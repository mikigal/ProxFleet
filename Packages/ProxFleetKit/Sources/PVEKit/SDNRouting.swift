import Foundation
import ProxmoxCore

// The routing side of SDN: controllers (BGP sessions for EVPN zones), fabrics (routed underlays between nodes),
// and the prefix lists and route maps that filter their routes. All of it is pending until Apply, like zones.

// MARK: - Controllers

/// Controller types the web interface creates. Faucet controllers exist in the API only.
public enum SDNControllerType: String, CaseIterable, Sendable, Identifiable {
    case evpn, bgp, isis

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .evpn: String(localized: "EVPN")
        case .bgp: String(localized: "BGP")
        case .isis: String(localized: "IS-IS")
        }
    }

    /// BGP and IS-IS controllers belong to one node and are named after it.
    public var isPerNode: Bool { self != .evpn }
}

/// The form for a controller. Only the settings of its type are sent.
public struct SDNControllerDraft: Equatable, Sendable {
    public var id = ""
    public var type = SDNControllerType.evpn
    public var asn = "65000"
    public var peers = ""
    /// EVPN: a fabric as underlay instead of peers.
    public var fabric = ""
    public var routeMapIn = ""
    public var routeMapOut = ""
    public var peerGroupName = ""
    /// EVPN: the nodes that run it; empty for all.
    public var nodes: Set<String> = []
    /// EVPN: `auto`, `external` or `internal`; empty for automatic.
    public var bgpMode = ""
    public var ebgpMultihop = ""
    /// BGP and IS-IS.
    public var node = ""
    public var loopback = ""
    public var ebgp = false
    public var multipathRelax = false
    public var isisDomain = ""
    public var isisNet = ""
    public var isisInterfaces = ""

    public init(type: SDNControllerType = .evpn) {
        self.type = type
    }

    public init(_ controller: SDNObject) {
        let values = controller.values
        id = controller.id
        type = SDNControllerType(rawValue: controller.type) ?? .evpn
        asn = values["asn"] ?? ""
        peers = values["peers"] ?? ""
        fabric = values["fabric"] ?? ""
        routeMapIn = values["route-map-in"] ?? ""
        routeMapOut = values["route-map-out"] ?? ""
        peerGroupName = values["peer-group-name"] ?? ""
        nodes = Set((values["nodes"] ?? "").split(separator: ",").map(String.init))
        bgpMode = values["bgp-mode"] ?? ""
        ebgpMultihop = values["ebgp-multihop"] ?? ""
        node = values["node"] ?? ""
        loopback = values["loopback"] ?? ""
        ebgp = values["ebgp"] == "1"
        multipathRelax = values["bgp-multipath-as-path-relax"] == "1"
        isisDomain = values["isis-domain"] ?? ""
        isisNet = values["isis-net"] ?? ""
        isisInterfaces = values["isis-ifaces"] ?? ""
    }

    /// The ID sent on creation: BGP and IS-IS controllers are named `bgp<node>` and `isis<node>`, as in the web
    /// interface.
    public var resolvedID: String {
        switch type {
        case .evpn: id.trimmingCharacters(in: .whitespaces)
        case .bgp: "bgp\(node)"
        case .isis: "isis\(node)"
        }
    }

    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        switch type {
        case .evpn:
            set("asn", trimmed(asn))
            set("peers", commaList(peers))
            set("fabric", trimmed(fabric))
            set("route-map-in", trimmed(routeMapIn))
            set("route-map-out", trimmed(routeMapOut))
            set("peer-group-name", trimmed(peerGroupName))
            set("nodes", nodes.isEmpty ? nil : nodes.sorted().joined(separator: ","))
            set("bgp-mode", trimmed(bgpMode))
            set("ebgp-multihop", trimmed(ebgpMultihop))
        case .bgp:
            set("node", trimmed(node))
            set("asn", trimmed(asn))
            set("peers", commaList(peers))
            set("ebgp", ebgp ? "1" : nil)
            set("loopback", trimmed(loopback))
            set("ebgp-multihop", trimmed(ebgpMultihop))
            set("bgp-multipath-as-path-relax", multipathRelax ? "1" : nil)
            set("route-map-in", trimmed(routeMapIn))
            set("route-map-out", trimmed(routeMapOut))
        case .isis:
            set("node", trimmed(node))
            set("isis-domain", trimmed(isisDomain))
            set("isis-net", trimmed(isisNet))
            set("isis-ifaces", commaList(isisInterfaces))
            set("loopback", trimmed(loopback))
        }
        return values
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["controller": .string(resolvedID), "type": .string(type.rawValue)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        return parameters
    }

