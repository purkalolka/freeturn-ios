import Foundation
import Network
import Mobile

/// Extension side of the loopback control channel. It is the only transport that needs neither
/// an App Group nor `sendProviderMessage`, so it keeps working when a third-party signer gives
/// the extension a different (or no) provisioning profile.
///
/// The extension listens on the first free port in `ControlConfig.portRange`; the app scans the
/// same range. Newline-delimited JSON keeps the framing trivial and lets both sides evolve.
final class ControlServer {
    /// Called on the server queue when the app asks for a reconnect or wake.
    var onReconnect: (() -> Void)?
    var onWake: (() -> Void)?

    private final class Client {
        let connection: NWConnection
        var handshaken = false
        var buffer = Data()
        var pendingBytes = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "freeturn.control.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var port: UInt16?
    private var token = ""
    private var started = false
    private var pendingLog = ""
    private var pendingStart: Int?
    private var pendingEnd = 0
    private var flushTimer: DispatchSourceTimer?
    private var stateTimer: DispatchSourceTimer?

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    func start(token: String) {
        queue.async {
            if !token.isEmpty { self.token = token }
            guard !self.started else { return }
            self.started = true
            self.bind(from: ControlConfig.portRange.lowerBound)
            self.startTimers()
        }
    }

    func stop() {
        queue.async {
            self.started = false
            self.listener?.cancel()
            self.listener = nil
            self.flushTimer?.cancel(); self.flushTimer = nil
            self.stateTimer?.cancel(); self.stateTimer = nil
            for client in self.clients.values { client.connection.cancel() }
            self.clients.removeAll()
            self.port = nil
            self.pendingLog = ""
            self.pendingStart = nil
            self.pendingEnd = 0
        }
    }

    /// Appends a line to the next batched log message. The line is also in SharedLog's ring,
    /// so a client that connects later gets it in the snapshot. `offset` is the absolute UTF-8
    /// position of the first byte of `line`.
    func appendLog(_ line: String, offset: Int) {
        queue.async {
            guard self.started else { return }
            if self.pendingLog.isEmpty { self.pendingStart = offset }
            self.pendingLog += line
            self.pendingEnd = offset + line.utf8.count
            if self.pendingLog.utf8.count > ControlConfig.logLimit {
                let bytes = Array(self.pendingLog.utf8)
                var drop = bytes.count - ControlConfig.logLimit / 2
                // Trim at a line boundary so the byte offset stays exact and no multi-byte
                // character is split.
                while drop < bytes.count && bytes[drop] != 0x0A { drop += 1 }
                if drop < bytes.count { drop += 1 }
                self.pendingLog = String(decoding: bytes[drop...], as: UTF8.self)
                self.pendingStart = (self.pendingStart ?? 0) + drop
            }
        }
    }

    func broadcastClear() {
        queue.async {
            self.pendingLog = ""
            self.pendingStart = nil
            self.pendingEnd = 0
            var message = ControlMessage(type: "reset")
            message.build = self.build
            self.broadcast(message)
        }
    }

    // MARK: - Listener

    private func bind(from candidate: UInt16) {
        guard started else { return }
        guard candidate <= ControlConfig.portRange.upperBound else {
            SharedLog.write("[CTRL] no free port in \(ControlConfig.portRange)")
            return
        }
        let parameters = NWParameters.tcp
        // Bind explicitly to loopback: the channel must never be reachable from the LAN, and
        // it must not be captured by the tunnel's default route.
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: candidate)!)
        parameters.allowLocalEndpointReuse = false
        guard let listener = try? NWListener(using: parameters) else {
            bind(from: candidate + 1)
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self = self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    guard self.started, self.listener === listener else { return }
                    self.port = candidate
                    SharedLog.write("[CTRL] listening on 127.0.0.1:\(candidate)")
                case .failed(let error), .waiting(let error):
                    guard self.started, self.listener === listener else { return }
                    self.listener?.cancel()
                    self.listener = nil
                    self.port = nil
                    SharedLog.write("[CTRL] port \(candidate) failed: \(error.localizedDescription)")
                    self.bind(from: candidate + 1)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        let id = ObjectIdentifier(connection)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async {
                    self?.clients.removeValue(forKey: id)
                    SharedLog.write("[CTRL] client disconnected")
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        SharedLog.write("[CTRL] client connected")
        receive(id)
    }

    private func receive(_ id: ObjectIdentifier) {
        guard let client = clients[id] else { return }
        client.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self = self, let client = self.clients[id] else { return }
            if let data = data, !data.isEmpty {
                client.buffer.append(data)
                self.drain(id, client)
            }
            if isComplete || error != nil {
                self.clients.removeValue(forKey: id)
                client.connection.cancel()
                return
            }
            self.receive(id)
        }
    }

