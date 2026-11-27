import NetworkExtension
import Darwin
import Mobile
import UserNotifications
import Network
import WidgetKit

/// System VPN entry point. The Go core (Mobile.xcframework) runs WireGuard/AmneziaWG
/// entirely in-process, talking to the TURN relay through an in-memory pipe — there is
/// no local loopback socket to exclude from the tunnel, unlike a separate relay process.
///
/// The extension owns recovery: the app is suspended almost immediately after it leaves
/// the foreground, so nothing outside this process can notice a dead relay or a stale
/// session (see `RecoveryController`).
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var started = false
    /// Raw provider tun descriptor. The core gets a `dup()` of it, so stopping the
    /// session does not invalidate the descriptor a restart needs.
    private var rawTunFD: Int32?
    private var configJSON = ""
    private var memTicks = 0
    private var cachedHandshakeAge: Int64 = -1

    private let control = ControlServer()
    private let recovery = RecoveryController()
    private let workQueue = DispatchQueue(label: "freeturn.work")
    /// `MobileStop()` can block for seconds; keep it off the health/timer queue.
    private let recoveryQueue = DispatchQueue(label: "freeturn.recovery")
    private var healthTimer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var observingDefaultPath = false
    private var lastPathKey: String?
    private var latestMonitorPath: Network.NWPath?
    private var pendingPathCheck: DispatchWorkItem?
    private var pathWarmupUntil = Date.distantPast
    private var lastHealthTick: Date?
    private var lastSleepAt: Date?
    private var eventSink: TunnelEventSink?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let conf = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let appGroups = (conf["appGroups"] as? [String] ?? []).sorted()
        // Our own profile may list no groups (signer quirk); then use a group from the app's profile
        // that this process can actually open: derived group first, else sorted-first, same as the app.
        if SharedLog.profileAppGroups().isEmpty,
           let g = ([SharedLog.groupID] + appGroups).first(where: {
               appGroups.contains($0) && FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
           }) {
            SharedLog.groupOverride = g
        }
        // The system can call startTunnel again for a tunnel it considers alive. Reuse the
        // running Go session for the same config; otherwise the old timers leak and
        // MobileStartTunnel fails with "already running".
        guard let configJSON = conf["configJSON"] as? String,
              let wgText = conf["wgText"] as? String,
              let mtu = conf["mtu"] as? Int else {
            SharedLog.write("[EXT] ERROR missing provider configuration")
            completionHandler(NSError(domain: "FreeTurn", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing provider configuration"]))
            return
        }
        let sameConfig = started && configJSON == self.configJSON
        if started && !sameConfig {
            SharedLog.write("[EXT] startTunnel re-entered with a new config, restarting session")
            teardownRuntime()
        }
        // The loopback control channel is the primary app<->extension transport: unlike App
        // Groups and sendProviderMessage it survives a third-party signer that gives the
        // extension a different (or no) embedded provisioning profile.
        let controlServer = control
        SharedLog.onWrite = { [weak controlServer] line, offset in
            controlServer?.appendLog(line, offset: offset)
        }
        SharedLog.onClear = { [weak controlServer] in controlServer?.broadcastClear() }
        control.onReconnect = { [weak self] in self?.requestRecovery(reason: "app request") }
        control.onWake = { [weak self] in
            self?.workQueue.async { self?.handleWake() }
        }
        control.start(token: conf["controlToken"] as? String
            ?? conf["beaconToken"] as? String
            ?? "")
        SharedLog.clear()
        SharedLog.captchaURL = nil
        MobileTuneForExtension()
        SharedLog.write("[EXT] startTunnel called, build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"), group \(SharedLog.groupID)")
        self.configJSON = configJSON
        if sameConfig {
            SharedLog.write("[EXT] startTunnel re-entered, reusing the running session")
            startHealthTimer()
            startPathWatch()
            completionHandler(nil)
            return
        }
        SharedLog.write("[EXT] config loaded, mtu=\(mtu)")

        var paramsErr: NSError?
        guard let params = MobileParseTunnelConfig(wgText, mtu, &paramsErr) else {
            SharedLog.write("[EXT] ERROR parse tunnel config: \(paramsErr?.localizedDescription ?? "?")")
            completionHandler(paramsErr ?? NSError(domain: "FreeTurn", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "failed to parse tunnel config"]))
            return
        }
        SharedLog.write("[EXT] parsed tunnel params: addr=\(params.addresses) dns=\(params.dns) mtu=\(params.mtu)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let addrList = params.addresses.split(separator: ",").map(String.init)
        var v4Addrs: [String] = []
        var v4Masks: [String] = []
        for a in addrList {
            let parts = a.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { continue }
            v4Addrs.append(String(parts[0]))
            v4Masks.append(cidrToMask(prefix))
        }
        if v4Addrs.isEmpty {
            completionHandler(NSError(domain: "FreeTurn", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "no tunnel addresses"]))
            return
        }
        let ipv4 = NEIPv4Settings(addresses: v4Addrs, subnetMasks: v4Masks)

        let allowedList = params.allowedIPs.split(separator: ",").map(String.init)
        var routes: [NEIPv4Route] = []
        for a in allowedList {
            let parts = a.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]) else { continue }
            routes.append(NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: cidrToMask(prefix)))
        }
        ipv4.includedRoutes = routes.isEmpty ? [NEIPv4Route.default()] : routes
        settings.ipv4Settings = ipv4
        settings.mtu = NSNumber(value: params.mtu > 0 ? params.mtu : mtu)

        // IPv6 is intentionally left off the tunnel (same as the Android client): the Go core
        // only speaks IPv4, so routing IPv6 into it black-holes traffic and makes apps wait
        // for a timeout before falling back to IPv4 (slow TikTok and similar).

        var dnsList = params.dns.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        if dnsList.isEmpty {
            dnsList = ["1.1.1.1", "8.8.8.8"]
        }
        let dns = NEDNSSettings(servers: dnsList)
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        SharedLog.write("[EXT] applying tunnel network settings...")
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                SharedLog.write("[EXT] ERROR setTunnelNetworkSettings: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            SharedLog.write("[EXT] network settings applied")
            guard let self = self else { return }

            guard let raw = self.getTunnelFileDescriptor() else {
                SharedLog.write("[EXT] ERROR could not find tun fd")
                completionHandler(NSError(domain: "FreeTurn", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "could not find tun file descriptor"]))
                return
            }
            self.rawTunFD = raw
            SharedLog.write("[EXT] found tun fd=\(raw)")
            guard let goFD = self.duplicateTunFD() else {
                completionHandler(NSError(domain: "FreeTurn", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "could not duplicate tun file descriptor"]))
                return
            }

            let sink = TunnelEventSink()
            MobileSetEventSink(sink)
            self.eventSink = sink

            SharedLog.write("[EXT] calling MobileStartTunnel...")
            var startErr: NSError?
            MobileStartTunnel(configJSON, Int(goFD), &startErr)
            if let startErr = startErr {
                SharedLog.write("[EXT] ERROR MobileStartTunnel: \(startErr.localizedDescription)")
                completionHandler(startErr)
                return
            }
            SharedLog.write("[EXT] MobileStartTunnel returned OK")

            self.started = true
            self.startRecovery()
            if #available(iOS 18.0, *) { ControlCenter.shared.reloadControls(ofKind: "FreeTurnToggle") }
            self.startHealthTimer()
            self.startPathWatch()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        SharedLog.write("[EXT] stopTunnel reason=\(reason.rawValue)")
        teardownRuntime()
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        workQueue.async { [weak self] in
            self?.lastSleepAt = Date()
            self?.recovery.noteSleep()
        }
        completionHandler()
    }

    override func wake() {
        SharedLog.write("[EXT] wake")
        workQueue.async { [weak self] in self?.handleWake() }
    }

    private func handleWake() {
        guard started else { return }
        let now = Date()
        let lastActive = lastSleepAt ?? lastHealthTick ?? now
        lastSleepAt = nil
        recovery.noteWake()
        // Android only kicks the core after a deep sleep. A short screen lock
        // should not provoke a 30-second TURN liveness probe while traffic is idle.
        if now.timeIntervalSince(lastActive) >= 60 {
            SharedLog.write("[EXT] wake after \(Int(now.timeIntervalSince(lastActive)))s - probing TURN")
            MobileWake()
        }
    }

    // MARK: - Recovery

    private func startRecovery() {
        recovery.streamRecovery = { _ in
            // Recycles only the streams that stopped receiving; the session, the tunnel and
            // the other allocations keep running.
            return MobileEnsureStreams()
        }
        recovery.reconnect = { _ in
            // Rebuilds every TURN allocation; the tunnel, fd and WireGuard keys stay.
            MobileReconnect()
        }
        recovery.hardRecovery = { [weak self] reason in self?.restartSession(reason: reason) }
        recovery.giveUp = { [weak self] reason in self?.cancelAfterFailure(reason: reason) }
        recovery.phaseChanged = { [weak self] phase, detail in
            SharedLog.write("[RECOVERY] \(phase.rawValue): \(detail)")
            // Keep the tunnel in "reconnecting" state instead of reporting it healthy.
            self?.reasserting = (phase == .recovering || phase == .backingOff)
        }
        cachedHandshakeAge = -1
        recovery.start()
    }

    private func requestRecovery(reason: String) {
        workQueue.async { [weak self] in
            guard let self = self, self.started else { return }
            self.recovery.requestSoftRecovery(reason)
        }
    }

    /// A soft reconnect is not enough when the Go session itself ended: stop it and start
    /// it again on a fresh duplicate of the provider descriptor.
    private func restartSession(reason: String) {
        SharedLog.write("[RECOVERY] hard restart: \(reason)")
        recoveryQueue.async { [weak self] in
            guard let self = self, self.started else { return }
            MobileStop()
            guard let fd = self.duplicateTunFD() else { return }
            var err: NSError?
            MobileStartTunnel(self.configJSON, Int(fd), &err)
            if let err = err {
                SharedLog.write("[RECOVERY] hard restart failed: \(err.localizedDescription)")
            } else {
                SharedLog.write("[RECOVERY] hard restart ok")
            }
        }
    }

    private func cancelAfterFailure(reason: String) {
        SharedLog.write("[RECOVERY] cancelling tunnel: \(reason)")
        recoveryQueue.async { [weak self] in
            guard let self = self else { return }
            MobileStop()
            // Documented way for a provider to stop an unrecoverable tunnel; on-demand
            // then starts a fresh process with a fresh Go runtime.
            self.cancelTunnelWithError(NSError(domain: "FreeTurn", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "tunnel recovery failed"]))
        }
    }

    private func duplicateTunFD() -> Int32? {
        guard let raw = rawTunFD else {
            SharedLog.write("[EXT] ERROR no raw tun fd to duplicate")
            return nil
        }
        let fd = dup(raw)
        if fd < 0 {
            SharedLog.write("[EXT] ERROR dup(tun fd): errno=\(errno)")
            return nil
        }
        return fd
    }

    private func currentHealth() -> RecoveryController.Snapshot {
        var snapshot = RecoveryController.Snapshot()
        if let st = MobileGetState() {
            snapshot.state = st.state
            snapshot.streams = st.streams
            snapshot.total = st.total
            snapshot.rxTotal = st.rxTotal
            snapshot.txTotal = st.txTotal
            snapshot.rxRate = st.rxRate
            snapshot.txRate = st.txRate
        }
        // Refreshed every fifth tick: MobileTunnelStats does a device-wide IPC read.
        snapshot.handshakeAge = cachedHandshakeAge
        return snapshot
    }

    private func refreshHandshakeAge() {
        guard let st = MobileGetState(), st.streams > 0, let ts = MobileTunnelStats() else {
            cachedHandshakeAge = -1
            return
        }
        cachedHandshakeAge = ts.handshakeAgeSec
    }

    private func startHealthTimer() {
        healthTimer?.cancel()
        // GCD timer: this callback runs on a queue with no active run loop, so Timer would never fire.
        let t = DispatchSource.makeTimerSource(queue: workQueue)
        t.schedule(deadline: .now() + 1, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self = self, self.started else { return }
            self.lastHealthTick = Date()
            self.recovery.tick(self.currentHealth())
            self.memTicks += 1
            if self.memTicks % 5 == 0 {
                self.refreshHandshakeAge()
            }
            if self.memTicks % 30 == 0 {
                SharedLog.write("[MEM] \(MobileMemStats())")
            }
        }
        t.resume()
        healthTimer = t
    }

    // MARK: - Network path

    /// Use the physical transport actually selected by the provider's path. The old
    /// availableInterfaces key changed when an unused cellular interface or utun appeared,
    /// tearing down every healthy TURN allocation.
    private func startPathWatch() {
        pathMonitor?.cancel()
        pendingPathCheck?.cancel()
        pendingPathCheck = nil
        lastPathKey = nil
        latestMonitorPath = nil
        pathWarmupUntil = Date().addingTimeInterval(3)
        if !observingDefaultPath {
            // `defaultPath` is KVO-compliant and reports the physical path of the
            // provider's own sockets; the tunnel's utun is not part of it.
            addObserver(self, forKeyPath: "defaultPath",
                        options: [.initial, .new], context: Self.defaultPathContext)
            observingDefaultPath = true
        }
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other])
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.workQueue.async {
                self.latestMonitorPath = path
                self.observePhysicalPath()
            }
        }
        monitor.start(queue: workQueue)
        pathMonitor = monitor
    }

    private static let defaultPathContext = UnsafeMutableRawPointer(bitPattern: 0x46545054)!

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard context == Self.defaultPathContext else { return }
        // NEProvider.defaultPath uses the legacy NetworkExtension.NWPath class. Its
        // changes prompt us to re-sample the Network framework monitor path.
        workQueue.async { [weak self] in self?.observePhysicalPath() }
    }

    private static func pathKey(_ path: Network.NWPath) -> String {
        guard path.status == .satisfied else { return "none" }
        if path.usesInterfaceType(.wiredEthernet) { return "ethernet" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        return "other"
    }

    private func observePhysicalPath() {
        guard started else { return }
        guard let path = latestMonitorPath else { return }
        let key = Self.pathKey(path)
        guard key != "none", key != "other" else { return }
        if lastPathKey == nil || Date() < pathWarmupUntil {
            pendingPathCheck?.cancel()
            pendingPathCheck = nil
            lastPathKey = key
            SharedLog.write("[EXT] physical network baseline: \(key)")
            return
        }
        guard lastPathKey != key else {
            pendingPathCheck?.cancel()
            pendingPathCheck = nil
            return
        }
        // Re-sample after the handover settles. Extra path notifications for the same
        // candidate do not extend the wait indefinitely.
        if pendingPathCheck != nil { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self = self, self.started else { return }
            self.pendingPathCheck = nil
            guard let settledPath = self.latestMonitorPath else { return }
            let settled = Self.pathKey(settledPath)
            guard settled != "none", settled != "other",
                  let previous = self.lastPathKey, previous != settled else { return }
            self.lastPathKey = settled
            SharedLog.write("[EXT] physical network \(previous) -> \(settled)")
            self.recovery.notePathChange(settled)
        }
        pendingPathCheck = check
        workQueue.asyncAfter(deadline: .now() + 2, execute: check)
    }

    // MARK: - App messages

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        var info = SharedLog.snapshot()
        info["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        info["group"] = SharedLog.groupID
        if let st = MobileGetState() {
            info["streams"] = String(st.streams)
            info["total"] = String(st.total)
        }
        var data = try? JSONSerialization.data(withJSONObject: info)
        if data == nil {
            // Never reply with nil: the app could not tell that apart from "handler not implemented".
            data = try? JSONSerialization.data(withJSONObject: ["build": info["build"] ?? "?", "error": "log not encodable"])
        }
        completionHandler?(data)
    }

    // MARK: - Teardown

    private func teardownRuntime() {
        healthTimer?.cancel()
        healthTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        pendingPathCheck?.cancel()
        pendingPathCheck = nil
        if observingDefaultPath {
            removeObserver(self, forKeyPath: "defaultPath", context: Self.defaultPathContext)
            observingDefaultPath = false
        }
        lastPathKey = nil
        latestMonitorPath = nil
        lastHealthTick = nil
        lastSleepAt = nil
        recovery.stop()
        control.stop()
        SharedLog.onWrite = nil
        SharedLog.onClear = nil
        if started {
            MobileStop()
            started = false
        }
    }

    /// Extracts the raw file descriptor backing this extension's utun interface.
    /// NEPacketTunnelFlow does not expose it publicly; every userspace-WireGuard iOS
    /// app (WireGuard, AmneziaWG) relies on this same scan — the interface is a
    /// PF_SYSTEM/SYSPROTO_CONTROL "utun" control socket among the process's open fds.
    private func getTunnelFileDescriptor() -> Int32? {
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var ret: Int32 = -1
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    ret = getpeername(fd, $0, &len)
                }
            }
            if ret != 0 || addr.sc_family != AF_SYSTEM {
                continue
            }
            if ctlInfo.ctl_id == 0 {
                ret = ioctl(fd, FT_CTLIOCGINFO, &ctlInfo)
                if ret != 0 {
                    continue
                }
            }
            if addr.sc_id == ctlInfo.ctl_id {
                return fd
            }
        }
        return nil
    }
}