    public func changes(from original: SDNControllerDraft) -> SDNUpdate {
        var update = SDNUpdate.between(original.serialized(), serialized())
        // The node is part of the ID and cannot change.
        update.values["node"] = nil
        update.deletions.remove("node")
        return update
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, type == .evpn, let problem = identifierProblem(id.trimmingCharacters(in: .whitespaces)) { problems["controller"] = problem }
        if type.isPerNode, trimmed(node) == nil { problems["node"] = String(localized: "Choose a node.") }
        if type != .isis, !(trimmed(asn).flatMap { UInt32($0) }.map { $0 >= 1 } ?? false) {
            problems["asn"] = String(localized: "Use a number from 1 to 4294967295.")
        }
        if type == .bgp, trimmed(peers) == nil { problems["peers"] = String(localized: "Enter the addresses of the peers.") }
        if type == .evpn, trimmed(peers) == nil, trimmed(fabric) == nil {
            problems["peers"] = String(localized: "Enter the addresses of the peers, or choose a fabric.")
        }
        for address in (commaList(peers) ?? "").split(separator: ",") where !SDNSubnetDraft.isAddress(String(address)) {
            problems["peers"] = String(localized: "\(String(address)) is not an IP address.")
        }
        if let hops = trimmed(ebgpMultihop), !(Int(hops).map { (1...100).contains($0) } ?? false) {
            problems["ebgp-multihop"] = String(localized: "Use a number from 1 to 100.")
        }
        if type == .isis {
            if trimmed(isisDomain) == nil { problems["isis-domain"] = String(localized: "Enter the IS-IS domain.") }
            if trimmed(isisInterfaces) == nil { problems["isis-ifaces"] = String(localized: "Enter at least one interface.") }
            if !Self.isNetworkEntityTitle(isisNet.trimmingCharacters(in: .whitespaces)) {
                problems["isis-net"] = String(localized: "Use the form 49.0001.1921.6800.1001.00.")
            }
        }
        return problems
    }

    /// `49.0001.1921.6800.1001.00`: two hex digits, three to nine groups of four, two hex digits.
    static func isNetworkEntityTitle(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts.count <= 11, parts.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) else { return false }
        return parts.first?.count == 2 && parts.last?.count == 2 && parts.dropFirst().dropLast().allSatisfy { $0.count == 4 }
    }
}

// MARK: - Fabrics

/// Fabric protocols the app sets up. WireGuard fabrics, with their keys and external peers, are left to the web
/// interface.
public enum SDNFabricProtocol: String, CaseIterable, Sendable, Identifiable {
    case openfabric, ospf, bgp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openfabric: String(localized: "OpenFabric")
        case .ospf: String(localized: "OSPF")
        case .bgp: String(localized: "BGP")
        }
    }

    /// OSPF fabrics are IPv4 only.
    public var supportsIPv6: Bool { self != .ospf }

    /// Sources other routes can be redistributed from into the fabric; OpenFabric has none.
    public var redistributionSources: [String] {
        switch self {
        case .openfabric: []
        case .ospf: ["bgp", "connected", "static", "kernel"]
        case .bgp: ["ospf", "connected", "static", "kernel"]
        }
    }
}

/// `source=connected,route-map=rm1`: routes of another protocol announced in the fabric.
public struct SDNRedistribution: Sendable, Hashable {
    public var source: String
    public var routeMap: String

    public init(source: String, routeMap: String = "") {
        self.source = source
        self.routeMap = routeMap
    }

    init?(propertyString text: String) {
        let property = PropertyString(parsing: text)
        guard let source = property["source"] else { return nil }
        self.init(source: source, routeMap: property["route-map"] ?? "")
    }

    var propertyString: String {
        trimmed(routeMap).map { "source=\(source),route-map=\($0)" } ?? "source=\(source)"
    }
}

