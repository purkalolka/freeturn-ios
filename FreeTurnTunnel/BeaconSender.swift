import Foundation
import Network
import Mobile

/// Sends a small status datagram (and a recent log tail) to the app over 127.0.0.1 UDP every
/// 2 seconds. Independent of sendProviderMessage and of any shared App Group.
final class BeaconSender {
    private let queue = DispatchQueue(label: "freeturn.beacon")
    private var timer: DispatchSourceTimer?
    private var conn: NWConnection?
    private var tick = 0
    private var probes: [GroupProbeResult] = []

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 2)
            t.setEventHandler { [weak self] in self?.fire() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.conn?.cancel()
            self.conn = nil
        }
    }

    private func connection() -> NWConnection {
        if let c = conn { return c }
        let params = NWParameters.udp
        // Loopback only: never let these packets be routed into the tunnel or out to the network.
        params.requiredInterfaceType = .loopback
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: BeaconConfig.port)!, using: params)
        c.stateUpdateHandler = { [weak self, weak c] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { if self?.conn === c { self?.conn = nil } }
            default: break
            }
        }
        c.start(queue: queue)
        conn = c
        return c
    }

    private func send(_ packet: BeaconPacket, limit: Int) {
        guard let data = try? JSONEncoder().encode(packet), data.count <= limit else { return }
        let c = connection()
        c.send(content: data, completion: .contentProcessed { [weak self, weak c] err in
            if err != nil { self?.queue.async { c?.cancel(); if self?.conn === c { self?.conn = nil } } }
        })
    }

    private func fire() {
        if tick % 5 == 0 { probes = GroupProbe.run() }
        tick += 1

        var state = BeaconPacket(type: "state")
        state.build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        state.bundleId = Bundle.main.bundleIdentifier
        state.groupID = SharedLog.groupID
        state.profileGroups = SharedLog.profileAppGroups()
        state.probes = probes
        if let st = MobileGetState() {
            state.streams = st.streams
            state.total = st.total
        }
        state.t = Int(Date().timeIntervalSince1970)
        // Keep profileGroups; shrink probe detail instead if the datagram gets too big.
        if ((try? JSONEncoder().encode(state))?.count ?? 0) > 4000 {
            state.probes = state.probes?.map { GroupProbeResult(group: $0.group, container: $0.container, wrote: $0.wrote, seen: []) }
        }
        send(state, limit: 4000)

        // Log goes in its own datagram (loopback allows far larger than one MTU).
        let lines = (SharedLog.snapshot()["log"] ?? "").split(separator: "\n", omittingEmptySubsequences: true).suffix(30)
        var tail = lines.map(String.init)
        var logPacket = BeaconPacket(type: "log")
        logPacket.logTail = tail
        while !tail.isEmpty, ((try? JSONEncoder().encode(logPacket))?.count ?? Int.max) > 8000 {
            tail.removeFirst()
            logPacket.logTail = tail
        }
        if !tail.isEmpty { send(logPacket, limit: 8000) }
    }
}
