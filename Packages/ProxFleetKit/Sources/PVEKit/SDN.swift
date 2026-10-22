import Foundation
import ProxmoxCore

/// A DHCP range of an SDN subnet.
public struct SDNDHCPRange: Sendable, Hashable {
    public var start: String
    public var end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }

    /// `start-address=10.0.0.100,end-address=10.0.0.200`, as the API takes and lists pending ranges.
    init?(propertyString text: String) {
        let property = PropertyString(parsing: text)
        guard let start = property["start-address"], let end = property["end-address"] else { return nil }
        self.init(start: start, end: end)
    }

    var propertyString: String { "start-address=\(start),end-address=\(end)" }
}

/// An SDN zone, VNet or subnet as `GET` lists it with `pending=1`: the applied values, plus changes that wait
/// for Apply. Values are text by API name; lists are comma-separated.
public struct SDNObject: Decodable, Sendable, Equatable, Identifiable {
    public enum State: String, Sendable {
        case new, changed, deleted
    }

    public var id: String
    public var type: String
    /// Values in effect on the nodes. Empty for objects that were never applied.
    public var running: [String: String]
    /// Values once the pending changes are applied.
    public var values: [String: String]
    public var runningRanges: [SDNDHCPRange]
    public var ranges: [SDNDHCPRange]
    /// nil when nothing waits for Apply.
    public var state: State?

    private static let idKeys = ["subnet", "vnet", "zone"]
    private static let skippedKeys: Set<String> = ["pending", "state", "digest", "dhcp-range", "type"]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        type = container.lossyString(AnyCodingKey("type")) ?? ""
        let idKey = Self.idKeys.first { container.contains(AnyCodingKey($0)) } ?? "zone"
        id = container.lossyString(AnyCodingKey(idKey)) ?? ""
        running = Self.values(in: container)
        running[idKey] = nil
        runningRanges = Self.ranges(in: container)
        state = container.lossyString(AnyCodingKey("state")).flatMap(State.init)
        values = running
        ranges = runningRanges
        if let pending = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("pending")) {
            for (key, value) in Self.values(in: pending) {
                // Settings removed by a pending change are listed as "deleted".
                values[key] = value == "deleted" ? nil : value
            }
            // Removed ranges are listed as "deleted", which reads as no ranges.
            if pending.contains(AnyCodingKey("dhcp-range")) {
                ranges = Self.ranges(in: pending)
            }
        }
    }

    private static func values(in container: KeyedDecodingContainer<AnyCodingKey>) -> [String: String] {
        var values: [String: String] = [:]
        for key in container.allKeys where !skippedKeys.contains(key.stringValue) {
            if let text = container.lossyString(key) {
                values[key.stringValue] = text
            } else if let flag = container.lossyBool(key) {
                values[key.stringValue] = flag ? "1" : "0"
            } else if let list = try? container.decode([String].self, forKey: key) {
                values[key.stringValue] = list.joined(separator: ",")
            }
        }
        return values
    }

    /// Applied ranges come as objects, pending ones as property strings.
    private static func ranges(in container: KeyedDecodingContainer<AnyCodingKey>) -> [SDNDHCPRange] {
        let key = AnyCodingKey("dhcp-range")
        if let texts = try? container.decode([String].self, forKey: key) {
            return texts.compactMap(SDNDHCPRange.init(propertyString:))
        }
        if let objects = try? container.decode([[String: String]].self, forKey: key) {
            return objects.compactMap { object in
                guard let start = object["start-address"], let end = object["end-address"] else { return nil }
                return SDNDHCPRange(start: start, end: end)
            }
        }
        return []
    }

    public subscript(key: String) -> String? { values[key] }

    /// VNet alias, subnet CIDR and the like, as the web interface shows them.
    public var zone: String? { values["zone"] }
}

/// Zone types the app creates. EVPN and Faucet zones need controllers and are left to the web interface.
public enum SDNZoneType: String, CaseIterable, Sendable, Identifiable {
    case simple, vlan, qinq, vxlan

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .simple: String(localized: "Simple")
        case .vlan: String(localized: "VLAN")
        case .qinq: String(localized: "QinQ")
        case .vxlan: String(localized: "VXLAN")
        }
    }

    /// VNets of these zones need a tag (VLAN ID or VNI); QinQ allows VNets without one, simple zones none.
    public var requiresVNetTag: Bool { self == .vlan || self == .vxlan }
    public var allowsVNetTag: Bool { self != .simple }
}