    private func drain(_ id: ObjectIdentifier, _ client: Client) {
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            let line = client.buffer.subdata(in: client.buffer.startIndex..<newline)
            client.buffer.removeSubrange(client.buffer.startIndex...newline)
            guard let message = ControlFraming.decode(line) else { continue }
            handle(id, client, message)
        }
    }

    private func handle(_ id: ObjectIdentifier, _ client: Client, _ message: ControlMessage) {
        if !client.handshaken {
            guard message.type == "hello" else {
                clients.removeValue(forKey: id)
                client.connection.cancel()
                return
            }
            // An extension started by an older app has no token in providerConfiguration.
            // Adopt the first client's token instead of forcing a VPN restart after an update.
            if token.isEmpty { token = message.token ?? "" }
            guard message.token == token else {
                clients.removeValue(forKey: id)
                client.connection.cancel()
                return
            }
            client.handshaken = true
            sendSnapshot(to: client)
            return
        }
        guard message.type == "cmd" else { return }
        switch message.cmd {
        case "snapshot":
            sendSnapshot(to: client)
        case "clear":
            SharedLog.clear()
        case "reconnect":
            onReconnect?()
        case "wake":
            onWake?()
        case "ping":
            var pong = ControlMessage(type: "pong")
            pong.build = build
            send(pong, to: client)
        default:
            break
        }
    }

    // MARK: - Sending

    private func sendSnapshot(to client: Client) {
        let snapshot = SharedLog.snapshot()
        var message = ControlMessage(type: "snapshot")
        message.build = build
        message.port = port
        message.log = snapshot["log"] ?? ""
        message.offsetEnd = Int(snapshot["offset"] ?? "") ?? 0
        let captcha = snapshot["captcha"] ?? ""
        message.captcha = captcha.isEmpty ? nil : captcha
        if let state = MobileGetState() {
            message.state = state.state
            message.streams = state.streams
            message.total = state.total
        }
        send(message, to: client)
    }

    private func send(_ message: ControlMessage, to client: Client) {
        guard client.handshaken, let data = ControlFraming.encode(message) else { return }
        // A slow client must not grow the extension's memory without bound: it will get a fresh
        // snapshot on its next request/reconnect instead.
        guard client.pendingBytes < ControlConfig.maxPendingBytes else { return }
        client.pendingBytes += data.count
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self = self, let client = client else { return }
            self.queue.async {
                client.pendingBytes = max(0, client.pendingBytes - data.count)
                if error != nil {
                    self.clients.removeValue(forKey: ObjectIdentifier(client.connection))
                    client.connection.cancel()
                }
            }
        })
    }

    private func broadcast(_ message: ControlMessage) {
        for client in clients.values where client.handshaken {
            send(message, to: client)
        }
    }

    // MARK: - Timers

    private func startTimers() {
        let flush = DispatchSource.makeTimerSource(queue: queue)
        flush.schedule(deadline: .now() + 0.2, repeating: 0.2)
        flush.setEventHandler { [weak self] in self?.flushLog() }
        flush.resume()
        flushTimer = flush

        let state = DispatchSource.makeTimerSource(queue: queue)
        state.schedule(deadline: .now() + 2, repeating: 2)
        state.setEventHandler { [weak self] in self?.tick() }
        state.resume()
        stateTimer = state
    }

    private func flushLog() {
        guard !pendingLog.isEmpty, let start = pendingStart else { return }
        let text = pendingLog
        let end = pendingEnd
        pendingLog = ""
        pendingStart = nil
        pendingEnd = 0
        var message = ControlMessage(type: "log")
        message.log = text
        message.offsetStart = start
        message.offsetEnd = end
        broadcast(message)
    }

    private func tick() {
        var message = ControlMessage(type: "state")
        message.build = build
        message.port = port
        if let state = MobileGetState() {
            message.state = state.state
            message.streams = state.streams
            message.total = state.total
        }
        let captcha = SharedLog.snapshotCaptcha()
        message.captcha = captcha.isEmpty ? nil : captcha
        broadcast(message)
    }
}
