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

/// An SDN object as `GET` lists it with `pending=1` (zones, VNets, subnets, controllers, fabrics and their nodes,
/// route map entries, prefix lists): the applied values, plus changes that wait for Apply. Values are text by API
/// name, with lists comma-separated; `lists` keeps list settings item by item, since their items may contain
/// commas themselves. New objects only have pending values, including their own ID.
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
    public var runningLists: [String: [String]]
    public var lists: [String: [String]]
    public var runningRanges: [SDNDHCPRange]
    public var ranges: [SDNDHCPRange]
    /// nil when nothing waits for Apply.
    public var state: State?

    /// The first of these keys an object has is its ID. VNets also name their zone, subnets their VNet and EVPN
    /// zones their controller, so the order matters.
    private static let idKeys = ["subnet", "vnet", "zone", "controller", "node_id", "id"]
    private static let skippedKeys: Set<String> = ["pending", "state", "digest", "dhcp-range", "type"]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        type = container.lossyString(AnyCodingKey("type")) ?? ""
        running = Self.values(in: container)
        runningLists = Self.lists(in: container)
        runningRanges = Self.ranges(in: container)
        state = container.lossyString(AnyCodingKey("state")).flatMap(State.init)
        values = running
        lists = runningLists
        ranges = runningRanges
        if let pending = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("pending")) {
            for (key, value) in Self.values(in: pending) {
                // Settings removed by a pending change are listed as "deleted".
                values[key] = value == "deleted" ? nil : value
                if value == "deleted" { lists[key] = nil }
            }
            for (key, list) in Self.lists(in: pending) { lists[key] = list }
            // Removed ranges are listed as "deleted", which reads as no ranges.
            if pending.contains(AnyCodingKey("dhcp-range")) {
                ranges = Self.ranges(in: pending)
            }
        }
        let (pendingValues, runningValues) = (values, running)
        let idKey = Self.idKeys.first { pendingValues[$0] != nil || runningValues[$0] != nil } ?? "zone"
        id = pendingValues[idKey] ?? runningValues[idKey] ?? ""
        running[idKey] = nil
        values[idKey] = nil
    }

    private static func lists(in container: KeyedDecodingContainer<AnyCodingKey>) -> [String: [String]] {
        var lists: [String: [String]] = [:]
        for key in container.allKeys where !skippedKeys.contains(key.stringValue) {
            if let list = try? container.decode([String].self, forKey: key) { lists[key.stringValue] = list }
        }
        return lists
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

/// Zone types the web interface creates. Faucet zones exist in the API only.
public enum SDNZoneType: String, CaseIterable, Sendable, Identifiable {
    case simple, vlan, qinq, vxlan, evpn

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .simple: String(localized: "Simple")
        case .vlan: String(localized: "VLAN")
        case .qinq: String(localized: "QinQ")
        case .vxlan: String(localized: "VXLAN")
        case .evpn: String(localized: "EVPN")
        }
    }

    /// VNets of these zones need a tag (VLAN ID or VNI); QinQ allows VNets without one, simple zones none.
    public var requiresVNetTag: Bool { self == .vlan || self == .vxlan || self == .evpn }
    public var allowsVNetTag: Bool { self != .simple }
    /// VXLAN and EVPN tags are VNIs, which go beyond VLAN IDs.
    public var usesVNI: Bool { self == .vxlan || self == .evpn }
}

/// Changes to send for an SDN object: values to set, settings to remove, and list settings such as DHCP ranges,
/// which the API takes as a repeated parameter.
public struct SDNUpdate: Sendable, Equatable {
    public var values: [String: String] = [:]
    public var deletions: Set<String> = []
    /// nil leaves the ranges as they are; empty removes them.
    public var ranges: [SDNDHCPRange]?
    /// Other list settings that changed; an empty list removes the setting.
    public var lists: [String: [String]] = [:]
    /// Fabrics, prefix lists and route maps take `delete` as a list too, not as comma-separated text.
    var repeatsDeletions = false

    public init() {}

    public var isEmpty: Bool { values.isEmpty && deletions.isEmpty && ranges == nil && lists.isEmpty }

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
        for key in lists.keys.sorted() {
            if lists[key]!.isEmpty {
                deletions.insert(key)
            } else {
                for item in lists[key]! { parameters.append(key, .string(item)) }
            }
        }
        if repeatsDeletions {
            for key in deletions.sorted() { parameters.append("delete", .string(key)) }
        } else if !deletions.isEmpty {
            parameters["delete"] = .string(deletions.sorted().joined(separator: ","))
        }
        return parameters
    }

    /// The differences between two serialized forms; nil values are settings to remove.
    static func between(_ old: [String: String?], _ new: [String: String?], oldLists: [String: [String]] = [:], newLists: [String: [String]] = [:]) -> SDNUpdate {
        var update = SDNUpdate()
        for (key, value) in new where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        for (key, list) in newLists where list != (oldLists[key] ?? []) {
            update.lists[key] = list
        }
        return update
    }
}

func trimmed(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

/// Comma-separated text as the API takes it, from text the user may have separated with spaces or semicolons.
func commaList(_ text: String) -> String? {
    let items = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init)
    return items.isEmpty ? nil : items.joined(separator: ",")
}

