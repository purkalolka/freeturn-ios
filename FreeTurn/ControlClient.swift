import Foundation
import Network
import Combine

/// App side of the loopback control channel. It receives log lines, stream counts and the
/// captcha URL directly from the extension, and can send commands back, without App Groups,
/// the provisioning profile or `sendProviderMessage`.
///
/// All methods and callbacks run on the main queue: the connection is started on `.main`, the
/// heartbeat is a main-run-loop timer, and the UI observes the published properties.
final class ControlClient: ObservableObject {
    static let shared = ControlClient()

    /// Random per-install value handed to the extension in providerConfiguration. A stray
    /// listener from another install cannot impersonate ours without it.
    let token: String = {
        let key = "controlToken"
        if let token = UserDefaults.standard.string(forKey: key), !token.isEmpty { return token }
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
        UserDefaults.standard.set(token, forKey: key)
        return token
    }()

    @Published private(set) var connected = false
    @Published private(set) var logText = ""
    @Published private(set) var streams = 0
    @Published private(set) var total = 0
    @Published private(set) var captcha: String?
    @Published private(set) var tunnelState = "?"
    @Published private(set) var extBuild = "unknown"
    @Published private(set) var port: UInt16?
    @Published private(set) var lastMessageAt: Date?
    @Published private(set) var status = "idle"
    @Published private(set) var lastError: String?

    var age: Int? { lastMessageAt.map { Int(Date().timeIntervalSince($0)) } }

    private var connection: NWConnection?
    private var running = false
    private var generation = 0
    private var buffer = Data()
    /// Absolute UTF-8 end offset of the log text currently held in `logText`.
    private var offset = 0
    private var receivedSnapshot = false
    private var snapshotRequested = false
    private var reconnectScheduled = false
    private var heartbeat: Timer?

    func start() {
        guard !running else { return }
        running = true
        connected = false
        logText = ""
        buffer.removeAll(keepingCapacity: true)
        offset = 0
        receivedSnapshot = false
        snapshotRequested = false
        reconnectScheduled = false
        generation += 1
        status = "searching"
        scan(from: ControlConfig.portRange.lowerBound)
        startHeartbeat()
    }

    func stop() {
        running = false
        generation += 1
        connection?.cancel()
        connection = nil
        connected = false
        status = "stopped"
        reconnectScheduled = false
        heartbeat?.invalidate()
        heartbeat = nil
    }

    /// Clears the local copy immediately; the extension echoes a `reset` message as well.
    func clearLocalLog() {
        logText = ""
        offset = 0
        receivedSnapshot = false
        snapshotRequested = false
    }

