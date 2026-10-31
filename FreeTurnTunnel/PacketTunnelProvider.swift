import NetworkExtension
import Darwin
import Mobile

/// System VPN entry point. The Go core (Mobile.xcframework) runs WireGuard/AmneziaWG
/// entirely in-process, talking to the TURN relay through an in-memory pipe — there is
/// no local loopback socket to exclude from the tunnel, unlike a separate relay process.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var started = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        SharedLog.clear()
        SharedLog.captchaURL = nil
        SharedLog.write("[EXT] startTunnel called")
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

        // The Go core only speaks IPv4 - without this, iOS leaves IPv6 on the device's
        // real interface, and IPv6-preferring destinations (Happy Eyeballs, e.g. Google)
        // bypass the tunnel entirely instead of failing over to the tunneled IPv4 path.
        let ipv6 = NEIPv6Settings(addresses: ["fd00:0:0:0:0:0:0:1"], networkPrefixLengths: [128])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

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
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        SharedLog.write("[EXT] stopTunnel reason=\(reason.rawValue)")
        if started {
            MobileStop()
            started = false
        }
        completionHandler()
    }

    private var eventSink: TunnelEventSink?

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
    }
}
