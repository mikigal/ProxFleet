import Foundation
import ProxmoxCore

/// One entry of `GET /nodes/{node}/network`, as written in `/etc/network/interfaces` (or its pending `.new` copy).
public struct NetworkInterface: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    /// `eth`, `bridge`, `bond`, `vlan`, `alias`, `OVSBridge`, `OVSBond`, `OVSPort`, `OVSIntPort`…
    public var type: String
    /// Up right now. Interfaces added since the last apply are not.
    public var isActive: Bool
    public var autostart: Bool
    /// Physical interfaces: whether the device is present.
    public var exists: Bool?
    public var cidr: String?
    public var gateway: String?
    public var cidr6: String?
    public var gateway6: String?
    public var mtu: Int?
    public var comments: String?
    public var bridgePorts: [String]
    public var bridgeVLANAware: Bool
    public var bridgeVIDs: String?
    public var bondSlaves: [String]
    public var bondMode: String?
    public var bondPrimary: String?
    public var bondHashPolicy: String?
    public var vlanRawDevice: String?
    public var vlanID: Int?
    /// Other names of a physical interface, e.g. `enp6s18`.
    public var altNames: [String]
    public var ovsBridge: String?
    public var ovsPorts: [String]
    public var ovsBonds: [String]
    public var ovsTag: Int?
    public var ovsOptions: String?

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func string(_ key: String) -> String? {
            container.lossyString(AnyCodingKey(key)).flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        func list(_ key: String) -> [String] {
            (string(key) ?? "").split(separator: " ").map(String.init)
        }
        name = string("iface") ?? ""
        type = string("type") ?? "unknown"
        isActive = container.lossyBool(AnyCodingKey("active")) ?? false
        autostart = container.lossyBool(AnyCodingKey("autostart")) ?? false
        exists = container.lossyBool(AnyCodingKey("exists"))
        // Older servers report address and netmask only.
        if let cidr = string("cidr") {
            self.cidr = cidr
        } else if let address = string("address"), let netmask = string("netmask") {
            cidr = "\(address)/\(Self.prefixLength(netmask) ?? netmask)"
        }
        gateway = string("gateway")
        if let cidr6 = string("cidr6") {
            self.cidr6 = cidr6
        } else if let address = string("address6"), let netmask = string("netmask6") {
            cidr6 = "\(address)/\(netmask)"
        }
        gateway6 = string("gateway6")
        mtu = container.lossyInt(AnyCodingKey("mtu"))
        comments = string("comments")
        bridgePorts = list("bridge_ports")
        bridgeVLANAware = container.lossyBool(AnyCodingKey("bridge_vlan_aware")) ?? false
        bridgeVIDs = string("bridge_vids")
        bondSlaves = list("slaves")
        bondMode = string("bond_mode")
        bondPrimary = string("bond-primary")
        bondHashPolicy = string("bond_xmit_hash_policy")
        vlanRawDevice = string("vlan-raw-device")
        vlanID = container.lossyInt(AnyCodingKey("vlan-id"))
        var names: [String] = []
        if var nested = try? container.nestedUnkeyedContainer(forKey: AnyCodingKey("altnames")) {
            while !nested.isAtEnd {
                if let value = try? nested.decode(String.self) { names.append(value) } else { _ = try? nested.decode(Nothing.self) }
            }
        }
        altNames = names
        ovsBridge = string("ovs_bridge")
        ovsPorts = list("ovs_ports")
        ovsBonds = list("ovs_bonds")
        ovsTag = container.lossyInt(AnyCodingKey("ovs_tag"))
        ovsOptions = string("ovs_options")
    }

    public var isOVS: Bool { type.hasPrefix("OVS") }

    /// Interfaces the web interface lets you create and delete; physical ones are only edited.
    public var isRemovable: Bool { type != "eth" && type != "unknown" }

    /// Interfaces this one depends on: bridge ports, bond members, the VLAN's parent.
    public var memberInterfaces: [String] {
        bridgePorts + bondSlaves + ovsPorts + ovsBonds + [vlanRawDevice, ovsBridge].compactMap { $0 }
    }

    /// `255.255.255.0` → `24`.
    static func prefixLength(_ netmask: String) -> String? {
        if Int(netmask) != nil { return netmask }
        let octets = netmask.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return String(octets.reduce(0) { $0 + $1.nonzeroBitCount })
    }
}

