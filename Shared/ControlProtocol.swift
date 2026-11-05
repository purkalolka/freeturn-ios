import Foundation

/// Loopback control channel between the app and the tunnel extension.
///
/// It deliberately uses neither App Groups nor the provisioning profile nor
/// `sendProviderMessage`: a loopback TCP socket is available to both processes even when a
/// third-party signer gives the extension a different (or no) embedded profile.
enum ControlConfig {
    /// First port the extension tries; if it is taken it moves up the range. The app scans the
    /// same range, so a busy port never disables the channel.
    static let portRange: ClosedRange<UInt16> = 47831...47840
    /// Bumped when the message schema changes; both sides ignore messages from another version.
    static let version = 2
    /// Characters kept in the in-memory log ring and sent in a snapshot.
    static let logLimit = 200_000
    /// A connected client that has received nothing for this long is considered stale.
    static let staleAfter: TimeInterval = 6
    /// A slow client is cut off instead of growing the extension's memory without bound.
    static let maxPendingBytes = 1_000_000
}

/// One newline-delimited JSON message on the control channel.
struct ControlMessage: Codable {
    var v: Int = ControlConfig.version
    var type: String
    var token: String?
    var build: String?
    var port: UInt16?
    var state: String?
    var streams: Int?
    var total: Int?
    var log: String?
    var captcha: String?
    var cmd: String?
    /// Absolute UTF-8 byte offsets of the log text: `start` is the first byte of this batch,
    /// `end` is one past the last byte. The client uses them to ignore lines already covered
    /// by a snapshot and to detect gaps caused by backpressure.
    var offsetStart: Int?
    var offsetEnd: Int?
    var ts: Double?

    init(type: String) { self.type = type }

    private enum CodingKeys: String, CodingKey {
        case v, type, token, build, port, state, streams, total, log, captcha, cmd, offsetStart, offsetEnd, ts
    }
}

enum ControlFraming {
    static func encode(_ message: ControlMessage) -> Data? {
        guard var data = try? JSONEncoder().encode(message) else { return nil }
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data) -> ControlMessage? {
        guard let message = try? JSONDecoder().decode(ControlMessage.self, from: line),
              message.v == ControlConfig.version else { return nil }
        return message
    }
}
