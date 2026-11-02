import Foundation
import Network

/// Receives the tunnel extension's loopback beacon. Only runs while the app is active.
final class BeaconListener: ObservableObject {
    static let shared = BeaconListener()

    @Published private(set) var state: BeaconPacket?
    @Published private(set) var stateAt: Date?
    @Published private(set) var logTail: [String] = []
    @Published private(set) var listenerState = "not started"

    private let queue = DispatchQueue(label: "freeturn.beacon.listener")
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    var received: Bool { state != nil }
    var age: Int? { stateAt.map { Int(Date().timeIntervalSince($0)) } }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.udp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: BeaconConfig.port)!)
            l.stateUpdateHandler = { [weak self, weak l] st in
                DispatchQueue.main.async {
                    self?.listenerState = "\(st)"
                    if case .failed = st { self?.listener = nil; l?.cancel() }
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
        } catch {
            listenerState = "failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
        listenerState = "stopped"
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            if let data = data, let p = try? JSONDecoder().decode(BeaconPacket.self, from: data) {
                DispatchQueue.main.async {
                    if p.type == "log" {
                        self?.logTail = p.logTail ?? []
                    } else {
                        self?.state = p
                        self?.stateAt = Date()
                    }
                }
            }
            if err == nil { self?.receive(c) } else { c.cancel() }
        }
    }
}
