import Foundation
import Network

/// Receives the tunnel extension's loopback status datagrams. Only runs while the app is active;
/// if the port is taken it simply stays silent and the UI falls back to other sources.
final class BeaconListener: ObservableObject {
    static let shared = BeaconListener()

    /// Random per-install value, handed to the extension via providerConfiguration.
    let token: String = {
        let key = "beaconToken"
        if let t = UserDefaults.standard.string(forKey: key), !t.isEmpty { return t }
        let t = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
        UserDefaults.standard.set(t, forKey: key)
        return t
    }()

    /// Published on the main queue only.
    @Published private(set) var packet: BeaconPacket?
    @Published private(set) var packetAt: Date?

    private let queue = DispatchQueue(label: "freeturn.beacon.listener")
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    var age: Int? { packetAt.map { Int(Date().timeIntervalSince($0)) } }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.udp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: BeaconConfig.port)!) else { return }
        l.stateUpdateHandler = { [weak self, weak l] st in
            if case .failed = st {
                DispatchQueue.main.async { self?.listener = nil }
                l?.cancel()
            }
        }
        l.newConnectionHandler = { [weak self] c in
            guard let self = self else { return }
            self.connections.append(c)
            c.stateUpdateHandler = { [weak self, weak c] st in
                switch st {
                case .failed, .cancelled:
                    self?.queue.async { self?.connections.removeAll { $0 === c } }
                default: break
                }
            }
            c.start(queue: self.queue)
            self.receive(c)
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            if let self = self, let data = data,
               let p = try? JSONDecoder().decode(BeaconPacket.self, from: data), p.token == self.token {
                DispatchQueue.main.async {
                    self.packet = p
                    self.packetAt = Date()
                }
            }
            if err == nil { self?.receive(c) } else { c.cancel() }
        }
    }
}