/// The form for a fabric: the address ranges its nodes use and the protocol's settings.
public struct SDNFabricDraft: Equatable, Sendable {
    public var id = ""
    public var protocolType = SDNFabricProtocol.openfabric
    public var ipPrefix = ""
    public var ip6Prefix = ""
    /// OpenFabric timers in seconds; empty for the defaults (3 and 10).
    public var helloInterval = ""
    public var csnpInterval = ""
    /// OSPF area, a number or an IPv4 address; empty for area 0.
    public var area = ""
    /// A prefix list for the routes installed in the nodes' routing tables.
    public var routeFilter = ""
    public var redistribution: [SDNRedistribution] = []
    /// BGP.
    public var bfd = false
    public var routeMapIn = ""
    public var routeMapOut = ""

    public init(protocol protocolType: SDNFabricProtocol = .openfabric) {
        self.protocolType = protocolType
    }

    public init(_ fabric: SDNObject) {
        let values = fabric.values
        id = fabric.id
        protocolType = SDNFabricProtocol(rawValue: values["protocol"] ?? "") ?? .openfabric
        ipPrefix = values["ip_prefix"] ?? ""
        ip6Prefix = values["ip6_prefix"] ?? ""
        helloInterval = values["hello_interval"] ?? ""
        csnpInterval = values["csnp_interval"] ?? ""
        area = values["area"] ?? ""
        routeFilter = values["route_filter"] ?? ""
        redistribution = (fabric.lists["redistribute"] ?? []).compactMap(SDNRedistribution.init(propertyString:))
        bfd = values["bfd"] == "1"
        routeMapIn = values["route_map_in"] ?? ""
        routeMapOut = values["route_map_out"] ?? ""
    }

    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("ip_prefix", trimmed(ipPrefix))
        if protocolType.supportsIPv6 { set("ip6_prefix", trimmed(ip6Prefix)) }
        set("route_filter", trimmed(routeFilter))
        switch protocolType {
        case .openfabric:
            set("hello_interval", trimmed(helloInterval))
            set("csnp_interval", trimmed(csnpInterval))
        case .ospf:
            set("area", trimmed(area) ?? "0")
        case .bgp:
            set("bfd", bfd ? "1" : nil)
            set("route_map_in", trimmed(routeMapIn))
            set("route_map_out", trimmed(routeMapOut))
        }
        return values
    }

    func serializedLists() -> [String: [String]] {
        protocolType.redistributionSources.isEmpty ? [:] : ["redistribute": redistribution.map(\.propertyString)]
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["id": .string(id.trimmingCharacters(in: .whitespaces)), "protocol": .string(protocolType.rawValue)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        for item in serializedLists()["redistribute"] ?? [] { parameters.append("redistribute", .string(item)) }
        return parameters
    }

    public func changes(from original: SDNFabricDraft) -> SDNUpdate {
        var update = SDNUpdate.between(original.serialized(), serialized(), oldLists: original.serializedLists(), newLists: serializedLists())
        update.repeatsDeletions = true
        return update
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        let id = id.trimmingCharacters(in: .whitespaces)
        if isNew, !Self.isFabricID(id) { problems["id"] = String(localized: "2 to 8 letters, digits and dashes, not starting or ending with a dash.") }
        let ipv4 = trimmed(ipPrefix), ipv6 = protocolType.supportsIPv6 ? trimmed(ip6Prefix) : nil
        if ipv4 == nil, ipv6 == nil {
            problems["ip_prefix"] = protocolType.supportsIPv6 ? String(localized: "Enter an IPv4 or IPv6 prefix.") : String(localized: "Enter an IPv4 prefix.")
        }
        if let ipv4, !isCIDR(ipv4, ipv6: false) { problems["ip_prefix"] = String(localized: "Enter a network with its prefix length, e.g. 10.0.0.0/24.") }
        if let ipv6, !isCIDR(ipv6, ipv6: true) { problems["ip6_prefix"] = String(localized: "Enter a network with its prefix length, e.g. fd00::/64.") }
        for (key, value) in [("hello_interval", helloInterval), ("csnp_interval", csnpInterval)] where protocolType == .openfabric {
            if let value = trimmed(value), !(Int(value).map { (1...600).contains($0) } ?? false) {
                problems[key] = String(localized: "Use a number from 1 to 600.")
            }
        }
        if protocolType == .ospf {
            if let area = trimmed(area), !(UInt32(area) != nil || SDNSubnetDraft.isIPv4(area)) { problems["area"] = String(localized: "Use a number or an IPv4 address.") }
        }
        return problems
    }

    static func isFabricID(_ id: String) -> Bool {
        guard (2...8).contains(id.count), id.first != "-", id.last != "-" else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }
}