/// Changes to send for an SDN object: values to set, settings to remove, and DHCP ranges, which the API takes as
/// a repeated parameter.
public struct SDNUpdate: Sendable, Equatable {
    public var values: [String: String] = [:]
    public var deletions: Set<String> = []
    /// nil leaves the ranges as they are; empty removes them.
    public var ranges: [SDNDHCPRange]?

    public init() {}

    public var isEmpty: Bool { values.isEmpty && deletions.isEmpty && ranges == nil }

    mutating func set(_ key: String, _ value: String?) {
        if let value {
            values[key] = value
            deletions.remove(key)
        } else {
            values[key] = nil
            deletions.insert(key)
        }
    }

    var parameters: APIParameters {
        var parameters = APIParameters()
        for key in values.keys.sorted() {
            parameters[key] = .string(values[key]!)
        }
        var deletions = deletions
        if let ranges {
            if ranges.isEmpty {
                deletions.insert("dhcp-range")
            } else {
                for range in ranges { parameters.append("dhcp-range", .string(range.propertyString)) }
            }
        }
        if !deletions.isEmpty { parameters["delete"] = .string(deletions.sorted().joined(separator: ",")) }
        return parameters
    }

    /// The differences between two serialized forms; nil values are settings to remove.
    static func between(_ old: [String: String?], _ new: [String: String?]) -> SDNUpdate {
        var update = SDNUpdate()
        for (key, value) in new where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        return update
    }
}

private func trimmed(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

/// SDN identifiers: up to 8 letters and digits, starting with a letter.
private func identifierProblem(_ id: String) -> String? {
    if id.isEmpty { return String(localized: "Enter a name.") }
    let valid = id.count <= 8 && id.first?.isLetter == true && id.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    return valid ? nil : String(localized: "Up to 8 letters and digits, starting with a letter.")
}

/// The form for a zone. Only the settings of its type are sent.
public struct SDNZoneDraft: Equatable, Sendable {
    public var id = ""
    public var type = SDNZoneType.simple
    /// Empty for all nodes.
    public var nodes: Set<String> = []
    public var mtu = ""
    public var ipam = "pve"
    public var dns = ""
    public var reverseDNS = ""
    public var dnsZone = ""
    /// Simple zones: dnsmasq hands out addresses of the subnets' DHCP ranges.
    public var automaticDHCP = false
    /// VLAN and QinQ zones.
    public var bridge = ""
    /// QinQ: the service VLAN and its protocol.
    public var serviceVLAN = ""
    public var vlanProtocol = ""
    /// VXLAN: comma-separated peer addresses and the UDP port.
    public var peers = ""
    public var vxlanPort = ""

    public init() {}

    public init(_ zone: SDNObject) {
        let values = zone.values
        id = zone.id
        type = SDNZoneType(rawValue: zone.type) ?? .simple
        nodes = Set((values["nodes"] ?? "").split(separator: ",").map(String.init))
        mtu = values["mtu"] ?? ""
        ipam = values["ipam"] ?? ""
        dns = values["dns"] ?? ""
        reverseDNS = values["reversedns"] ?? ""
        dnsZone = values["dnszone"] ?? ""
        automaticDHCP = values["dhcp"] == "dnsmasq"
        bridge = values["bridge"] ?? ""
        serviceVLAN = values["tag"] ?? ""
        vlanProtocol = values["vlan-protocol"] ?? ""
        peers = values["peers"] ?? ""
        vxlanPort = values["vxlan-port"] ?? ""
    }

    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("nodes", nodes.isEmpty ? nil : nodes.sorted().joined(separator: ","))
        set("mtu", trimmed(mtu))
        set("ipam", trimmed(ipam))
        set("dns", trimmed(dns))
        set("reversedns", trimmed(reverseDNS))
        set("dnszone", trimmed(dnsZone))
        if type == .simple { set("dhcp", automaticDHCP ? "dnsmasq" : nil) }
        if type == .vlan || type == .qinq { set("bridge", trimmed(bridge)) }
        if type == .qinq {
            set("tag", trimmed(serviceVLAN))
            set("vlan-protocol", trimmed(vlanProtocol))
        }
        if type == .vxlan {
            let list = peers.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init)
            set("peers", list.isEmpty ? nil : list.joined(separator: ","))
            set("vxlan-port", trimmed(vxlanPort))
        }
        return values
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["zone": .string(id), "type": .string(type.rawValue)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        return parameters
    }

    public func changes(from original: SDNZoneDraft) -> SDNUpdate {
        SDNUpdate.between(original.serialized(), serialized())
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, let problem = identifierProblem(id) { problems["zone"] = problem }
        if let mtu = trimmed(mtu), !(Int(mtu).map { (68...65535).contains($0) } ?? false) {
            problems["mtu"] = String(localized: "Use a whole number from 68 to 65535.")
        }
        if (type == .vlan || type == .qinq), trimmed(bridge) == nil { problems["bridge"] = String(localized: "Choose a bridge.") }
        if type == .qinq, !(trimmed(serviceVLAN).flatMap { Int($0) }.map { (0...4096).contains($0) } ?? false) {
            problems["tag"] = String(localized: "Use a VLAN ID from 0 to 4096.")
        }
        if type == .vxlan {
            if trimmed(peers) == nil { problems["peers"] = String(localized: "Enter the addresses of the nodes.") }
            if let port = trimmed(vxlanPort), !(Int(port).map { (1...65535).contains($0) } ?? false) {
                problems["vxlan-port"] = String(localized: "Use a port from 1 to 65535.")
            }
        }
        if automaticDHCP, type == .simple, trimmed(ipam) == nil {
            problems["dhcp"] = String(localized: "Automatic DHCP needs an IPAM.")
        }
        return problems
    }
}

