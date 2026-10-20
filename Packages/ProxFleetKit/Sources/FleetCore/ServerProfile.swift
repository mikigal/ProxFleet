import Foundation
import ProxmoxCore

/// A saved server: a standalone node or a whole cluster, reachable through one or more addresses.
public struct ServerProfile: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var product: ProxmoxProduct
    /// Tried in order. For clusters these are the addresses of different nodes.
    public var addresses: [ServerAddress]
    /// User name without the realm, as typed on the login screen.
    public var username: String
    public var realm: String
    /// SHA-256 fingerprints of self-signed certificates the user accepted.
    public var trustedFingerprints: [String]
    /// Name of the cluster this server belongs to, learned at login. Used to detect duplicates.
    public var clusterName: String?
    public var isDemo: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        product: ProxmoxProduct = .virtualEnvironment,
        addresses: [ServerAddress],
        username: String,
        realm: String,
        trustedFingerprints: [String] = [],
        clusterName: String? = nil,
        isDemo: Bool = false
    ) {
        self.id = id
        self.name = name
        self.product = product
        self.addresses = addresses
        self.username = username
        self.realm = realm
        self.trustedFingerprints = trustedFingerprints
        self.clusterName = clusterName
        self.isDemo = isDemo
    }

    /// Full user ID such as `root@pam`.
    public var userID: String {
        username.contains("@") ? username : "\(username)@\(realm)"
    }

    public var primaryAddress: ServerAddress? { addresses.first }

    public var addressSummary: String {
        guard let primary = addresses.first else { return "" }
        let text = primary.displayString(defaultPort: product.defaultPort)
        return addresses.count > 1 ? "\(text) +\(addresses.count - 1)" : text
    }
}