private func cidrToMask(_ prefix: Int) -> String {
    guard prefix >= 0, prefix <= 32 else { return "255.255.255.255" }
    let mask: UInt32 = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF
    return "\((mask >> 24) & 0xFF).\((mask >> 16) & 0xFF).\((mask >> 8) & 0xFF).\(mask & 0xFF)"
}

/// Minimal EventSink — logs go through Mobile's own ring buffer (DumpLogs), this just
/// needs to exist so the Go side has somewhere to push OnState/OnCaptcha without a nil
/// pointer. The extension has no UI of its own to render state changes into.
private final class TunnelEventSink: NSObject, MobileEventSinkProtocol {
    func onState(_ state: String?, streams: Int, total: Int, errMsg: String?) {
        SharedLog.write("[STATE] \(state ?? "?") streams=\(streams)/\(total) err=\(errMsg ?? "")")
    }
    func onLog(_ level: String?, msg: String?, unixMillis: Int64) {
        SharedLog.write("[\((level ?? "log").uppercased())] \(msg ?? "")")
    }
    func onCaptcha(_ url: String?) {
        // The URL carries a one-time captcha handle: keep it out of the log, the app gets
        // it over the control channel and the system notification.
        SharedLog.write("[CAPTCHA] " + (url == nil || url?.isEmpty == true ? "cleared" : "required"))
        SharedLog.captchaURL = url
        guard let url = url, !url.isEmpty, url != lastNotified else {
            if url == nil || url?.isEmpty == true { lastNotified = nil }
            return
        }
        lastNotified = url
        let content = UNMutableNotificationContent()
        content.title = "VK captcha required"
        content.body = "Tap to solve it in the browser"
        content.sound = .default
        content.userInfo = ["captchaURL": url]
        if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "captcha", content: content, trigger: nil))
    }
    private var lastNotified: String?
}
