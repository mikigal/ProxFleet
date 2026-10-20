/// Proxmox products share the same ticket-based authentication, differing only in names and ports.
public enum ProxmoxProduct: String, Codable, Sendable, CaseIterable {
    case virtualEnvironment
    case backupServer

    public var defaultPort: Int {
        switch self {
        case .virtualEnvironment: 8006
        case .backupServer: 8007
        }
    }

    public var authCookieName: String {
        switch self {
        case .virtualEnvironment: "PVEAuthCookie"
        case .backupServer: "PBSAuthCookie"
        }
    }

    /// Prefix of tickets issued by this product, e.g. `PVE:root@pam:...`.
    public var ticketPrefix: String {
        switch self {
        case .virtualEnvironment: "PVE"
        case .backupServer: "PBS"
        }
    }
}