/// `10.0.0.0/24` or `fd00::/64`.
func isCIDR(_ text: String, ipv6: Bool) -> Bool {
    let parts = text.split(separator: "/")
    guard parts.count == 2, let length = Int(parts[1]), (0...(ipv6 ? 128 : 32)).contains(length) else { return false }
    return ipv6 ? parts[0].contains(":") && SDNSubnetDraft.isAddress(String(parts[0])) : SDNSubnetDraft.isIPv4(String(parts[0]))
}

/// An interface of a node in a fabric, `name=ens19,ip=10.0.0.1/31`. Settings the form does not show (the
/// OpenFabric hello multiplier) are kept.
public struct SDNFabricInterface: Sendable, Hashable, Identifiable {
    public var name: String
    public var ip = ""
    public var ip6 = ""
    /// OSPF: `broadcast`, `non-broadcast`, `point-to-multipoint` or `point-to-point`; empty for automatic.
    public var networkType = ""
    public var helloMultiplier = ""

    public var id: String { name }

    public static let networkTypes = ["broadcast", "non-broadcast", "point-to-multipoint", "point-to-point"]

    public init(name: String) {
        self.name = name
    }

    init?(propertyString text: String) {
        let property = PropertyString(parsing: text)
        guard let name = property["name"] else { return nil }
        self.name = name
        ip = property["ip"] ?? ""
        ip6 = property["ip6"] ?? ""
        networkType = property["network_type"] ?? ""
        helloMultiplier = property["hello_multiplier"] ?? ""
    }

    func propertyString(for protocolType: SDNFabricProtocol) -> String {
        var items = ["name=\(name)"]
        if protocolType != .bgp, let ip = trimmed(ip) { items.append("ip=\(ip)") }
        if protocolType == .openfabric {
            if let ip6 = trimmed(ip6) { items.append("ip6=\(ip6)") }
            if let multiplier = trimmed(helloMultiplier) { items.append("hello_multiplier=\(multiplier)") }
        }
        if protocolType == .ospf, let type = trimmed(networkType) { items.append("network_type=\(type)") }
        return items.joined(separator: ",")
    }
}

/// The form for a node in a fabric: its router addresses inside the fabric's prefixes and the interfaces that
/// connect it to the other nodes.
public struct SDNFabricNodeDraft: Equatable, Sendable {
    public var node = ""
    public var protocolType: SDNFabricProtocol
    public var ip = ""
    public var ip6 = ""
    /// BGP: the node's own AS number.
    public var asn = ""
    public var interfaces: [SDNFabricInterface] = []

    public init(protocol protocolType: SDNFabricProtocol) {
        self.protocolType = protocolType
    }

