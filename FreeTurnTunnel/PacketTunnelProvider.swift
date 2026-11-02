import NetworkExtension
import Darwin
import Mobile
import UserNotifications
import Network
import WidgetKit

/// System VPN entry point. The Go core (Mobile.xcframework) runs WireGuard/AmneziaWG
/// entirely in-process, talking to the TURN relay through an in-memory pipe — there is
/// no local loopback socket to exclude from the tunnel, unlike a separate relay process.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var started = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        SharedLog.clear()
        SharedLog.captchaURL = nil
        beacon.start()
        MobileTuneForExtension()
        SharedLog.write("[EXT] startTunnel called, build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"), group \(SharedLog.groupID)")
        let conf = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        guard let configJSON = conf["configJSON"] as? String,
              let wgText = conf["wgText"] as? String,
              let mtu = conf["mtu"] as? Int else {
            SharedLog.write("[EXT] ERROR missing provider configuration")
            completionHandler(NSError(domain: "FreeTurn", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing provider configuration"]))
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

            guard let fd = self.getTunnelFileDescriptor() else {
                SharedLog.write("[EXT] ERROR could not find tun fd")
                completionHandler(NSError(domain: "FreeTurn", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "could not find tun file descriptor"]))
                return
            }
            SharedLog.write("[EXT] found tun fd=\(fd)")

            let sink = TunnelEventSink()
            MobileSetEventSink(sink)
            self.eventSink = sink

            SharedLog.write("[EXT] calling MobileStartTunnel...")
            var startErr: NSError?
            MobileStartTunnel(configJSON, Int(fd), &startErr)
            if let startErr = startErr {
                SharedLog.write("[EXT] ERROR MobileStartTunnel: \(startErr.localizedDescription)")
                completionHandler(startErr)
                return
            }
            SharedLog.write("[EXT] MobileStartTunnel returned OK")

            self.started = true
            if #available(iOS 18.0, *) { ControlCenter.shared.reloadControls(ofKind: "FreeTurnToggle") }
            // GCD timer: this callback runs on a queue with no active run loop, so Timer would never fire.
            let t = DispatchSource.makeTimerSource(queue: self.workQueue)
            t.schedule(deadline: .now() + 2, repeating: 10)
            t.setEventHandler { [weak self] in
                SharedLog.write("[MEM] \(MobileMemStats())")
                self?.watchStreams()
            }
            t.resume()
            self.memTimer = t
            self.startPathMonitor()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        SharedLog.write("[EXT] stopTunnel reason=\(reason.rawValue)")
        beacon.stop()
        memTimer?.cancel()
        memTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if started {
            MobileStop()
            started = false
        }
        completionHandler()
    }

    private var eventSink: TunnelEventSink?
    private let beacon = BeaconSender()
    private var memTimer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private let workQueue = DispatchQueue(label: "freeturn.work")
    private var lastPathKey: String?
    private var degradedSince: Date?
    private var lastReconnect = Date.distantPast

    override func wake() {
        SharedLog.write("[EXT] wake - refreshing TURN allocations")
        reconnect(reason: "wake")
    }

    /// Mirrors the Android client's NetworkHandoverMonitor: after Wi-Fi/cellular switches
    /// the old TURN sockets are dead, but the Go core cannot see the network change itself.
    private func startPathMonitor() {
        // .other excludes our own utun interface.
        let m = NWPathMonitor(prohibitedInterfaceTypes: [.other])
        m.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let key = path.status == .satisfied
                ? path.availableInterfaces.map { $0.name }.sorted().joined(separator: ",")
                : "none"
            defer { self.lastPathKey = key }
            guard let prev = self.lastPathKey, prev != key, key != "none" else { return }
            SharedLog.write("[EXT] network changed \(prev) -> \(key)")
            self.reconnect(reason: "network change")
        }
        m.start(queue: workQueue)
        pathMonitor = m
    }

    /// Streams that stay below the target for a while are not coming back by themselves.
    private func watchStreams() {
        guard let st = MobileGetState(), st.total > 0, st.state == "connected" || st.state == "connecting" else {
            degradedSince = nil
            return
        }
        if st.streams >= st.total { degradedSince = nil; return }
        let since = degradedSince ?? Date()
        degradedSince = since
        if Date().timeIntervalSince(since) > 45 {
            degradedSince = nil
            SharedLog.write("[EXT] streams \(st.streams)/\(st.total) for 45s - reconnecting")
            reconnect(reason: "watchdog")
        }
    }

    private func reconnect(reason: String) {
        workQueue.async {
            guard self.started, Date().timeIntervalSince(self.lastReconnect) > 15 else { return }
            self.lastReconnect = Date()
            SharedLog.write("[EXT] reconnect (\(reason))")
            if reason == "wake" { MobileWake() } else { MobileReconnect() }
        }
    }

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
        SharedLog.write("[CAPTCHA] \(url ?? "(cleared)")")
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
