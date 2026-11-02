import Foundation

/// One App Group as seen from the current process.
struct GroupProbeResult: Codable {
    var group: String
    /// "ok" if the container URL resolved, "nil" otherwise.
    var container: String
    var wrote: Bool
    /// Process tags ("app", "ext", "ctl") whose probe-<tag>.txt is visible in this container.
    var seen: [String]
}

/// Writes a marker file into every App Group listed in the embedded profile and reports which
/// other processes' markers are visible, so a group really shared by app and extension shows up.
enum GroupProbe {
    static var tag: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        if id.hasSuffix(".tunnel") { return "ext" }
        if id.hasSuffix(".control") { return "ctl" }
        return "app"
    }

    /// Probes the union of the profile's groups, `extra` and the currently chosen group.
    static func run(extra: [String] = []) -> [GroupProbeResult] {
        var groups: [String] = []
        for g in SharedLog.profileAppGroups() + extra + [SharedLog.groupID] where !groups.contains(g) { groups.append(g) }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let body = "build=\(build)\nbundleId=\(Bundle.main.bundleIdentifier ?? "?")\nt=\(Int(Date().timeIntervalSince1970))\n"
        return groups.map { g in
            guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) else {
                return GroupProbeResult(group: g, container: "nil", wrote: false, seen: [])
            }
            let wrote = (try? body.write(to: dir.appendingPathComponent("probe-\(tag).txt"),
                                         atomically: true, encoding: .utf8)) != nil
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let seen = files
                .filter { $0.hasPrefix("probe-") && $0.hasSuffix(".txt") }
                .map { String($0.dropFirst("probe-".count).dropLast(".txt".count)) }
                .sorted()
            return GroupProbeResult(group: g, container: "ok", wrote: wrote, seen: seen)
        }
    }

    /// Groups where both the app and the extension marker are visible.
    static func common(_ results: [GroupProbeResult]) -> [String] {
        results.filter { $0.seen.contains("app") && $0.seen.contains("ext") }.map { $0.group }
    }
}