    public init(_ node: SDNObject) {
        let values = node.values
        self.node = node.id
        protocolType = SDNFabricProtocol(rawValue: values["protocol"] ?? "") ?? .openfabric
        ip = values["ip"] ?? ""
        ip6 = values["ip6"] ?? ""
        asn = values["asn"] ?? ""
        interfaces = (node.lists["interfaces"] ?? []).compactMap(SDNFabricInterface.init(propertyString:))
    }

    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("ip", trimmed(ip))
        if protocolType.supportsIPv6 { set("ip6", trimmed(ip6)) }
        if protocolType == .bgp { set("asn", trimmed(asn)) }
        return values
    }

    func serializedLists() -> [String: [String]] {
        ["interfaces": interfaces.map { $0.propertyString(for: protocolType) }]
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["node_id": .string(node), "protocol": .string(protocolType.rawValue)]
        // BGP fabrics also know external nodes; the ones the web interface adds are the cluster's own.
        if protocolType == .bgp { parameters["role"] = "internal" }
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        for item in serializedLists()["interfaces"] ?? [] { parameters.append("interfaces", .string(item)) }
        return parameters
    }

    public func changes(from original: SDNFabricNodeDraft) -> SDNUpdate {
        var update = SDNUpdate.between(original.serialized(), serialized(), oldLists: original.serializedLists(), newLists: serializedLists())
        update.repeatsDeletions = true
        return update
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, node.isEmpty { problems["node_id"] = String(localized: "Choose a node.") }
        if let ip = trimmed(ip), !SDNSubnetDraft.isIPv4(ip) { problems["ip"] = String(localized: "Enter an IPv4 address without prefix length.") }
        if protocolType.supportsIPv6, let ip6 = trimmed(ip6), !(ip6.contains(":") && SDNSubnetDraft.isAddress(ip6)) {
            problems["ip6"] = String(localized: "Enter an IPv6 address without prefix length.")
        }
        if protocolType == .bgp, !(trimmed(asn).flatMap { UInt32($0) }.map { $0 >= 1 } ?? false) {
            problems["asn"] = String(localized: "Use a number from 1 to 4294967295.")
        }
        for interface in interfaces {
            if let ip = trimmed(interface.ip), !isCIDR(ip, ipv6: false) {
                problems["interfaces"] = String(localized: "Enter the address of \(interface.name) with its prefix length, e.g. 10.0.0.1/31.")
            }
            if let ip6 = trimmed(interface.ip6), !isCIDR(ip6, ipv6: true) {
                problems["interfaces"] = String(localized: "Enter the IPv6 address of \(interface.name) with its prefix length.")
            }
        }
        return problems
    }
}

/// `GET /cluster/sdn/fabrics/all`: fabrics and their nodes.
public struct SDNFabrics: Decodable, Sendable, Equatable {
    public var fabrics: [SDNObject]
    public var nodes: [SDNObject]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        fabrics = try container.decodeIfPresent([SDNObject].self, forKey: AnyCodingKey("fabrics")) ?? []
        nodes = try container.decodeIfPresent([SDNObject].self, forKey: AnyCodingKey("nodes")) ?? []
    }
}

extension SDNObject {
    /// The fabric a fabric node belongs to.
    public var fabricID: String? { values["fabric_id"] ?? running["fabric_id"] }
}

// MARK: - Prefix lists

/// One line of a prefix list: whether routes for networks within `prefix`, optionally limited to prefix lengths
/// from `ge` to `le`, are permitted. Entries are checked by sequence number.
public struct SDNPrefixListEntry: Decodable, Sendable, Hashable, Identifiable {
    public var sequence: Int
    public var action: String
    public var prefix: String
    public var le: Int?
    public var ge: Int?

    public var id: Int { sequence }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        sequence = container.lossyInt(AnyCodingKey("seq")) ?? 0
        action = container.lossyString(AnyCodingKey("action")) ?? "permit"
        prefix = container.lossyString(AnyCodingKey("prefix")) ?? ""
        le = container.lossyInt(AnyCodingKey("le"))
        ge = container.lossyInt(AnyCodingKey("ge"))
    }
}

public struct SDNPrefixListEntryDraft: Equatable, Sendable {
    /// Empty lets the server pick the next number, in steps of 5.
    public var sequence = ""
    public var action = "permit"
    public var prefix = ""
    public var le = ""
    public var ge = ""

    public init() {}

    public init(_ entry: SDNPrefixListEntry) {
        sequence = String(entry.sequence)
        action = entry.action
        prefix = entry.prefix
        le = entry.le.map(String.init) ?? ""
        ge = entry.ge.map(String.init) ?? ""
    }

    func serialized() -> [String: String?] {
        ["action": action, "prefix": trimmed(prefix), "le": trimmed(le), "ge": trimmed(ge)]
    }

    var creationParameters: APIParameters {
        var parameters = APIParameters()
        if let sequence = trimmed(sequence) { parameters["seq"] = .string(sequence) }
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        return parameters
    }

