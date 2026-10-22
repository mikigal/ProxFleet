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

/// `GET /nodes/{node}/config`: notes and options of a node, stored in `/etc/pve/nodes/{node}/config`.
public struct NodeOptions: Decodable, Sendable, Equatable {
    public var values: [String: String]
    public var digest: String?

    public init(values: [String: String] = [:], digest: String? = nil) {
        self.values = values
        self.digest = digest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: String] = [:]
        for key in container.allKeys where key.stringValue != "digest" {
            if let value = container.lossyString(key) { values[key.stringValue] = value }
        }
        self.values = values
        digest = container.lossyString(AnyCodingKey("digest"))
    }

    /// Notes shown in the web interface's node summary, in Markdown. Proxmox adds a trailing newline.
    public var notes: String {
        (values["description"] ?? "").trimmingCharacters(in: .newlines)
    }

    /// The MAC address other nodes send the wake-on-LAN packet to, if set.
    public var wakeOnLANAddress: String? {
        let property = PropertyString(parsing: values["wakeonlan"] ?? "")
        return property["mac"] ?? property.defaultValue
    }
}

/// The options of the web interface's node Options panel: wake on LAN, start-at-boot delay and ballooning target.
public struct NodeOptionsDraft: OptionsDraft, Sendable {
    public var macAddress: String
    /// Interface to send the packet from, empty for the one carrying the default route.
    public var bindInterface: String
    /// Empty for 255.255.255.255.
    public var broadcastAddress: String
    /// Seconds before guests with Start at Boot are started, empty for none.
    public var startDelay: String
    /// RAM usage target for ballooning in percent, empty for the default of 80.
    public var ballooningTarget: String
    /// Overrides the datacenter's location for this node.
    public var location: Location
    private var otherWakeOnLANOptions: PropertyString

    public init(_ options: NodeOptions) {
        let wakeOnLAN = PropertyString(parsing: options.values["wakeonlan"] ?? "")
        macAddress = wakeOnLAN["mac"] ?? wakeOnLAN.defaultValue ?? ""
        bindInterface = wakeOnLAN["bind-interface"] ?? ""
        broadcastAddress = wakeOnLAN["broadcast-address"] ?? ""
        otherWakeOnLANOptions = PropertyString(items: wakeOnLAN.items.filter { $0.key != nil && !["mac", "bind-interface", "broadcast-address"].contains($0.key!) })
        startDelay = options.values["startall-onboot-delay"] ?? ""
        ballooningTarget = options.values["ballooning-target"] ?? ""
        location = Location(options.values["location"])
    }

    public func serialized() -> [String: String?] {
        var wakeOnLAN = PropertyString(items: [])
        let mac = macAddress.trimmed
        if !mac.isEmpty {
            wakeOnLAN.items.append((key: nil, value: mac.uppercased()))
            if !bindInterface.trimmed.isEmpty { wakeOnLAN["bind-interface"] = bindInterface.trimmed }
            if !broadcastAddress.trimmed.isEmpty { wakeOnLAN["broadcast-address"] = broadcastAddress.trimmed }
            wakeOnLAN.items += otherWakeOnLANOptions.items
        }
        return [
            "wakeonlan": wakeOnLAN.items.isEmpty ? nil : wakeOnLAN.stringValue,
            "startall-onboot-delay": startDelay.trimmed.isEmpty ? nil : startDelay.trimmed,
            "ballooning-target": ballooningTarget.trimmed.isEmpty ? nil : ballooningTarget.trimmed,
            "location": location.serialized,
        ]
    }

    /// Settings without a MAC address cannot be stored, so the interface and broadcast address need one.
    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if macAddress.trimmed.isEmpty, !(bindInterface.trimmed.isEmpty && broadcastAddress.trimmed.isEmpty) {
            problems["wakeonlan"] = String(localized: "Enter the MAC address of the node's network card.")
        }
        if let problem = location.problem { problems["location"] = problem }
        return problems
    }
}

extension PVE {
    public static func nodeOptions(_ node: String) -> APIRequest<NodeOptions> {
        APIRequest(.get, "/nodes/\(node)/config")
    }

    /// Changes notes and options of a node. Needs `Sys.Modify` on `/`.
    public static func updateNodeOptions(_ node: String, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/nodes/\(node)/config", parameters: update.parameters)
    }

    /// Sends a wake-on-LAN packet for `node` from the node the app is connected to. Returns the MAC address used.
    public static func wakeOnLAN(_ node: String) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(node)/wakeonlan")
    }

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
