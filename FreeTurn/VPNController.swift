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
    @Published var extGroup = "unknown"
    private var ipcStreamsAt: Date?

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
        manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionBundleId }
            ?? managers.first
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
                "appGroups": SharedLog.profileAppGroups().sorted(),
                "beaconToken": BeaconListener.shared.token,
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
                    self?.ipcStreamsAt = obj["total"] != nil ? Date() : nil
                    self?.extGroup = obj["group"] ?? "?"
                    self?.extBuild = obj["build"] ?? "?"
                    self?.ipcStatus = "ok, extension log \(self?.remoteLog.count ?? 0) chars, streams \(self?.streams ?? 0)/\(self?.totalStreams ?? 0)"
                }
            }
        } catch {
            ipcStatus = "send failed: \(error.localizedDescription)"
        }
    }

    /// Picks the stream counter source: fresh IPC reply, then fresh loopback beacon, then the last
    /// "[STATE] ... streams=X/Y" line of the log. Called once a second by the Log view (main thread).
    func updateStreams(logText: String) {
        guard status == "Connected" || status == "Connecting…" else {
            streams = 0; totalStreams = 0
            return
        }
        if let at = ipcStreamsAt, Date().timeIntervalSince(at) < 6 { return }
        if let age = beacon.age, age < 6, let s = beacon.packet?.streams, let t = beacon.packet?.total {
            streams = s; totalStreams = t
            return
        }
        if let r = logText.range(of: "[STATE]", options: .backwards) {
            let line = logText[r.upperBound...].prefix { $0 != "\n" }
            if let m = line.range(of: #"streams=(\d+)/(\d+)"#, options: .regularExpression) {
                let nums = line[m].dropFirst("streams=".count).split(separator: "/").compactMap { Int($0) }
                if nums.count == 2 { streams = nums[0]; totalStreams = nums[1] }
            }
        }
    }

    private var beacon: BeaconListener { BeaconListener.shared }
    private var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    private var verdict: String {
        guard let eb = beacon.packet?.build, beacon.age != nil else { return "no beacon: extension not running this build, or loopback blocked" }
        if eb != appBuild { return "build mismatch (app \(appBuild), ext \(eb))" }
        return ipcStatus.hasPrefix("ok") ? "ok" : "ok (IPC unavailable, using beacon/log)"
    }

    var diagnostics: String {
        let raw: String
        if let c = manager?.connection {
            raw = ["invalid", "disconnected", "connecting", "connected", "reasserting", "disconnecting"][min(max(c.status.rawValue, 0), 5)]
        } else {
            raw = "no VPN configuration saved"
        }
        let extBuildShown = extBuild != "unknown" ? extBuild : (beacon.packet?.build ?? "unknown")
        let beaconText = beacon.age.map { "received (age \($0)s)" } ?? "NOT received"
        return SharedLog.diagnostics + """

        ext group: \(extGroup)
        extension: \(extensionBundleId)
        vpn status: \(raw)
        app build: \(appBuild)
        extension build: \(extBuildShown)
        extension link: \(ipcStatus)
        beacon: \(beaconText)
        last error: \(lastError ?? "none")
        verdict: \(verdict)
        """
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