    public func changes(from original: SDNPrefixListEntryDraft) -> SDNUpdate {
        var update = SDNUpdate.between(original.serialized(), serialized())
        update.repeatsDeletions = true
        return update
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        let prefix = prefix.trimmingCharacters(in: .whitespaces)
        if !(isCIDR(prefix, ipv6: false) || isCIDR(prefix, ipv6: true)) {
            problems["prefix"] = String(localized: "Enter a network with its prefix length, e.g. 10.0.0.0/8.")
        }
        if let sequence = trimmed(sequence), !(UInt32(sequence).map { $0 >= 1 } ?? false) {
            problems["seq"] = String(localized: "Use a number from 1 to 4294967295.")
        }
        for (key, value) in [("le", le), ("ge", ge)] {
            if let value = trimmed(value), !(Int(value).map { (0...128).contains($0) } ?? false) {
                problems[key] = String(localized: "Use a prefix length from 0 to 128.")
            }
        }
        if let le = Int(le), let ge = Int(ge), ge > le { problems["ge"] = String(localized: "The minimum cannot be above the maximum.") }
        return problems
    }
}

// MARK: - Route maps

/// A condition or an action of a route map entry, `key=metric,value=100`. Some keys take no value.
public struct SDNRouteMapClause: Sendable, Hashable {
    public var key: String
    public var value: String

    public init(key: String, value: String = "") {
        self.key = key
        self.value = value
    }

    init?(propertyString text: String) {
        let property = PropertyString(parsing: text)
        guard let key = property["key"] else { return nil }
        self.init(key: key, value: property["value"] ?? "")
    }

    var propertyString: String {
        trimmed(value).map { "key=\(key),value=\($0)" } ?? "key=\(key)"
    }
}

/// What a route map clause's value is, which picks the control for it.
public enum SDNRouteMapValueKind: Sendable, Equatable {
    case none
    case number
    case text
    case ipv4
    case ipv6
    case prefixList
    case choice([String])
}

public enum SDNRouteMapMatch {
    public static let keys = [
        "route-type", "vni", "ip-address-prefix-list", "ip6-address-prefix-list", "ip-next-hop-prefix-list", "ip6-next-hop-prefix-list",
        "ip-next-hop-address", "ip6-next-hop-address", "metric", "local-preference", "peer", "tag",
    ]
    public static let routeTypes = ["ead", "macip", "multicast", "es", "prefix"]

    public static func kind(_ key: String) -> SDNRouteMapValueKind {
        switch key {
        case "route-type": .choice(routeTypes)
        case "vni", "metric", "local-preference", "tag": .number
        case "ip-address-prefix-list", "ip6-address-prefix-list", "ip-next-hop-prefix-list", "ip6-next-hop-prefix-list": .prefixList
        case "ip-next-hop-address": .ipv4
        case "ip6-next-hop-address": .ipv6
        default: .text
        }
    }
}

public enum SDNRouteMapSet {
    public static let keys = [
        "ip-next-hop-peer-address", "ip-next-hop", "ip-next-hop-unchanged", "ip6-next-hop-peer-address", "ip6-next-hop-prefer-global",
        "ip6-next-hop", "local-preference", "tag", "weight", "metric", "src",
    ]

    public static func kind(_ key: String) -> SDNRouteMapValueKind {
        switch key {
        case "ip-next-hop-peer-address", "ip-next-hop-unchanged", "ip6-next-hop-peer-address", "ip6-next-hop-prefer-global": .none
        case "ip-next-hop": .ipv4
        case "ip6-next-hop": .ipv6
        case "weight": .number
        default: .text
        }
    }
}

/// One entry of a route map, from `GET /cluster/sdn/route-maps/entries`. Route maps exist through their entries.
public struct SDNRouteMapEntry: Sendable, Equatable, Identifiable {
    public var routeMap: String
    public var order: Int
    public var object: SDNObject

    public var id: String { "\(routeMap)/\(order)" }
    public var state: SDNObject.State? { object.state }
    public var action: String { object.values["action"] ?? "permit" }
    public var match: [SDNRouteMapClause] { (object.lists["match"] ?? []).compactMap(SDNRouteMapClause.init(propertyString:)) }
    public var set: [SDNRouteMapClause] { (object.lists["set"] ?? []).compactMap(SDNRouteMapClause.init(propertyString:)) }

