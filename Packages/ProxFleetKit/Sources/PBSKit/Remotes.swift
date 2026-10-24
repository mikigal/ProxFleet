import Foundation
import ProxmoxCore

/// Another Proxmox Backup Server that sync jobs pull from or push to, from `GET /config/remote`.
/// The password or token secret is never returned.
public struct BackupRemote: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var host: String
    public var port: Int?
    /// The user or API token the server signs in with, e.g. `sync@pbs` or `root@pam!sync`.
    public var authID: String
    public var fingerprint: String?
    public var comment: String?
    public var usesNodeProxy: Bool

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        host = container.lossyString(AnyCodingKey("host")) ?? ""
        port = container.lossyInt(AnyCodingKey("port"))
        authID = container.lossyString(AnyCodingKey("auth-id")) ?? ""
        fingerprint = container.lossyString(AnyCodingKey("fingerprint")).flatMap { $0.isEmpty ? nil : $0 }
        comment = container.lossyString(AnyCodingKey("comment")).flatMap { $0.isEmpty ? nil : $0 }
        usesNodeProxy = container.lossyBool(AnyCodingKey("use-node-proxy")) ?? false
    }

    /// `host` or `host:port`, with brackets around IPv6 addresses.
    public var address: String {
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port, port != 8007 else { return hostPart }
        return "\(hostPart):\(port)"
    }
}

/// A traffic control rule, from `GET /config/traffic-control`, or with the current rates from `GET /admin/traffic-control`.
public struct TrafficControlRule: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var comment: String?
    /// Networks the rule applies to, in CIDR form.
    public var networks: [String]
    /// Users the rule applies to, since 4.1.
    public var users: [String]
    /// Rates such as `100 MiB` per second; nil without a limit.
    public var rateIn: String?
    public var rateOut: String?
    public var burstIn: String?
    public var burstOut: String?
    /// When the rule applies, e.g. `mon..fri 8:00-18:00`; always when empty.
    public var timeframes: [String]
    /// Bytes per second right now; only in `GET /admin/traffic-control`.
    public var currentRateIn: Double?
    public var currentRateOut: Double?

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        comment = container.lossyString(AnyCodingKey("comment")).flatMap { $0.isEmpty ? nil : $0 }
        networks = container.stringList("network")
        users = container.stringList("users")
        rateIn = container.lossyString(AnyCodingKey("rate-in"))
        rateOut = container.lossyString(AnyCodingKey("rate-out"))
        burstIn = container.lossyString(AnyCodingKey("burst-in"))
        burstOut = container.lossyString(AnyCodingKey("burst-out"))
        timeframes = container.stringList("timeframe")
        currentRateIn = container.lossyDouble(AnyCodingKey("cur-rate-in"))
        currentRateOut = container.lossyDouble(AnyCodingKey("cur-rate-out"))
    }
}

extension PBS {
    public static func remotes() -> APIRequest<Digested<[BackupRemote]>> {
        APIRequest(.get, "/config/remote")
    }

    public static func remote(_ name: String) -> APIRequest<Digested<BackupRemote>> {
        APIRequest(.get, "/config/remote/\(escapePath(name))")
    }

    public static func deleteRemote(_ name: String, digest: String? = nil) -> APIRequest<Nothing> {
        APIRequest(.delete, "/config/remote/\(escapePath(name))", parameters: digest.map { ["digest": .string($0)] } ?? APIParameters())
    }

    /// Datastores of a remote, as its configured user sees them.
    public static func remoteDatastores(_ remote: String) -> APIRequest<[DatastoreSummary]> {
        APIRequest(.get, "/config/remote/\(escapePath(remote))/scan")
    }

    public static func remoteNamespaces(_ remote: String, store: String) -> APIRequest<[BackupNamespace]> {
        APIRequest(.get, "/config/remote/\(escapePath(remote))/scan/\(escapePath(store))/namespaces")
    }

    public static func remoteGroups(_ remote: String, store: String, namespace: BackupNamespace = .root) -> APIRequest<[BackupGroup]> {
        APIRequest(.get, "/config/remote/\(escapePath(remote))/scan/\(escapePath(store))/groups",
                   parameters: namespace.isRoot ? APIParameters() : ["namespace": .string(namespace.path)])
    }

    public static func trafficControlRules() -> APIRequest<Digested<[TrafficControlRule]>> {
        APIRequest(.get, "/config/traffic-control")
    }

    /// The rules with the traffic they let through right now.
    public static func trafficControlStatus() -> APIRequest<[TrafficControlRule]> {
        APIRequest(.get, "/admin/traffic-control")
    }

    public static func deleteTrafficControlRule(_ name: String, digest: String? = nil) -> APIRequest<Nothing> {
        APIRequest(.delete, "/config/traffic-control/\(escapePath(name))", parameters: digest.map { ["digest": .string($0)] } ?? APIParameters())
    }
}