/// The interfaces of a node plus the pending changes, a diff of `/etc/network/interfaces` against the `.new`
/// file that Apply Configuration activates. The diff comes in `changes`, next to `data`.
public struct NetworkConfiguration: EnvelopeDecodable, Sendable, Equatable {
    public var interfaces: [NetworkInterface]
    /// nil when nothing is pending.
    public var pendingChanges: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        interfaces = try container.decodeIfPresent([NetworkInterface].self, forKey: AnyCodingKey("data")) ?? []
        let changes = container.lossyString(AnyCodingKey("changes"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingChanges = changes?.isEmpty == false ? changes : nil
    }

    /// Ordered as in the web interface: by type, then by name.
    public var sortedInterfaces: [NetworkInterface] {
        let order = ["eth", "bond", "bridge", "vlan", "OVSBridge", "OVSBond", "OVSPort", "OVSIntPort", "alias"]
        return interfaces.sorted {
            let left = order.firstIndex(of: $0.type) ?? order.count
            let right = order.firstIndex(of: $1.type) ?? order.count
            return left != right ? left < right : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Interfaces that can be a bridge port or bond member: physical ones, bonds and VLANs not used elsewhere.
    public func freeInterfaces(excluding name: String? = nil) -> [String] {
        let used = Set(interfaces.filter { $0.name != name }.flatMap { $0.bridgePorts + $0.bondSlaves })
        return interfaces
            .filter { ["eth", "bond", "vlan"].contains($0.type) && $0.name != name && !used.contains($0.name) }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Bonding modes of Linux bonds, in the order of the web interface.
public enum BondMode {
    public static let all = ["balance-rr", "active-backup", "balance-xor", "broadcast", "802.3ad", "balance-tlb", "balance-alb"]
    public static let hashPolicies = ["layer2", "layer2+3", "layer3+4"]

    public static func usesHashPolicy(_ mode: String) -> Bool { mode == "balance-xor" || mode == "802.3ad" }
}

/// The settings of one interface as a form. Like `OptionsDraft`, it serializes the same way as the interface it
/// was made from, so an update sends only what the user changed, plus `delete` for cleared settings.
public struct NetworkInterfaceDraft: Equatable, Sendable {
    /// Linux interface types that can be created.
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case bridge, bond, vlan

        public var id: String { rawValue }
    }

    public var type: String
    public var name: String
    public var autostart = true
    public var cidr = ""
    public var gateway = ""
    public var cidr6 = ""
    public var gateway6 = ""
    public var mtu = ""
    public var comments = ""
    public var bridgePorts: [String] = []
    public var vlanAware = false
    public var bridgeVIDs = ""
    public var bondSlaves: [String] = []
    public var bondMode = "balance-rr"
    public var bondPrimary = ""
    public var hashPolicy = ""
    public var vlanRawDevice = ""
    public var vlanID = ""

    /// A new interface with the web interface's defaults and the first free name, e.g. `vmbr1`.
    public init(creating kind: Kind, existing: [NetworkInterface]) {
        type = kind.rawValue
        let prefix = kind == .bridge ? "vmbr" : kind == .bond ? "bond" : ""
        if prefix.isEmpty {
            name = ""
        } else {
            let names = Set(existing.map(\.name))
            name = prefix + String((0...).first { !names.contains("\(prefix)\($0)") }!)
        }
    }

    public init(_ interface: NetworkInterface) {
        type = interface.type
        name = interface.name
        autostart = interface.autostart
        cidr = interface.cidr ?? ""
        gateway = interface.gateway ?? ""
        cidr6 = interface.cidr6 ?? ""
        gateway6 = interface.gateway6 ?? ""
        mtu = interface.mtu.map(String.init) ?? ""
        comments = interface.comments ?? ""
        bridgePorts = interface.bridgePorts
        vlanAware = interface.bridgeVLANAware
        bridgeVIDs = interface.bridgeVIDs ?? ""
        bondSlaves = interface.bondSlaves
        bondMode = interface.bondMode ?? "balance-rr"
        bondPrimary = interface.bondPrimary ?? ""
        hashPolicy = interface.bondHashPolicy ?? ""
        vlanRawDevice = interface.vlanRawDevice ?? ""
        vlanID = interface.vlanID.map(String.init) ?? ""
    }

    /// `vmbr0.20` style names carry the parent and VLAN ID themselves.
    public var namesVLAN: Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return Int(name[name.index(after: dot)...]) != nil
    }

    public var isBridge: Bool { type == "bridge" }
    public var isBond: Bool { type == "bond" }
    public var isVLAN: Bool { type == "vlan" }

    private static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The settings this form manages; nil means "not set".
    func serialized() -> [String: String?] {
        var values: [String: String?] = [
            "autostart": autostart ? "1" : nil,
            "cidr": Self.trimmed(cidr),
            "gateway": Self.trimmed(gateway),
            "cidr6": Self.trimmed(cidr6),
            "gateway6": Self.trimmed(gateway6),
            "mtu": Self.trimmed(mtu),
            "comments": Self.trimmed(comments),
        ]
        // updateValue keeps nil values, which mark settings to delete; assigning nil would drop the key.
        if isBridge {
            values.updateValue(bridgePorts.isEmpty ? nil : bridgePorts.joined(separator: " "), forKey: "bridge_ports")
            values.updateValue(vlanAware ? "1" : nil, forKey: "bridge_vlan_aware")
            values.updateValue(vlanAware ? Self.trimmed(bridgeVIDs) : nil, forKey: "bridge_vids")
        }
        if isBond {
            values.updateValue(bondSlaves.isEmpty ? nil : bondSlaves.joined(separator: " "), forKey: "slaves")
            values.updateValue(bondMode, forKey: "bond_mode")
            values.updateValue(bondMode == "active-backup" ? Self.trimmed(bondPrimary) : nil, forKey: "bond-primary")
            values.updateValue(BondMode.usesHashPolicy(bondMode) ? Self.trimmed(hashPolicy) : nil, forKey: "bond_xmit_hash_policy")
        }
        if isVLAN, !namesVLAN {
            values.updateValue(Self.trimmed(vlanRawDevice), forKey: "vlan-raw-device")
            values.updateValue(Self.trimmed(vlanID), forKey: "vlan-id")
        }
        return values
    }

    /// Parameters of `POST /nodes/{node}/network`.
    var creationParameters: APIParameters {
        var parameters: APIParameters = ["iface": .string(name.trimmingCharacters(in: .whitespaces)), "type": .string(type)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        return parameters
    }

    /// The changes against the interface the form was opened with. Empty when nothing changed.
    public func changes(from original: NetworkInterfaceDraft) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let old = original.serialized()
        for (key, value) in serialized() where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        return update
    }

    /// Problems the app can see itself, by parameter name as the server reports them.
    public var problems: [String: String] {
        var problems: [String: String] = [:]
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            problems["iface"] = String(localized: "Enter a name.")
        } else if name.count > 20 || name.contains(where: { !($0.isLetter || $0.isNumber || "-_.".contains($0)) }) {
            problems["iface"] = String(localized: "Use up to 20 letters, digits, and - _ . only.")
        }
        if let mtu = Self.trimmed(mtu), !(Int(mtu).map { (1280...65520).contains($0) } ?? false) {
            problems["mtu"] = String(localized: "Enter a value from 1280 to 65520.")
        }
        if Self.trimmed(gateway) != nil, Self.trimmed(cidr) == nil {
            problems["gateway"] = String(localized: "A gateway needs an IPv4 address.")
        }
        if Self.trimmed(gateway6) != nil, Self.trimmed(cidr6) == nil {
            problems["gateway6"] = String(localized: "A gateway needs an IPv6 address.")
        }
        for (key, value) in [("cidr", cidr), ("cidr6", cidr6)] {
            if let value = Self.trimmed(value), !value.contains("/") {
                problems[key] = String(localized: "Include the prefix length, e.g. /24.")
            }
        }
        if isVLAN, !namesVLAN {
            if Self.trimmed(vlanRawDevice) == nil {
                problems["vlan-raw-device"] = String(localized: "Choose the parent interface, or name the VLAN like vmbr0.20.")
            }
            if !(Int(vlanID).map { (1...4094).contains($0) } ?? false) {
                problems["vlan-id"] = String(localized: "Enter a VLAN ID from 1 to 4094.")
            }
        }
        return problems
    }
}

extension PVE {
    /// The node's interfaces and the pending changes.
    public static func network(node: String) -> APIRequest<NetworkConfiguration> {
        APIRequest(.get, "/nodes/\(node)/network")
    }

    /// Adds an interface to the pending configuration.
    public static func createInterface(node: String, _ draft: NetworkInterfaceDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/nodes/\(node)/network", parameters: draft.creationParameters)
    }

    /// Changes an interface in the pending configuration. Settings not sent stay as they are.
    public static func updateInterface(node: String, name: String, type: String, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        var parameters = update.parameters
        parameters["type"] = .string(type)
        return APIRequest(.put, "/nodes/\(node)/network/\(escapePath(name))", parameters: parameters)
    }

    public static func deleteInterface(node: String, name: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/nodes/\(node)/network/\(escapePath(name))")
    }

    /// Activates the pending configuration (`ifreload`). Returns a task ID.
    public static func applyNetwork(node: String) -> APIRequest<String?> {
        APIRequest(.put, "/nodes/\(node)/network")
    }

    /// Discards the pending configuration.
    public static func revertNetwork(node: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/nodes/\(node)/network")
    }
}