    public init(_ object: SDNObject) {
        routeMap = object.values["route-map-id"] ?? object.running["route-map-id"] ?? ""
        order = Int(object.values["order"] ?? object.running["order"] ?? "") ?? 0
        self.object = object
    }
}

public struct SDNRouteMapEntryDraft: Equatable, Sendable {
    /// What happens after an entry matched: the default ends the route map.
    public enum ExitAction: String, CaseIterable, Sendable {
        case exit = "", next = "on-match-next", goto = "on-match-goto", `continue`

        /// Go to and continue name the order of the entry to go on with.
        public var needsTarget: Bool { self == .goto || self == .continue }
    }

    public var routeMap = ""
    public var order = ""
    public var action = "permit"
    public var match: [SDNRouteMapClause] = []
    public var set: [SDNRouteMapClause] = []
    /// Another route map to run when this entry matches.
    public var call = ""
    public var exitAction = ExitAction.exit
    public var exitTarget = ""

    public init(routeMap: String = "", order: String = "") {
        self.routeMap = routeMap
        self.order = order
    }

    public init(_ entry: SDNRouteMapEntry) {
        routeMap = entry.routeMap
        order = String(entry.order)
        action = entry.action
        match = entry.match
        set = entry.set
        call = entry.object.values["call"] ?? ""
        let exit = PropertyString(parsing: entry.object.values["exit-action"] ?? "")
        exitAction = ExitAction(rawValue: exit["key"] ?? "") ?? .exit
        exitTarget = exit["value"] ?? ""
    }

    func serialized() -> [String: String?] {
        var exit: String?
        if exitAction != .exit {
            exit = exitAction.needsTarget ? "key=\(exitAction.rawValue),value=\(exitTarget.trimmingCharacters(in: .whitespaces))" : "key=\(exitAction.rawValue)"
        }
        return ["action": action, "call": trimmed(call), "exit-action": exit]
    }

    func serializedLists() -> [String: [String]] {
        ["match": match.map(\.propertyString), "set": set.map(\.propertyString)]
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["route-map-id": .string(routeMap.trimmingCharacters(in: .whitespaces)), "order": .string(order.trimmingCharacters(in: .whitespaces))]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        for (key, list) in serializedLists().sorted(by: { $0.key < $1.key }) {
            for item in list { parameters.append(key, .string(item)) }
        }
        return parameters
    }

    public func changes(from original: SDNRouteMapEntryDraft) -> SDNUpdate {
        var update = SDNUpdate.between(original.serialized(), serialized(), oldLists: original.serializedLists(), newLists: serializedLists())
        update.repeatsDeletions = true
        return update
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew {
            let id = routeMap.trimmingCharacters(in: .whitespaces)
            if id.isEmpty || id.first?.isLetter != true || !id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)) }) {
                problems["route-map-id"] = String(localized: "Letters, digits, - and _, starting with a letter.")
            }
            if !(Int(order.trimmingCharacters(in: .whitespaces)).map { (0...65535).contains($0) } ?? false) {
                problems["order"] = String(localized: "Use a number from 0 to 65535.")
            }
        }
        if exitAction.needsTarget, !(Int(exitTarget.trimmingCharacters(in: .whitespaces)).map { (0...65535).contains($0) } ?? false) {
            problems["exit-action"] = String(localized: "Enter the order of the entry to go on with.")
        }
        for (clauses, kind, key) in [(match, SDNRouteMapMatch.kind, "match"), (set, SDNRouteMapSet.kind, "set")] {
            for clause in clauses {
                let value = clause.value.trimmingCharacters(in: .whitespaces)
                let valid = switch kind(clause.key) {
                case .none: true
                case .number: Int(value) != nil
                case .ipv4: SDNSubnetDraft.isIPv4(value)
                case .ipv6: value.contains(":") && SDNSubnetDraft.isAddress(value)
                case .text, .prefixList, .choice: !value.isEmpty
                }
                if !valid { problems[key] = String(localized: "Check the value of \(clause.key).") }
            }
        }
        return problems
    }
}

// MARK: - Requests

extension PVE {
    public static func sdnControllers() -> APIRequest<[SDNObject]> {
        APIRequest(.get, "/cluster/sdn/controllers", parameters: ["pending": true])
    }

