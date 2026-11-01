import Foundation

/// Simple append-only log file in the shared App Group container, since the
/// extension is a separate process from the main app and Mobile's own
/// DumpLogs() ring buffer lives in whichever process calls it.
enum SharedLog {
    /// App Group actually granted by the provisioning profile embedded by the signer, so it
    /// survives re-signing under any bundle id. Falls back to "group.<bundle id>".
    static let groupID: String = {
        var id = Bundle.main.bundleIdentifier ?? "com.purkalolka.freeturn"
        if id.hasSuffix(".tunnel") { id.removeLast(".tunnel".count) }
        if id.hasSuffix(".control") { id.removeLast(".control".count) }
        let derived = "group." + id
        let groups = profileAppGroups()
        if groups.contains(derived) { return derived }
        return groups.first ?? derived
    }()

    private static func profileAppGroups() -> [String] {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let start = raw.range(of: Data("<?xml".utf8)),
              let end = raw.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(
                from: raw.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let ents = plist["Entitlements"] as? [String: Any],
              let groups = ents["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups
    }

    /// In-memory copy, served to the app over sendProviderMessage so logs work even
    /// when the App Group container is unavailable.
    private static var memory = ""
    private static var memoryCaptcha = ""

    static func snapshot() -> [String: String] {
        queue.sync { ["log": memory, "captcha": memoryCaptcha] }
    }

    static func setMemoryCaptcha(_ v: String?) {
        queue.async { memoryCaptcha = v ?? "" }
    }
    static let fileName = "tunnel.log"

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(fileName)
    }

    private static let queue = DispatchQueue(label: "sharedlog")

    static func write(_ line: String) {
        queue.async {
            let ts = ISO8601DateFormatter().string(from: Date())
            let entry = "\(ts) \(line)\n"
            memory += entry
            if memory.count > 200_000 { memory = String(memory.suffix(100_000)) }
            guard let url = url else { return }
            guard let data = entry.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func clear() {
        queue.async {
            memory = ""
            guard let url = url else { return }
            try? "".data(using: .utf8)?.write(to: url)
        }
    }

    static func read() -> String {
        guard let url = url, let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static var captchaFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("captcha.url")
    }

    /// Manual-captcha URL published by the extension; empty/nil means nothing to solve.
    static var captchaURL: String? {
        get {
            guard let url = captchaFileURL, let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
            return s
        }
        set {
            setMemoryCaptcha(newValue)
            guard let url = captchaFileURL else { return }
            if let v = newValue, !v.isEmpty {
                try? v.data(using: .utf8)?.write(to: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
