import Foundation
import NetworkExtension
import Combine
import Mobile

@MainActor
final class VPNController: ObservableObject {
    @Published var status: String = "Disconnected"
    @Published var active = false
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private let extensionBundleId = "com.purkalolka.freeturn.tunnel"

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusChanged),
            name: .NEVPNStatusDidChange, object: nil)
        Task { await load() }
    }

    private func load() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = managers.first
        refreshStatus()
    }

    /// Builds the relay+tunnel JSON config from the freeturn:// share link and the VK call
    /// link (the Go core does the parsing), then starts the system VPN via the
    /// packet-tunnel extension.
    func start(freeturnLink: String, vkLink: String, clientId: String) {
        var err: NSError?
        let configJSON = MobileConfigFromLink(freeturnLink, vkLink, clientId, &err)
        if let err = err {
            lastError = err.localizedDescription
            return
        }
        guard let data = configJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tunnel = obj["tunnel"] as? [String: Any],
              let wgText = tunnel["config"] as? String, !wgText.isEmpty else {
            lastError = "freeturn link has no WireGuard config"
            return
        }
        let mtu = tunnel["mtu"] as? Int ?? 1280
        lastError = nil

        Task {
            let m = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = extensionBundleId
            proto.serverAddress = "FreeTurn"
            proto.providerConfiguration = [
                "configJSON": configJSON,
                "wgText": wgText,
                "mtu": mtu,
            ]
            m.protocolConfiguration = proto
            m.localizedDescription = "FreeTurn"
            m.isEnabled = true
            do {
                try await m.saveToPreferences()
                try await m.loadFromPreferences()
                self.manager = m
                try m.connection.startVPNTunnel()
            } catch {
                self.status = "Error: \(error.localizedDescription)"
                self.lastError = error.localizedDescription
            }
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    @objc private func statusChanged() { refreshStatus() }

    private func refreshStatus() {
        guard let conn = manager?.connection else { active = false; status = "Disconnected"; return }
        switch conn.status {
        case .connected:     status = "Connected";     active = true
        case .connecting:    status = "Connecting…";   active = true
        case .disconnecting: status = "Disconnecting…"; active = true
        case .reasserting:   status = "Reasserting…";  active = true
        default:             status = "Disconnected";  active = false
        }
    }
}