    public static func createSDNController(_ draft: SDNControllerDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/sdn/controllers", parameters: draft.creationParameters)
    }

    public static func updateSDNController(_ id: String, _ update: SDNUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/cluster/sdn/controllers/\(escapePath(id))", parameters: update.parameters)
    }

    /// Controllers used by zones cannot be deleted.
    public static func deleteSDNController(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/sdn/controllers/\(escapePath(id))")
    }

    public static func sdnFabrics() -> APIRequest<SDNFabrics> {
        APIRequest(.get, "/cluster/sdn/fabrics/all", parameters: ["pending": true])
    }

    public static func createSDNFabric(_ draft: SDNFabricDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/sdn/fabrics/fabric", parameters: draft.creationParameters)
    }

    public static func updateSDNFabric(_ id: String, protocol protocolType: SDNFabricProtocol, _ update: SDNUpdate) -> APIRequest<Nothing> {
        var parameters = update.parameters
        parameters["protocol"] = .string(protocolType.rawValue)
        return APIRequest(.put, "/cluster/sdn/fabrics/fabric/\(escapePath(id))", parameters: parameters)
    }

    /// Fabrics with nodes cannot be deleted.
    public static func deleteSDNFabric(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/sdn/fabrics/fabric/\(escapePath(id))")
    }

    public static func addSDNFabricNode(fabric: String, _ draft: SDNFabricNodeDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/sdn/fabrics/node/\(escapePath(fabric))", parameters: draft.creationParameters)
    }

    public static func updateSDNFabricNode(fabric: String, node: String, protocol protocolType: SDNFabricProtocol, _ update: SDNUpdate) -> APIRequest<Nothing> {
        var parameters = update.parameters
        parameters["protocol"] = .string(protocolType.rawValue)
        return APIRequest(.put, "/cluster/sdn/fabrics/node/\(escapePath(fabric))/\(escapePath(node))", parameters: parameters)
    }

    public static func removeSDNFabricNode(fabric: String, node: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/sdn/fabrics/node/\(escapePath(fabric))/\(escapePath(node))")
    }

    public static func sdnPrefixLists() -> APIRequest<[SDNObject]> {
        APIRequest(.get, "/cluster/sdn/prefix-lists", parameters: ["pending": true])
    }

    /// The entries as they will be after Apply.
    public static func sdnPrefixListEntries(_ id: String) -> APIRequest<[SDNPrefixListEntry]> {
        APIRequest(.get, "/cluster/sdn/prefix-lists/\(escapePath(id))/entries", parameters: ["pending": true])
    }

    public static func createSDNPrefixList(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/sdn/prefix-lists", parameters: ["id": .string(id)])
    }

    public static func deleteSDNPrefixList(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/sdn/prefix-lists/\(escapePath(id))")
    }

    public static func createSDNPrefixListEntry(list: String, _ draft: SDNPrefixListEntryDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/sdn/prefix-lists/\(escapePath(list))/entries", parameters: draft.creationParameters)
    }

    public static func updateSDNPrefixListEntry(list: String, sequence: Int, _ update: SDNUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/cluster/sdn/prefix-lists/\(escapePath(list))/entries/\(sequence)", parameters: update.parameters)
    }

    public static func deleteSDNPrefixListEntry(list: String, sequence: Int) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/sdn/prefix-lists/\(escapePath(list))/entries/\(sequence)")
    }

    public static func sdnRouteMapEntries() -> APIRequest<[SDNObject]> {
        APIRequest(.get, "/cluster/sdn/route-maps/entries", parameters: ["pending": true])
    }

    /// Creates the route map with its first entry, or adds an entry.
    public static func createSDNRouteMapEntry(_ draft: SDNRouteMapEntryDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/sdn/route-maps/entries", parameters: draft.creationParameters)
    }

    public static func updateSDNRouteMapEntry(routeMap: String, order: Int, _ update: SDNUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/cluster/sdn/route-maps/entries/\(escapePath(routeMap))/entry/\(order)", parameters: update.parameters)
    }

    public static func deleteSDNRouteMapEntry(routeMap: String, order: Int) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/sdn/route-maps/entries/\(escapePath(routeMap))/entry/\(order)")
    }
}
