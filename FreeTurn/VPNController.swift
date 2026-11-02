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
    private var appProbes: [GroupProbeResult] = []
    private var probeTick = 0

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
                    self?.extGroup = obj["group"] ?? "?"
                    self?.ipcStatus = "ok, extension log \(self?.remoteLog.count ?? 0) chars, streams \(self?.streams ?? 0)/\(self?.totalStreams ?? 0)"
                }
            }
        } catch {
            ipcStatus = "send failed: \(error.localizedDescription)"
        }
    }

    // MARK: loopback beacon state

    private var beacon: BeaconListener { BeaconListener.shared }
    var beaconReceived: Bool { beacon.received }
    var beaconAge: Int? { beacon.age }
    var beaconBuild: String? { beacon.state?.build }
    var beaconGroup: String? { beacon.state?.groupID }
    var beaconBundleId: String? { beacon.state?.bundleId }
    var beaconProfileGroups: [String] { beacon.state?.profileGroups ?? [] }
    var beaconProbes: [GroupProbeResult] { beacon.state?.probes ?? [] }
    var beaconEntitledGroups: [String] { beacon.state?.entitledGroups ?? [] }

    /// Re-runs the App Group probes every ~5 calls (called once a second by the Log view).
    func tickProbes() {
        if probeTick % 5 == 0 { appProbes = GroupProbe.run() }
        probeTick += 1
    }

    private var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    /// Groups where app and extension markers see each other, from our own disk view and the extension's.
    private var commonGroups: [String] {
        Array(Set(GroupProbe.common(appProbes) + GroupProbe.common(beaconProbes))).sorted()
    }

    private var effectiveExtBuild: String {
        extBuild != "unknown" ? extBuild : (beaconBuild ?? "unknown")
    }

    private func verdict(fileLogEmpty: Bool) -> String {
        guard beaconReceived else { return "ext not running current code, or loopback blocked" }
        let eb = beaconBuild ?? "?"
        guard eb == appBuild else { return "build mismatch (app \(appBuild), ext \(eb))" }
        if !beaconEntitledGroups.isEmpty && !commonGroups.isEmpty && fileLogEmpty {
            return "shared group available, file log should work"
        }
        if ipcStatus == "extension replied with nothing" { return "ext code ok, IPC blocked by system" }
        if ipcStatus.hasPrefix("ok") {
            return fileLogEmpty && commonGroups.isEmpty ? "no shared group: profile/entitlements" : "ok"
        }
        return "ok (ipc: \(ipcStatus))"
    }

    var diagnostics: String {
        let raw: String
        if let c = manager?.connection {
            raw = ["invalid", "disconnected", "connecting", "connected", "reasserting", "disconnecting"][min(max(c.status.rawValue, 0), 5)]
        } else {
            raw = "no VPN configuration saved"
        }
        let fileLogEmpty = SharedLog.read().isEmpty
        let probes = (appProbes.isEmpty ? "n/a" : appProbes.map { "\($0.group) container=\($0.container) wrote=\($0.wrote) seen=\($0.seen.joined(separator: "+"))" }.joined(separator: "\n  "))
        let extProbes = beaconProbes.isEmpty ? "n/a" : beaconProbes.map { "\($0.group) container=\($0.container) wrote=\($0.wrote) seen=\($0.seen.joined(separator: "+"))" }.joined(separator: "\n  ")
        let extGrp = beaconGroup ?? (extGroup == "unknown" ? nil : extGroup)
        let sameGroup = extGrp.map { $0 == SharedLog.groupID ? "same" : "DIFFERENT (app \(SharedLog.groupID), ext \($0))" } ?? "unknown"
        return SharedLog.diagnostics + """

        extension: \(extensionBundleId)
        vpn status: \(raw)
        app build: \(appBuild)
        extension build: \(effectiveExtBuild)
        extension link: \(ipcStatus)
        last error: \(lastError ?? "none")
        beacon: \(beaconReceived ? "received (age \(beaconAge ?? -1)s)" : "NOT received") [listener: \(beacon.listenerState)]
        beacon build: \(beaconBuild ?? "-")
        beacon bundle: \(beaconBundleId ?? "-")
        beacon group: \(beaconGroup ?? "-")
        beacon profile groups: \(beaconProfileGroups.isEmpty ? "-" : beaconProfileGroups.joined(separator: ", "))
        ext profile: present=\(beacon.state?.profilePresent.map(String.init) ?? "-") size=\(beacon.state?.profileSize.map(String.init) ?? "-") parseOK=\(beacon.state?.profileParseOK.map(String.init) ?? "-") groups=\(beacon.state?.profileGroupsCount.map(String.init) ?? "-")
        ext chosen group: \(beacon.state?.chosenGroup ?? "-")
        ext entitled groups: \(beaconEntitledGroups.isEmpty ? "none" : beaconEntitledGroups.joined(separator: ", "))
        handleAppMessage calls: \(beacon.state?.handleAppMessageCount.map(String.init) ?? "-")
        ipc: extBuild=\(extBuild) extGroup=\(extGroup) status=\(ipcStatus)
        common groups: \(commonGroups.isEmpty ? "none" : commonGroups.joined(separator: ", "))
        app group vs ext group: \(sameGroup)
        app probes:
          \(probes)
        ext probes:
          \(extProbes)
        VERDICT: \(verdict(fileLogEmpty: fileLogEmpty))
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