    func send(_ command: String) {
        guard let connection = connection, connected else { return }
        var message = ControlMessage(type: "cmd")
        message.cmd = command
        guard let data = ControlFraming.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Connection

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, self.running else { return }
            if self.connected, let age = self.age, age > Int(ControlConfig.staleAfter) {
                self.status = "stale (\(age)s)"
                self.reconnectNow()
            }
        }
    }

    private func reconnectNow() {
        generation += 1
        connection?.cancel()
        connection = nil
        connected = false
        buffer.removeAll(keepingCapacity: true)
        offset = 0
        receivedSnapshot = false
        snapshotRequested = false
        reconnectScheduled = false
        scan(from: ControlConfig.portRange.lowerBound)
    }

    private func scan(from candidate: UInt16) {
        guard running else { return }
        guard candidate <= ControlConfig.portRange.upperBound else {
            status = "no listener"
            scheduleReconnect()
            return
        }
        let gen = generation
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: candidate)!,
            using: parameters)
        self.connection = connection
        var settled = false

        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self = self, self.running, self.generation == gen, !settled else { return }
            settled = true
            connection?.cancel()
            if self.connection === connection { self.connection = nil }
            self.scan(from: candidate + 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: timeout)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, self.running, self.generation == gen else { return }
            switch state {
            case .ready:
                guard !settled, let connection = connection else { return }
                settled = true
                timeout.cancel()
                self.buffer.removeAll(keepingCapacity: true)
                self.sendHello(connection)
                // A foreign process may accept the TCP connection and then stay silent, so a
                // ready socket is not proof that this is our extension. Move on if no snapshot
                // or state message arrives.
                let handshake = DispatchWorkItem { [weak self, weak connection] in
                    guard let self = self,
                          self.running,
                          self.generation == gen,
                          !self.connected,
                          self.connection === connection else { return }
                    connection?.cancel()
                    self.connection = nil
                    self.scan(from: candidate + 1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: handshake)
            case .failed(let error):
                guard !settled else { return }
                settled = true
                timeout.cancel()
                self.lastError = error.localizedDescription
                if self.connection === connection { self.connection = nil }
                self.scan(from: candidate + 1)
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(connection, generation: gen, candidate: candidate)
    }

    private func sendHello(_ connection: NWConnection) {
        var message = ControlMessage(type: "hello")
        message.token = token
        message.build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        guard let data = ControlFraming.encode(message) else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.lastError = error.localizedDescription
                connection.cancel()
            }
        })
        status = "handshaking on \(connection.endpoint)"
    }

    private func receive(_ connection: NWConnection, generation gen: Int, candidate: UInt16) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self,
                  let connection = connection,
                  self.running,
                  self.generation == gen,
                  self.connection === connection else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                if let error = error { self.lastError = error.localizedDescription }
                self.connection = nil
                connection.cancel()
                if self.connected {
                    // The extension went away (or restarted on another port): start the scan
                    // over, because the first free port may have changed.
                    self.connected = false
                    self.scheduleReconnect()
                } else {
                    // Something else is listening, or the token did not match: keep scanning
                    // instead of reconnecting to the same port forever.
                    self.scan(from: candidate + 1)
                }
                return
            }
            self.receive(connection, generation: gen, candidate: candidate)
        }
    }

    private func drain() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = ControlFraming.decode(line) else { continue }
            handle(message)
        }
        if buffer.count > ControlConfig.maxPendingBytes {
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func handle(_ message: ControlMessage) {
        lastMessageAt = Date()
        lastError = nil
        switch message.type {
        case "snapshot":
            connected = true
            receivedSnapshot = true
            snapshotRequested = false
            status = "connected on \(message.port.map(String.init) ?? "?")"
            port = message.port
            extBuild = message.build ?? "?"
            logText = message.log ?? ""
            trimLog()
            streams = message.streams ?? 0
            total = message.total ?? 0
            captcha = message.captcha
            tunnelState = message.state ?? tunnelState
            offset = message.offsetEnd ?? 0
        case "log":
            connected = true
            guard let text = message.log,
                  let start = message.offsetStart,
                  let end = message.offsetEnd else { return }
            if end <= offset { return } // already included in the snapshot
            if start > offset {
                // A batch was dropped by backpressure: a snapshot is cheaper and safer than
                // showing a log with holes. Ignore this batch until the snapshot arrives.
                if !snapshotRequested {
                    snapshotRequested = true
                    send("snapshot")
                }
                return
            }
            // start <= offset < end: skip the bytes already covered by the snapshot.
            let bytes = Array(text.utf8)
            let skip = offset - start
            if skip < bytes.count {
                logText += String(decoding: bytes[skip...], as: UTF8.self)
                trimLog()
            }
            offset = end
        case "state":
            connected = true
            extBuild = message.build ?? extBuild
            port = message.port ?? port
            streams = message.streams ?? streams
            total = message.total ?? total
            captcha = message.captcha
            tunnelState = message.state ?? tunnelState
            // A snapshot normally arrives first; if it was missed, ask for one once.
            if !receivedSnapshot && !snapshotRequested {
                snapshotRequested = true
                send("snapshot")
            }
        case "reset":
            logText = ""
            offset = 0
            receivedSnapshot = true
            snapshotRequested = false
        case "pong":
            break
        default:
            break
        }
    }

    private func trimLog() {
        if logText.count > ControlConfig.logLimit {
            logText = String(logText.suffix(ControlConfig.logLimit))
        }
    }

    private func scheduleReconnect() {
        guard running, !reconnectScheduled else { return }
        reconnectScheduled = true
        offset = 0
        receivedSnapshot = false
        snapshotRequested = false
        status = "reconnecting"
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            self.reconnectScheduled = false
            guard self.running, self.generation == gen else { return }
            self.generation += 1
            self.scan(from: ControlConfig.portRange.lowerBound)
        }
    }
}
