import Foundation
import ProxmoxCore

/// `GET /nodes/{node}/dns`: the search domain and up to three name servers from `/etc/resolv.conf`.
public struct NodeDNS: Decodable, Sendable, Equatable {
    public var searchDomain: String
    /// Always three entries; empty strings for unset servers.
    public var servers: [String]

    public init(searchDomain: String = "", servers: [String] = []) {
        self.searchDomain = searchDomain
        self.servers = (servers + ["", "", ""]).prefix(3).map { $0 }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(
            searchDomain: container.lossyString(AnyCodingKey("search")) ?? "",
            servers: (1...3).map { container.lossyString(AnyCodingKey("dns\($0)")) ?? "" }
        )
    }

    /// Parameters of `PUT /nodes/{node}/dns`. Servers left out are removed; `search` is required.
    var parameters: APIParameters {
        var parameters: APIParameters = ["search": .string(searchDomain.trimmingCharacters(in: .whitespaces))]
        // Empty fields in between are skipped, so the remaining servers move up as in resolv.conf.
        let set = servers.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (index, server) in set.enumerated() {
            parameters["dns\(index + 1)"] = .string(server)
        }
        return parameters
    }
}

/// `GET /nodes/{node}/hosts`: the text of `/etc/hosts` and its digest.
public struct NodeHosts: Decodable, Sendable, Equatable {
    public var text: String
    public var digest: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        text = container.lossyString(AnyCodingKey("data")) ?? ""
        digest = container.lossyString(AnyCodingKey("digest"))
    }
}

/// `GET /nodes/{node}/time`: the node's clock and time zone.
public struct NodeTime: Decodable, Sendable, Equatable {
    /// For example `Europe/Warsaw`.
    public var timeZone: String
    /// The node's clock when it was read.
    public var time: Date
    /// When it was read, to advance the clock locally.
    public var readAt = Date()

    /// The node's clock now, assuming it runs at the same pace as this device's.
    public func clock(at date: Date = Date()) -> Date {
        time.addingTimeInterval(date.timeIntervalSince(readAt))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        timeZone = container.lossyString(AnyCodingKey("timezone")) ?? "UTC"
        time = Date(timeIntervalSince1970: TimeInterval(container.lossyInt(AnyCodingKey("time")) ?? 0))
    }

    /// Time zone names grouped by region, e.g. `Europe` → `Europe/Warsaw`, for a picker.
    /// Proxmox accepts the names from `/usr/share/zoneinfo/zone.tab`, which matches the system's list.
    public static func zonesByRegion(_ identifiers: [String] = TimeZone.knownTimeZoneIdentifiers) -> [(region: String, zones: [String])] {
        let grouped = Dictionary(grouping: identifiers.filter { $0.contains("/") }) { String($0.prefix { $0 != "/" }) }
        return grouped.keys.sorted().map { (region: $0, zones: grouped[$0]!.sorted()) } + [(region: "UTC", zones: ["UTC"])]
    }
}

extension PVE {
    public static func nodeDNS(_ node: String) -> APIRequest<NodeDNS> {
        APIRequest(.get, "/nodes/\(node)/dns")
    }

    public static func updateNodeDNS(_ node: String, _ dns: NodeDNS) -> APIRequest<Nothing> {
        APIRequest(.put, "/nodes/\(node)/dns", parameters: dns.parameters)
    }

    public static func nodeHosts(_ node: String) -> APIRequest<NodeHosts> {
        APIRequest(.get, "/nodes/\(node)/hosts")
    }

    /// Replaces `/etc/hosts`. With a digest, the server refuses when the file changed since it was read.
    public static func updateNodeHosts(_ node: String, text: String, digest: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["data": .string(text)]
        if let digest { parameters["digest"] = .string(digest) }
        return APIRequest(.post, "/nodes/\(node)/hosts", parameters: parameters)
    }

    public static func nodeTime(_ node: String) -> APIRequest<NodeTime> {
        APIRequest(.get, "/nodes/\(node)/time")
    }

    public static func setNodeTimeZone(_ node: String, _ timeZone: String) -> APIRequest<Nothing> {
        APIRequest(.put, "/nodes/\(node)/time", parameters: ["timezone": .string(timeZone)])
    }
}
