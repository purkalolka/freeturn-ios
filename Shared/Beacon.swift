import Foundation

enum BeaconConfig {
    /// UDP port on 127.0.0.1 that the app listens on and the tunnel extension sends to.
    static let port: UInt16 = 47831
}

/// Extension -> app status datagram. `token` is a random value the app passes in
/// providerConfiguration, so stray packets from another instance are ignored.
struct BeaconPacket: Codable {
    var token: String
    var build: String
    var streams: Int?
    var total: Int?
}