/// The form for a VNet.
public struct SDNVNetDraft: Equatable, Sendable {
    public var id = ""
    public var zone = ""
    public var alias = ""
    public var tag = ""
    public var isVLANAware = false
    public var isolatesPorts = false

    public init() {}

    public init(_ vnet: SDNObject) {
        id = vnet.id
        zone = vnet["zone"] ?? ""
        alias = vnet["alias"] ?? ""
        tag = vnet["tag"] ?? ""
        isVLANAware = vnet["vlanaware"] == "1"
        isolatesPorts = vnet["isolate-ports"] == "1"
    }

    /// The tag only applies to zones with tags; it is removed when the VNet moves to a simple zone.
    func serialized(zoneType: SDNZoneType?) -> [String: String?] {
        var values: [String: String?] = [:]
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("zone", trimmed(zone))
        set("alias", trimmed(alias))
        set("tag", zoneType?.allowsVNetTag == false ? nil : trimmed(tag))
        set("vlanaware", isVLANAware ? "1" : nil)
        set("isolate-ports", isolatesPorts ? "1" : nil)
        return values
    }

    func creationParameters(zoneType: SDNZoneType?) -> APIParameters {
        var parameters: APIParameters = ["vnet": .string(id), "type": "vnet"]
        for (key, value) in serialized(zoneType: zoneType).sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        return parameters
    }

    public func changes(from original: SDNVNetDraft, zoneType: SDNZoneType?) -> SDNUpdate {
        SDNUpdate.between(original.serialized(zoneType: zoneType), serialized(zoneType: zoneType))
    }

    public func problems(isNew: Bool, zoneType: SDNZoneType?) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, let problem = identifierProblem(id) { problems["vnet"] = problem }
        if trimmed(zone) == nil { problems["zone"] = String(localized: "Choose a zone.") }
        if let alias = trimmed(alias), alias.count > 256 || alias.contains(where: \.isNewline) {
            problems["alias"] = String(localized: "Use one line of at most 256 characters.")
        }
        let maximum = zoneType == .vxlan ? 16_777_215 : 4094
        if let tag = trimmed(tag), zoneType?.allowsVNetTag != false {
            if !(Int(tag).map { (1...maximum).contains($0) } ?? false) {
                problems["tag"] = String(localized: "Use a number from 1 to \(maximum).")
            }
        } else if zoneType?.requiresVNetTag == true {
            problems["tag"] = zoneType == .vxlan ? String(localized: "Enter the VXLAN ID (VNI).") : String(localized: "Enter the VLAN ID.")
        }
        return problems
    }
}

