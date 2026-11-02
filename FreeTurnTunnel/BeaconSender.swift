import Foundation
import Network
import Mobile

/// Sends a tiny status datagram to the app over 127.0.0.1 UDP every 2 seconds. Independent of
/// sendProviderMessage, which some third-party signing setups leave without a reply.
final class BeaconSender {
    private let queue = DispatchQueue(label: "freeturn.beacon")
    private var timer: DispatchSourceTimer?
    private var conn: NWConnection?
    private var token = ""

    func start(token: String) {
        queue.async {
            self.token = token
            guard self.timer == nil, !token.isEmpty else { return }
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
        // Loopback only: never route these packets into the tunnel or out to the network.
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

    private func fire() {
        var p = BeaconPacket(token: token, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
        if let st = MobileGetState() {
            p.streams = st.streams
            p.total = st.total
        }
        guard let data = try? JSONEncoder().encode(p) else { return }
        let c = connection()
        c.send(content: data, completion: .contentProcessed { [weak self, weak c] err in
            if err != nil { self?.queue.async { c?.cancel(); if self?.conn === c { self?.conn = nil } } }
        })
    }
}
