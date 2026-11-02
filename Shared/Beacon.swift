import Foundation

enum BeaconConfig {
    /// UDP port on 127.0.0.1 that the app listens on and the tunnel extension sends to.
    static let port: UInt16 = 47831
}

/// Extension -> app datagram. type "state" carries identity/probes, type "log" carries logTail.
struct BeaconPacket: Codable {
    var type: String
    var build: String?
    var bundleId: String?
    var groupID: String?
    var profileGroups: [String]?
    var probes: [GroupProbeResult]?
    var streams: Int?
    var total: Int?
    var t: Int?
    var logTail: [String]?
    var profilePresent: Bool?
    var profileSize: Int?
    var profileParseOK: Bool?
    var profileGroupsCount: Int?
    var entitledGroups: [String]?
    var handleAppMessageCount: Int?
    var chosenGroup: String?
}