/// The form for a subnet of a VNet.
public struct SDNSubnetDraft: Equatable, Sendable {
    /// `10.0.0.0/24`; fixed once created.
    public var cidr = ""
    public var gateway = ""
    public var snat = false
    public var dnsZonePrefix = ""
    public var ranges: [SDNDHCPRange] = []
    public var dhcpDNSServer = ""

    public init() {}

    public init(_ subnet: SDNObject) {
        cidr = subnet["cidr"] ?? ""
        gateway = subnet["gateway"] ?? ""
        snat = subnet["snat"] == "1"
        dnsZonePrefix = subnet["dnszoneprefix"] ?? ""
        ranges = subnet.ranges
        dhcpDNSServer = subnet["dhcp-dns-server"] ?? ""
    }

    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("gateway", trimmed(gateway))
        set("snat", snat ? "1" : nil)
        set("dnszoneprefix", trimmed(dnsZonePrefix))
        set("dhcp-dns-server", trimmed(dhcpDNSServer))
        return values
    }

    private var cleanRanges: [SDNDHCPRange] {
        ranges.compactMap { range in
            guard let start = trimmed(range.start), let end = trimmed(range.end) else { return nil }
            return SDNDHCPRange(start: start, end: end)
        }
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["subnet": .string(trimmed(cidr) ?? ""), "type": "subnet"]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        for range in cleanRanges { parameters.append("dhcp-range", .string(range.propertyString)) }
        return parameters
    }

    public func changes(from original: SDNSubnetDraft) -> SDNUpdate {
        var update = SDNUpdate.between(original.serialized(), serialized())
        if cleanRanges != original.cleanRanges { update.ranges = cleanRanges }
        return update
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew {
            let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/")
            let isIPv6 = parts.first?.contains(":") == true
            let prefixValid = parts.count == 2 && (Int(parts[1]).map { (0...(isIPv6 ? 128 : 32)).contains($0) } ?? false)
            if !prefixValid || !(isIPv6 || Self.isIPv4(String(parts[0]))) {
                problems["subnet"] = String(localized: "Enter a network with its prefix length, e.g. 10.0.0.0/24.")
            }
        }
        if let gateway = trimmed(gateway), !Self.isAddress(gateway) { problems["gateway"] = String(localized: "Enter an IP address.") }
        if let server = trimmed(dhcpDNSServer), !Self.isAddress(server) { problems["dhcp-dns-server"] = String(localized: "Enter an IP address.") }
        if ranges.contains(where: { range in
            let start = trimmed(range.start), end = trimmed(range.end)
            if start == nil && end == nil { return false }
            return !(start.map(Self.isAddress) ?? false) || !(end.map(Self.isAddress) ?? false)
        }) {
            problems["dhcp-range"] = String(localized: "Enter a start and an end address for each range.")
        }
        return problems
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in !part.isEmpty && part.count <= 3 && (Int(part).map { $0 <= 255 } ?? false) }
    }

    static func isAddress(_ text: String) -> Bool {
        isIPv4(text) || (text.contains(":") && text.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." })
    }
}

/// `GET /nodes/{node}/sdn/zones`: whether a zone works on a node after Apply.
public struct SDNZoneStatus: Decodable, Sendable, Equatable {
    public var zone: String
    /// `available`, `pending`, `error`…
    public var status: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        zone = container.lossyString(AnyCodingKey("zone")) ?? ""
        status = container.lossyString(AnyCodingKey("status")) ?? ""
    }
}

/// An IPAM or DNS plugin, for the zone pickers.
public struct SDNPlugin: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var type: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = container.lossyString(AnyCodingKey("ipam")) ?? container.lossyString(AnyCodingKey("dns")) ?? ""
        type = container.lossyString(AnyCodingKey("type")) ?? ""
    }
}

