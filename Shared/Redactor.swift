import Foundation

/// Keeps user-identifying data out of the extension log.
///
/// The log is streamed to the app over the control channel and persisted in the App Group
/// container, so it lives longer than any session. The VK invite link carries the call
/// access key, the captcha URL carries a one-time handle and VK API error bodies can echo
/// tokens — none of that belongs in a log file.
enum Redactor {

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        let specs: [(String, String)] = [
            // Share links: the key is part of the URI.
            (#"freeturn://\S+"#, "freeturn://<redacted>"),
            // VK call invites, captcha pages and API URLs.
            (#"https?://(?:[A-Za-z0-9.-]+\.)?(?:vk\.(?:com|ru|me)|userapi\.com)/\S+"#, "https://vk.com/<redacted>"),
            // Escaped URLs inside JSON debug dumps.
            (#"https?:\\/\\/\S+"#, "https://<redacted>"),
            // Token-ish query parameters.
            (#"(?i)([?&](?:access_token|token|sid|session|session_key|session_token|success_token|captcha_sid|captcha_img|captcha_ts|key|hash)=)[^&\s"']+"#, "$1<redacted>"),
            // The same values in JSON-ish API error bodies.
            (#"(?i)("(?:access_token|token|session_key|session_token|success_token|remixsid|remixnsid|captcha_sid|captcha_img|credential|password|secret)"\s*:\s*")[^",}\s]*"#, "$1<redacted>"),
            (#"(?i)\b(bearer\s+)[A-Za-z0-9._~+/-]+=*"#, "$1<redacted>"),
        ]
        return specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Rule(regex: regex, template: template)
        }
    }()

    private static let markers = [
        "freeturn://", "vk.com", "vk.ru", "vk.me", "userapi", "token", "session", "sid=", "captcha", "bearer",
    ]

    static func redact(_ line: String) -> String {
        guard markers.contains(where: { line.range(of: $0, options: .caseInsensitive) != nil }) else {
            return line
        }
        var out = line
        for rule in rules {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = rule.regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: rule.template)
        }
        return out
    }
}