/// SDN identifiers: up to 8 letters and digits, starting with a letter.
func identifierProblem(_ id: String) -> String? {
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
    /// VXLAN: comma-separated peer addresses and the UDP port. VXLAN and EVPN: a fabric as underlay instead of peers.
    public var peers = ""
    public var vxlanPort = ""
    public var fabric = ""
    /// EVPN: the controller, the VNI of the zone's VRF, the VNets' anycast MAC and the exit nodes to other networks.
    public var controller = ""
    public var secondaryControllers: [String] = []
    public var vrfVXLAN = ""
    public var mac = ""
    public var exitNodes: Set<String> = []
    public var primaryExitNode = ""
    public var exitNodesLocalRouting = false
    public var advertisesSubnets = false
    public var disablesARPNDSuppression = false
    public var routeTargetImport = ""

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
        fabric = values["fabric"] ?? ""
        controller = values["controller"] ?? ""
        secondaryControllers = zone.lists["secondary-controllers"] ?? (values["secondary-controllers"] ?? "").split(separator: ",").map(String.init)
        vrfVXLAN = values["vrf-vxlan"] ?? ""
        mac = values["mac"] ?? ""
        exitNodes = Set((values["exitnodes"] ?? "").split(separator: ",").map(String.init))
        primaryExitNode = values["exitnodes-primary"] ?? ""
        exitNodesLocalRouting = values["exitnodes-local-routing"] == "1"
        advertisesSubnets = values["advertise-subnets"] == "1"
        disablesARPNDSuppression = values["disable-arp-nd-suppression"] == "1"
        routeTargetImport = values["rt-import"] ?? ""
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
            set("peers", commaList(peers))
            set("vxlan-port", trimmed(vxlanPort))
        }
        if type == .vxlan || type == .evpn { set("fabric", trimmed(fabric)) }
        if type == .evpn {
            set("controller", trimmed(controller))
            set("vrf-vxlan", trimmed(vrfVXLAN))
            set("mac", trimmed(mac))
            set("exitnodes", exitNodes.isEmpty ? nil : exitNodes.sorted().joined(separator: ","))
            set("exitnodes-primary", trimmed(primaryExitNode))
            set("exitnodes-local-routing", exitNodesLocalRouting ? "1" : nil)
            set("advertise-subnets", advertisesSubnets ? "1" : nil)
            set("disable-arp-nd-suppression", disablesARPNDSuppression ? "1" : nil)
            set("rt-import", commaList(routeTargetImport))
        }
        return values
    }

    func serializedLists() -> [String: [String]] {
        type == .evpn ? ["secondary-controllers": secondaryControllers.filter { $0 != controller }] : [:]
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["zone": .string(id), "type": .string(type.rawValue)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        for (key, list) in serializedLists().sorted(by: { $0.key < $1.key }) {
            for item in list { parameters.append(key, .string(item)) }
        }
        return parameters
    }

    public func changes(from original: SDNZoneDraft) -> SDNUpdate {
        SDNUpdate.between(original.serialized(), serialized(), oldLists: original.serializedLists(), newLists: serializedLists())
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
            if trimmed(peers) == nil, trimmed(fabric) == nil { problems["peers"] = String(localized: "Enter the addresses of the nodes, or choose a fabric.") }
            if let port = trimmed(vxlanPort), !(Int(port).map { (1...65535).contains($0) } ?? false) {
                problems["vxlan-port"] = String(localized: "Use a port from 1 to 65535.")
            }
        }
        if type == .evpn {
            if trimmed(controller) == nil { problems["controller"] = String(localized: "Choose an EVPN controller.") }
            if !(trimmed(vrfVXLAN).flatMap { Int($0) }.map { (1...16_000_000).contains($0) } ?? false) {
                problems["vrf-vxlan"] = String(localized: "Use a number from 1 to 16000000.")
            }
            if let mac = trimmed(mac), !isMACAddress(mac) { problems["mac"] = String(localized: "Enter a MAC address such as BC:24:11:00:00:01.") }
            if let primary = trimmed(primaryExitNode), !exitNodes.isEmpty, !exitNodes.contains(primary) {
                problems["exitnodes-primary"] = String(localized: "Choose one of the exit nodes.")
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
        let maximum = zoneType?.usesVNI == true ? 16_777_215 : 4094
        if let tag = trimmed(tag), zoneType?.allowsVNetTag != false {
            if !(Int(tag).map { (1...maximum).contains($0) } ?? false) {
                problems["tag"] = String(localized: "Use a number from 1 to \(maximum).")
            }
        } else if zoneType?.requiresVNetTag == true {
            problems["tag"] = zoneType?.usesVNI == true ? String(localized: "Enter the VXLAN ID (VNI).") : String(localized: "Enter the VLAN ID.")
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

    public static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in !part.isEmpty && part.count <= 3 && (Int(part).map { $0 <= 255 } ?? false) }
    }

    public static func isAddress(_ text: String) -> Bool {
        isIPv4(text) || (text.contains(":") && text.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." })
    }
}

func isMACAddress(_ text: String) -> Bool {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    return parts.count == 6 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
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

    /// Reserves an address of a VNet's subnet for a MAC address in the IPAM, right away (no Apply).
    public static func createIPMapping(vnet: String, zone: String, ip: String, mac: String) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/sdn/vnets/\(escapePath(vnet))/ips", parameters: ["zone": .string(zone), "ip": .string(ip), "mac": .string(mac)])
    }

    /// Moves a MAC address to another address. Guests' mappings carry their VM ID.
    public static func updateIPMapping(vnet: String, zone: String, ip: String, mac: String, vmid: Int?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["zone": .string(zone), "ip": .string(ip), "mac": .string(mac)]
        if let vmid { parameters["vmid"] = .int(vmid) }
        return APIRequest(.put, "/cluster/sdn/vnets/\(escapePath(vnet))/ips", parameters: parameters)
    }

    public static func deleteIPMapping(vnet: String, zone: String, ip: String, mac: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["zone": .string(zone), "ip": .string(ip)]
        if let mac { parameters["mac"] = .string(mac) }
        return APIRequest(.delete, "/cluster/sdn/vnets/\(escapePath(vnet))/ips", parameters: parameters)
    }
}