/// An address the PVE IPAM handed out, from `GET /cluster/sdn/ipams/{ipam}/status`.
public struct IPAMEntry: Decodable, Sendable, Equatable, Identifiable {
    public var zone: String?
    public var vnet: String?
    public var subnet: String?
    public var ip: String
    public var mac: String?
    public var hostname: String?
    public var vmid: Int?
    public var isGateway: Bool

    public var id: String { [vnet, ip].compactMap { $0 }.joined(separator: "/") }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        zone = container.lossyString(AnyCodingKey("zone"))
        vnet = container.lossyString(AnyCodingKey("vnet"))
        subnet = container.lossyString(AnyCodingKey("subnet"))
        ip = container.lossyString(AnyCodingKey("ip")) ?? ""
        mac = container.lossyString(AnyCodingKey("mac"))
        hostname = container.lossyString(AnyCodingKey("hostname"))
        vmid = container.lossyInt(AnyCodingKey("vmid"))
        isGateway = container.lossyBool(AnyCodingKey("gateway")) ?? false
    }
}

extension PVE {
    public static func sdnZones() -> APIRequest<[SDNObject]> {
        APIRequest(.get, "/cluster/sdn/zones", parameters: ["pending": true])
    }

    public static func createSDNZone(_ draft: SDNZoneDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/sdn/zones", parameters: draft.creationParameters)
    }

    public static func updateSDNZone(_ id: String, _ update: SDNUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/cluster/sdn/zones/\(escapePath(id))", parameters: update.parameters)
    }

    public static func deleteSDNZone(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/sdn/zones/\(escapePath(id))")
    }

    public static func sdnVNets() -> APIRequest<[SDNObject]> {
        APIRequest(.get, "/cluster/sdn/vnets", parameters: ["pending": true])
    }

    public static func createSDNVNet(_ draft: SDNVNetDraft, zoneType: SDNZoneType?) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/sdn/vnets", parameters: draft.creationParameters(zoneType: zoneType))
    }

    public static func updateSDNVNet(_ id: String, _ update: SDNUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/cluster/sdn/vnets/\(escapePath(id))", parameters: update.parameters)
    }

    public static func deleteSDNVNet(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/sdn/vnets/\(escapePath(id))")
    }

    public static func sdnSubnets(vnet: String) -> APIRequest<[SDNObject]> {
        APIRequest(.get, "/cluster/sdn/vnets/\(escapePath(vnet))/subnets", parameters: ["pending": true])
    }

    public static func createSDNSubnet(vnet: String, _ draft: SDNSubnetDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/sdn/vnets/\(escapePath(vnet))/subnets", parameters: draft.creationParameters)
    }

    /// `id` is the subnet's identifier, e.g. `zone-10.0.0.0-24`, not its CIDR.
    public static func updateSDNSubnet(vnet: String, id: String, _ update: SDNUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/cluster/sdn/vnets/\(escapePath(vnet))/subnets/\(escapePath(id))", parameters: update.parameters)
    }

    public static func deleteSDNSubnet(vnet: String, id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/sdn/vnets/\(escapePath(vnet))/subnets/\(escapePath(id))")
    }

    /// Writes the pending configuration to every node and reloads their networks. Returns the task ID.
    public static func applySDN() -> APIRequest<String> {
        APIRequest(.put, "/cluster/sdn")
    }

    /// Drops every pending change.
    public static func rollbackSDN() -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/sdn/rollback")
    }

    public static func sdnZoneStatus(node: String) -> APIRequest<[SDNZoneStatus]> {
        APIRequest(.get, "/nodes/\(node)/sdn/zones")
    }

    public static func sdnIPAMs() -> APIRequest<[SDNPlugin]> {
        APIRequest(.get, "/cluster/sdn/ipams")
    }

    public static func sdnDNSServers() -> APIRequest<[SDNPlugin]> {
        APIRequest(.get, "/cluster/sdn/dns")
    }

    public static func ipamEntries(_ ipam: String) -> APIRequest<[IPAMEntry]> {
        APIRequest(.get, "/cluster/sdn/ipams/\(escapePath(ipam))/status")
    }
}
