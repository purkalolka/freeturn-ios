import Foundation
import NetworkExtension
import Combine
import Mobile
import WidgetKit

@MainActor
final class VPNController: ObservableObject {
    @Published var status: String = "Disconnected"
    @Published var active = false
    @Published var lastError: String?
    @Published var remoteLog = ""
    @Published var remoteCaptcha: String?
    @Published var streams = 0
    @Published var extBuild = "unknown"
    @Published var ipcStatus = "not queried yet"
    @Published var totalStreams = 0

    private var manager: NETunnelProviderManager?
    /// Derived from the real bundle id so it survives re-signing with a different one.
    private let extensionBundleId = (Bundle.main.bundleIdentifier ?? "com.purkalolka.freeturn") + ".tunnel"

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

    /// Pulls the extension's in-memory log over IPC (works without a shared App Group).
    func fetchLog() {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            ipcStatus = "no tunnel session"
            return
        }
        guard session.status != .disconnected, session.status != .invalid else {
            ipcStatus = "tunnel not running"
            return
        }
        do {
            try session.sendProviderMessage(Data([1])) { [weak self] reply in
                Task { @MainActor in
                    guard let reply = reply else { self?.ipcStatus = "extension replied with nothing"; return }
                    guard let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: String] else {
                        self?.ipcStatus = "unreadable reply (\(reply.count) bytes)"
                        return
                    }
                    self?.remoteLog = obj["log"] ?? ""
                    let c = obj["captcha"] ?? ""
                    self?.remoteCaptcha = c.isEmpty ? nil : c
                    self?.streams = Int(obj["streams"] ?? "") ?? 0
                    self?.totalStreams = Int(obj["total"] ?? "") ?? 0
                    self?.extBuild = obj["build"] ?? "?"
                    self?.ipcStatus = "ok, extension log \(self?.remoteLog.count ?? 0) chars, streams \(self?.streams ?? 0)/\(self?.totalStreams ?? 0)"
                }
            }
        } catch {
            ipcStatus = "send failed: \(error.localizedDescription)"
        }
    }

    var diagnostics: String {
        let raw: String
        if let c = manager?.connection {
            raw = ["invalid", "disconnected", "connecting", "connected", "reasserting", "disconnecting"][min(max(c.status.rawValue, 0), 5)]
        } else {
            raw = "no VPN configuration saved"
        }
        return SharedLog.diagnostics + "\nextension: \(extensionBundleId)\nvpn status: \(raw)\napp build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")\nextension build: \(extBuild)\nextension link: \(ipcStatus)\nlast error: \(lastError ?? "none")"
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    @objc private func statusChanged() { refreshStatus() }

    private func refreshStatus() {
        defer {
            if #available(iOS 18.0, *) { ControlCenter.shared.reloadControls(ofKind: "FreeTurnToggle") }
        }
        guard let conn = manager?.connection else { active = false; status = "Disconnected"; return }
        switch conn.status {
        case .connected:     status = "Connected";     active = true
        case .connecting:    status = "Connecting…";   active = true
        case .disconnecting: status = "Disconnecting…"; active = true
        case .reasserting:   status = "Reasserting…";  active = true
        default:             status = "Disconnected";  active = false
        }
        if conn.status == .disconnected { streams = 0; totalStreams = 0 }
        if conn.status == .disconnected, #available(iOS 16.0, *) {
            conn.fetchLastDisconnectError { [weak self] err in
                guard let err = err else { return }
                Task { @MainActor in self?.lastError = err.localizedDescription }
            }
        }
    }
}
