import Foundation
import ProxmoxCore

/// Where a firewall configuration lives. Security groups only have rules; nodes have no aliases or IP sets.
public enum FirewallScope: Sendable, Hashable {
    case datacenter
    case node(String)
    case guest(GuestReference)
    /// The rules of a security group of the datacenter.
    case group(String)
    /// An SDN VNet: forward rules for traffic between its guests and to other networks.
    case vnet(String, zone: String)

    var basePath: String {
        switch self {
        case .datacenter: "/cluster/firewall"
        case .node(let node): "/nodes/\(node)/firewall"
        case .guest(let guest): guest.path + "/firewall"
        case .group(let name): "/cluster/firewall/groups/\(PVE.escapePath(name))"
        case .vnet(let vnet, _): "/cluster/sdn/vnets/\(PVE.escapePath(vnet))/firewall"
        }
    }

    var rulesPath: String {
        if case .group = self { return basePath }
        return basePath + "/rules"
    }

    /// Nodes and security groups use the datacenter's aliases and IP sets.
    var referencesPath: String {
        switch self {
        case .guest: basePath + "/refs"
        default: "/cluster/firewall/refs"
        }
    }

    public var hasAliasesAndIPSets: Bool {
        switch self {
        case .datacenter, .guest: true
        case .node, .group, .vnet: false
        }
    }

    public var hasOptions: Bool {
        if case .group = self { return false }
        return true
    }

    public var hasLog: Bool {
        switch self {
        case .node, .guest: true
        case .datacenter, .group, .vnet: false
        }
    }

    /// Directions the web interface offers here. Guests have no forward rules, VNets only those.
    public var directions: [FirewallRule.Direction] {
        switch self {
        case .guest: [.in, .out]
        case .vnet: [.forward]
        default: [.in, .out, .forward]
        }
    }

    /// The path whose privileges decide what the user may change.
    public var aclPath: String {
        switch self {
        case .datacenter, .group: "/"
        case .node(let node): "/nodes/\(node)"
        case .guest(let guest): guest.aclPath
        case .vnet(let vnet, let zone): "/sdn/zones/\(zone)/\(vnet)"
        }
    }

    /// The privilege changes need on `aclPath`.
    public var modifyPrivilege: String {
        switch self {
        case .guest: "VM.Config.Network"
        case .vnet: "SDN.Allocate"
        default: "Sys.Modify"
        }
    }
}

/// One rule of `GET .../firewall/rules`, in the order the firewall checks them.
public struct FirewallRule: Decodable, Sendable, Equatable, Identifiable {
    public enum Direction: String, CaseIterable, Sendable, Identifiable {
        case `in`, out, forward

        public var id: String { rawValue }
    }

    public var position: Int
    /// `in`, `out`, `forward`, or `group` for a rule that applies a security group.
    public var type: String
    /// `ACCEPT`, `DROP`, `REJECT`, or the security group's name.
    public var action: String
    public var isEnabled: Bool
    public var macro: String?
    public var source: String?
    public var destination: String?
    public var proto: String?
    public var destinationPort: String?
    public var sourcePort: String?
    public var icmpType: String?
    public var interface: String?
    public var logLevel: String?
    public var comment: String?
    /// Set when the addresses only fit one IP version.
    public var ipVersion: Int?
    /// Problems the server found, by setting, e.g. a source that names an IP set that no longer exists.
    public var errors: [String: String]
    public var digest: String?

    public var id: Int { position }
    public var isGroup: Bool { type == "group" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func text(_ key: String) -> String? {
            container.lossyString(AnyCodingKey(key))?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        }
        position = container.lossyInt(AnyCodingKey("pos")) ?? 0
        type = text("type") ?? "in"
        action = text("action") ?? ""
        isEnabled = container.lossyBool(AnyCodingKey("enable")) ?? false
        macro = text("macro")
        source = text("source")
        destination = text("dest")
        proto = text("proto")
        destinationPort = text("dport")
        sourcePort = text("sport")
        icmpType = text("icmp-type")
        interface = text("iface")
        logLevel = text("log").flatMap { $0 == "nolog" ? nil : $0 }
        comment = text("comment")
        ipVersion = container.lossyInt(AnyCodingKey("ipversion"))
        errors = (try? container.decodeIfPresent([String: String].self, forKey: AnyCodingKey("errors"))) ?? [:]
        digest = text("digest")
    }
}

/// The form for a firewall rule. Settings that do not apply to the chosen kind of rule are sent as deletions,
/// as the web interface clears them: a macro brings its own protocol and ports, a security group only takes
/// an interface.
public struct FirewallRuleDraft: Equatable, Sendable {
    public static let actions = ["ACCEPT", "DROP", "REJECT"]
    /// Forward rules cannot reject.
    public static let forwardActions = ["ACCEPT", "DROP"]
    public static let logLevels = ["nolog", "emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"]
    public static let protocols = ["tcp", "udp", "icmp", "icmpv6", "sctp", "gre", "esp", "ah", "igmp", "ospf", "vrrp"]
    public static let icmpTypes = [
        "any", "echo-request", "echo-reply", "destination-unreachable", "port-unreachable", "host-unreachable",
        "fragmentation-needed", "time-exceeded", "redirect", "router-advertisement", "router-solicitation",
    ]
    public static let icmpv6Types = [
        "any", "echo-request", "echo-reply", "destination-unreachable", "packet-too-big", "time-exceeded",
        "router-solicitation", "router-advertisement", "neighbour-solicitation", "neighbour-advertisement",
    ]

    public var isEnabled = true
    /// A direction (`in`, `out`, `forward`) or `group`.
    public var type = "in"
    public var action = "ACCEPT"
    /// The security group applied, for rules of type `group`.
    public var group = ""
    public var macro = ""
    public var source = ""
    public var destination = ""
    public var proto = ""
    public var destinationPort = ""
    public var sourcePort = ""
    public var icmpType = ""
    public var interface = ""
    public var logLevel = "nolog"
    public var comment = ""

    public init() {}

    public init(_ rule: FirewallRule) {
        isEnabled = rule.isEnabled
        type = rule.type
        if rule.isGroup { group = rule.action } else { action = rule.action }
        macro = rule.macro ?? ""
        source = rule.source ?? ""
        destination = rule.destination ?? ""
        proto = rule.proto ?? ""
        destinationPort = rule.destinationPort ?? ""
        sourcePort = rule.sourcePort ?? ""
        icmpType = rule.icmpType ?? ""
        interface = rule.interface ?? ""
        logLevel = rule.logLevel ?? "nolog"
        comment = rule.comment ?? ""
    }

    public var isGroup: Bool { type == "group" }
    public var usesMacro: Bool { !isGroup && Self.text(macro) != nil }
    public var isICMP: Bool { ["icmp", "icmpv6", "ipv6-icmp"].contains(proto.trimmingCharacters(in: .whitespaces).lowercased()) }
    /// Ports need a protocol that has them; a macro brings its own.
    public var takesPorts: Bool { !isGroup && !usesMacro && !isICMP }

    private static func text(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        // updateValue keeps nil values, which mark settings to delete; assigning nil would drop the key.
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        let isGroup = isGroup
        set("enable", isEnabled ? "1" : "0")
        set("type", type)
        set("action", isGroup ? Self.text(group) : action)
        set("iface", Self.text(interface))
        set("comment", Self.text(comment))
        set("macro", isGroup ? nil : Self.text(macro))
        set("source", isGroup ? nil : Self.text(source))
        set("dest", isGroup ? nil : Self.text(destination))
        set("proto", isGroup || usesMacro ? nil : Self.text(proto))
        set("dport", takesPorts ? Self.text(destinationPort) : nil)
        set("sport", takesPorts ? Self.text(sourcePort) : nil)
        set("icmp-type", !isGroup && !usesMacro && isICMP ? Self.text(icmpType) : nil)
        set("log", isGroup || logLevel == "nolog" ? nil : logLevel)
        return values
    }

    var creationParameters: APIParameters {
        var parameters = APIParameters()
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        return parameters
    }

    public func changes(from original: FirewallRuleDraft) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let old = original.serialized()
        for (key, value) in serialized() where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        return update
    }

    /// What the app can check itself, by parameter name like the server's validation errors.
    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if isGroup, Self.text(group) == nil { problems["action"] = String(localized: "Choose a security group.") }
        if takesPorts, Self.text(proto) == nil, Self.text(destinationPort) != nil || Self.text(sourcePort) != nil {
            problems["proto"] = String(localized: "Ports need a protocol such as tcp or udp.")
        }
        if type == "forward", action == "REJECT" { problems["action"] = String(localized: "Forward rules can only accept or drop.") }
        return problems
    }
}

/// An IP or network with a name, usable in rules and IP sets (`GET .../firewall/aliases`).
public struct FirewallAlias: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var cidr: String
    public var comment: String?
    public var ipVersion: Int?
    public var digest: String?

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        cidr = container.lossyString(AnyCodingKey("cidr")) ?? ""
        comment = container.lossyString(AnyCodingKey("comment"))?.nilIfEmpty
        ipVersion = container.lossyInt(AnyCodingKey("ipversion"))
        digest = container.lossyString(AnyCodingKey("digest"))
    }
}

/// A named list of addresses, referred to as `+name` in rules (`GET .../firewall/ipset`).
public struct FirewallIPSet: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var comment: String?
    public var digest: String?

    public var id: String { name }
    /// IP sets the firewall itself uses when they exist, with what they do.
    public var specialPurpose: String? {
        switch name {
        case "management": String(localized: "Hosts allowed to reach the web interface and SSH of the nodes.")
        case "blacklist": String(localized: "Traffic from these addresses is always dropped.")
        case let name where name.hasPrefix("ipfilter-net"): String(localized: "Addresses the guest may use on \(String(name.dropFirst(9))).")
        default: nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        comment = container.lossyString(AnyCodingKey("comment"))?.nilIfEmpty
        digest = container.lossyString(AnyCodingKey("digest"))
    }
}

/// An address, network or alias in an IP set. `nomatch` entries are left out of the set.
public struct FirewallIPSetEntry: Decodable, Sendable, Equatable, Identifiable {
    public var cidr: String
    public var comment: String?
    public var isExcluded: Bool
    public var errors: [String: String]
    public var digest: String?

    public var id: String { cidr }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        cidr = container.lossyString(AnyCodingKey("cidr")) ?? ""
        comment = container.lossyString(AnyCodingKey("comment"))?.nilIfEmpty
        isExcluded = container.lossyBool(AnyCodingKey("nomatch")) ?? false
        errors = (try? container.decodeIfPresent([String: String].self, forKey: AnyCodingKey("errors"))) ?? [:]
        digest = container.lossyString(AnyCodingKey("digest"))
    }
}

/// A security group: a set of rules that rules of type `group` apply (`GET /cluster/firewall/groups`).
public struct FirewallGroup: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var comment: String?
    public var digest: String?

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("group")) ?? ""
        comment = container.lossyString(AnyCodingKey("comment"))?.nilIfEmpty
        digest = container.lossyString(AnyCodingKey("digest"))
    }
}

/// A standard rule set such as `SSH` or `HTTPS` (`GET /cluster/firewall/macros`).
public struct FirewallMacro: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("macro")) ?? ""
        description = container.lossyString(AnyCodingKey("descr")) ?? ""
    }
}

/// An alias or IP set usable as a rule's source or destination (`GET .../firewall/refs`).
public struct FirewallReference: Decodable, Sendable, Equatable, Identifiable {
    public var isIPSet: Bool
    public var name: String
    /// What goes into the rule: the alias name, or `+name` for an IP set.
    public var reference: String
    /// `dc` for the datacenter's, `guest` for the guest's own.
    public var scope: String
    public var comment: String?

    public var id: String { "\(scope)/\(reference)" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        isIPSet = container.lossyString(AnyCodingKey("type")) == "ipset"
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        reference = container.lossyString(AnyCodingKey("ref")) ?? name
        scope = container.lossyString(AnyCodingKey("scope")) ?? "dc"
        comment = container.lossyString(AnyCodingKey("comment"))?.nilIfEmpty
    }
}

/// `GET .../firewall/options`: every option the server has stored, as text, plus the digest of the file.
public struct FirewallOptions: Decodable, Sendable, Equatable {
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

    /// Whether the firewall is on here. Nodes default to on, the datacenter and guests to off.
    public func isEnabled(in scope: FirewallScope) -> Bool {
        guard let value = values["enable"] else {
            if case .node = scope { return true }
            return false
        }
        return value != "0"
    }
}

/// One option of a firewall options screen, with the default the server uses when it is not set.
public struct FirewallOptionSpec: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case flag(default: Bool)
        case choice([String], default: String)
        case number(default: Int, range: ClosedRange<Int>)
        /// A comma-separated subset, e.g. conntrack helpers.
        case set([String])
        /// `log_ratelimit`: `enable=1,rate=1/second,burst=5`.
        case rateLimit
    }

    public var key: String
    public var title: String
    public var kind: Kind
    public var footer: String?

    public var id: String { key }

    static let policies = ["ACCEPT", "REJECT", "DROP"]

    /// The options the web interface shows for each scope, in its order.
    public static func options(for scope: FirewallScope) -> [FirewallOptionSpec] {
        let levels = FirewallRuleDraft.logLevels
        switch scope {
        case .datacenter:
            return [
                .init(key: "enable", title: String(localized: "Firewall"), kind: .flag(default: false)),
                .init(key: "policy_in", title: String(localized: "Input Policy"), kind: .choice(policies, default: "DROP")),
                .init(key: "policy_out", title: String(localized: "Output Policy"), kind: .choice(policies, default: "ACCEPT")),
                .init(key: "policy_forward", title: String(localized: "Forward Policy"), kind: .choice(["ACCEPT", "DROP"], default: "ACCEPT"),
                      footer: String(localized: "Forwarded traffic is only filtered with the nftables firewall of the nodes.")),
                .init(key: "ebtables", title: String(localized: "ebtables"), kind: .flag(default: true)),
                .init(key: "log_ratelimit", title: String(localized: "Log Rate Limit"), kind: .rateLimit),
            ]
        case .node:
            return [
                .init(key: "enable", title: String(localized: "Firewall"), kind: .flag(default: true)),
                .init(key: "nosmurfs", title: String(localized: "SMURFS Filter"), kind: .flag(default: true)),
                .init(key: "tcpflags", title: String(localized: "TCP Flags Filter"), kind: .flag(default: false)),
                .init(key: "ndp", title: String(localized: "NDP"), kind: .flag(default: true)),
                .init(key: "nftables", title: String(localized: "nftables (Tech Preview)"), kind: .flag(default: false)),
                .init(key: "log_level_in", title: String(localized: "Log Level In"), kind: .choice(levels, default: "nolog")),
                .init(key: "log_level_out", title: String(localized: "Log Level Out"), kind: .choice(levels, default: "nolog")),
                .init(key: "log_level_forward", title: String(localized: "Log Level Forward"), kind: .choice(levels, default: "nolog")),
                .init(key: "tcp_flags_log_level", title: String(localized: "TCP Flags Log Level"), kind: .choice(levels, default: "nolog")),
                .init(key: "smurf_log_level", title: String(localized: "SMURFS Log Level"), kind: .choice(levels, default: "nolog")),
                .init(key: "nf_conntrack_max", title: String(localized: "Max Connections"), kind: .number(default: 262_144, range: 32768...16_777_216)),
                .init(key: "nf_conntrack_tcp_timeout_established", title: String(localized: "Established Timeout"), kind: .number(default: 432_000, range: 7875...4_294_967_295),
                      footer: String(localized: "Seconds an idle established TCP connection stays tracked.")),
                .init(key: "nf_conntrack_tcp_timeout_syn_recv", title: String(localized: "SYN-RECV Timeout"), kind: .number(default: 60, range: 30...60)),
                .init(key: "nf_conntrack_allow_invalid", title: String(localized: "Allow Invalid Packets"), kind: .flag(default: false)),
                .init(key: "log_nf_conntrack", title: String(localized: "Log Connection Tracking"), kind: .flag(default: false)),
                .init(key: "nf_conntrack_helpers", title: String(localized: "Conntrack Helpers"),
                      kind: .set(["amanda", "ftp", "irc", "netbios-ns", "pptp", "sane", "sip", "snmp", "tftp"])),
                .init(key: "protection_synflood", title: String(localized: "SYN Flood Protection"), kind: .flag(default: false)),
                .init(key: "protection_synflood_rate", title: String(localized: "SYN Flood Rate"), kind: .number(default: 200, range: 1...1_000_000),
                      footer: String(localized: "SYN packets per second and source address.")),
                .init(key: "protection_synflood_burst", title: String(localized: "SYN Flood Burst"), kind: .number(default: 1000, range: 1...1_000_000)),
            ]
        case .guest:
            return [
                .init(key: "enable", title: String(localized: "Firewall"), kind: .flag(default: false)),
                .init(key: "policy_in", title: String(localized: "Input Policy"), kind: .choice(policies, default: "DROP")),
                .init(key: "policy_out", title: String(localized: "Output Policy"), kind: .choice(policies, default: "ACCEPT")),
                .init(key: "dhcp", title: String(localized: "DHCP"), kind: .flag(default: true)),
                .init(key: "ndp", title: String(localized: "NDP"), kind: .flag(default: true)),
                .init(key: "radv", title: String(localized: "Router Advertisement"), kind: .flag(default: false)),
                .init(key: "macfilter", title: String(localized: "MAC Filter"), kind: .flag(default: true)),
                .init(key: "ipfilter", title: String(localized: "IP Filter"), kind: .flag(default: false),
                      footer: String(localized: "Only lets the guest use its own addresses, or those of its ipfilter-net IP sets.")),
                .init(key: "log_level_in", title: String(localized: "Log Level In"), kind: .choice(levels, default: "nolog")),
                .init(key: "log_level_out", title: String(localized: "Log Level Out"), kind: .choice(levels, default: "nolog")),
            ]
        case .vnet:
            return [
                .init(key: "enable", title: String(localized: "Firewall"), kind: .flag(default: false)),
                .init(key: "policy_forward", title: String(localized: "Forward Policy"), kind: .choice(["ACCEPT", "DROP"], default: "ACCEPT")),
                .init(key: "log_level_forward", title: String(localized: "Log Level Forward"), kind: .choice(levels, default: "nolog")),
            ]
        case .group:
            return []
        }
    }
}

/// `log_ratelimit` of the datacenter options.
public struct FirewallLogRateLimit: Equatable, Sendable {
    public var isEnabled = true
    /// `1/second`, `30/minute`…
    public var rate = "1/second"
    public var burst = 5

    public init(_ text: String?) {
        let property = PropertyString(parsing: text ?? "")
        isEnabled = (property["enable"] ?? property.defaultValue ?? "1") != "0"
        rate = property["rate"] ?? "1/second"
        burst = property["burst"].flatMap { Int($0) } ?? 5
    }

    var serialized: String? {
        guard self != FirewallLogRateLimit(nil) else { return nil }
        var property = PropertyString(items: [])
        property["enable"] = isEnabled ? "1" : "0"
        if rate != "1/second" { property["rate"] = rate }
        if burst != 5 { property["burst"] = String(burst) }
        return property.stringValue
    }
}

/// The options of one scope as editable values. Values equal to the default serialize as unset, so the
/// server's way of storing them never shows up as a change, as with `OptionsDraft`.
public struct FirewallOptionsDraft: OptionsDraft, Sendable {
    public let specs: [FirewallOptionSpec]
    public var values: [String: String]

    public init(_ options: FirewallOptions, scope: FirewallScope) {
        specs = FirewallOptionSpec.options(for: scope)
        values = options.values
    }

    public func flag(_ key: String) -> Bool {
        guard case .flag(let defaultValue) = specs.first(where: { $0.key == key })?.kind else { return values[key] == "1" }
        return values[key].map { $0 != "0" } ?? defaultValue
    }

    public mutating func setFlag(_ key: String, _ on: Bool) {
        values[key] = on ? "1" : "0"
    }

    public func choice(_ key: String) -> String {
        if let value = values[key] { return value }
        if case .choice(_, let defaultValue) = specs.first(where: { $0.key == key })?.kind { return defaultValue }
        return ""
    }

    public func number(_ key: String) -> Int {
        if let value = values[key].flatMap({ Int($0) }) { return value }
        if case .number(let defaultValue, _) = specs.first(where: { $0.key == key })?.kind { return defaultValue }
        return 0
    }

    public func members(_ key: String) -> Set<String> {
        Set((values[key] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public mutating func setMembers(_ key: String, _ members: Set<String>) {
        values[key] = members.sorted().joined(separator: ",")
    }

    public var rateLimit: FirewallLogRateLimit {
        get { FirewallLogRateLimit(values["log_ratelimit"]) }
        set { values["log_ratelimit"] = newValue.serialized }
    }

    public func serialized() -> [String: String?] {
        var result: [String: String?] = [:]
        for spec in specs {
            let value: String?
            switch spec.kind {
            case .flag(let defaultValue):
                value = flag(spec.key) == defaultValue ? nil : (flag(spec.key) ? "1" : "0")
            case .choice(_, let defaultValue):
                value = choice(spec.key) == defaultValue ? nil : choice(spec.key)
            case .number(let defaultValue, _):
                value = number(spec.key) == defaultValue ? nil : String(number(spec.key))
            case .set:
                let members = members(spec.key)
                value = members.isEmpty ? nil : members.sorted().joined(separator: ",")
            case .rateLimit:
                value = rateLimit.serialized
            }
            result.updateValue(value, forKey: spec.key)
        }
        return result
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        for spec in specs {
            if case .number(_, let range) = spec.kind, let text = values[spec.key], !text.isEmpty {
                if let number = Int(text), range.contains(number) { continue }
                problems[spec.key] = String(localized: "Enter a number from \(range.lowerBound) to \(range.upperBound).")
            }
        }
        let rate = rateLimit.rate
        if rate.wholeMatch(of: /[1-9][0-9]*\/(second|minute|hour|day)/) == nil {
            problems["log_ratelimit"] = String(localized: "Enter a rate such as 1/second or 30/minute.")
        }
        return problems
    }
}

/// `GET .../firewall/log`: lines with their numbers, plus the total, which comes next to `data`.
public struct FirewallLog: EnvelopeDecodable, Sendable, Equatable {
    public struct Line: Decodable, Sendable, Equatable, Identifiable {
        public var number: Int
        public var text: String

        public var id: Int { number }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            number = container.lossyInt(AnyCodingKey("n")) ?? 0
            text = container.lossyString(AnyCodingKey("t")) ?? ""
        }
    }

    public var lines: [Line]
    public var total: Int

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let lines = (try container.decodeIfPresent([Line].self, forKey: AnyCodingKey("data"))) ?? []
        // An empty log comes back as a single line saying so.
        self.lines = lines.count == 1 && lines[0].text == "no content" ? [] : lines
        total = self.lines.isEmpty ? 0 : container.lossyInt(AnyCodingKey("total")) ?? lines.count
    }
}

extension PVE {
    // MARK: Rules

    public static func firewallRules(_ scope: FirewallScope) -> APIRequest<[FirewallRule]> {
        APIRequest(.get, scope.rulesPath)
    }

    /// New rules go to the top, as in the web interface.
    public static func createFirewallRule(_ scope: FirewallScope, _ draft: FirewallRuleDraft) -> APIRequest<Nothing> {
        APIRequest(.post, scope.rulesPath, parameters: draft.creationParameters)
    }

    public static func updateFirewallRule(_ scope: FirewallScope, position: Int, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "\(scope.rulesPath)/\(position)", parameters: update.parameters)
    }

    /// Moves a rule in front of the rule now at `offset`; an offset past the end moves it to the bottom. This is
    /// what `moveto` does, and what SwiftUI's `onMove` reports.
    public static func moveFirewallRule(_ scope: FirewallScope, position: Int, to offset: Int, digest: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["moveto": .int(offset)]
        if let digest { parameters["digest"] = .string(digest) }
        return APIRequest(.put, "\(scope.rulesPath)/\(position)", parameters: parameters)
    }

    public static func deleteFirewallRule(_ scope: FirewallScope, position: Int, digest: String?) -> APIRequest<Nothing> {
        APIRequest(.delete, "\(scope.rulesPath)/\(position)", parameters: digest.map { ["digest": .string($0)] } ?? [:])
    }

    // MARK: Options, references, macros and log

    public static func firewallOptions(_ scope: FirewallScope) -> APIRequest<FirewallOptions> {
        APIRequest(.get, scope.basePath + "/options")
    }

    public static func updateFirewallOptions(_ scope: FirewallScope, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, scope.basePath + "/options", parameters: update.parameters)
    }

    public static func firewallReferences(_ scope: FirewallScope) -> APIRequest<[FirewallReference]> {
        APIRequest(.get, scope.referencesPath)
    }

    public static func firewallMacros() -> APIRequest<[FirewallMacro]> {
        APIRequest(.get, "/cluster/firewall/macros")
    }

    public static func firewallLog(_ scope: FirewallScope, start: Int, limit: Int) -> APIRequest<FirewallLog> {
        APIRequest(.get, scope.basePath + "/log", parameters: ["start": .int(start), "limit": .int(limit)])
    }

    // MARK: Aliases

    public static func firewallAliases(_ scope: FirewallScope) -> APIRequest<[FirewallAlias]> {
        APIRequest(.get, scope.basePath + "/aliases")
    }

    public static func createFirewallAlias(_ scope: FirewallScope, name: String, cidr: String, comment: String) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["name": .string(name), "cidr": .string(cidr)]
        if !comment.isEmpty { parameters["comment"] = .string(comment) }
        return APIRequest(.post, scope.basePath + "/aliases", parameters: parameters)
    }

    /// Renaming does not update rules that use the old name; the server marks them with errors.
    /// An empty comment removes it.
    public static func updateFirewallAlias(_ scope: FirewallScope, name: String, newName: String, cidr: String, comment: String, digest: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["cidr": .string(cidr), "comment": .string(comment)]
        if newName != name { parameters["rename"] = .string(newName) }
        if let digest { parameters["digest"] = .string(digest) }
        return APIRequest(.put, scope.basePath + "/aliases/\(escapePath(name))", parameters: parameters)
    }

    public static func deleteFirewallAlias(_ scope: FirewallScope, name: String) -> APIRequest<Nothing> {
        APIRequest(.delete, scope.basePath + "/aliases/\(escapePath(name))")
    }

    // MARK: IP sets

    public static func firewallIPSets(_ scope: FirewallScope) -> APIRequest<[FirewallIPSet]> {
        APIRequest(.get, scope.basePath + "/ipset")
    }

    /// Creates an IP set, or renames one and changes its comment when `renaming` names an existing set: the
    /// server takes the new name as `name` and the old one as `rename`.
    public static func saveFirewallIPSet(_ scope: FirewallScope, name: String, comment: String, renaming: String? = nil) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["name": .string(name)]
        if renaming != nil || !comment.isEmpty { parameters["comment"] = .string(comment) }
        if let renaming { parameters["rename"] = .string(renaming) }
        return APIRequest(.post, scope.basePath + "/ipset", parameters: parameters)
    }

    /// `force` also removes the entries; without it, the server refuses a set that is not empty.
    public static func deleteFirewallIPSet(_ scope: FirewallScope, name: String) -> APIRequest<Nothing> {
        APIRequest(.delete, scope.basePath + "/ipset/\(escapePath(name))", parameters: ["force": true])
    }

    public static func firewallIPSetEntries(_ scope: FirewallScope, set: String) -> APIRequest<[FirewallIPSetEntry]> {
        APIRequest(.get, scope.basePath + "/ipset/\(escapePath(set))")
    }

    public static func addFirewallIPSetEntry(_ scope: FirewallScope, set: String, cidr: String, comment: String, excluded: Bool) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["cidr": .string(cidr)]
        if !comment.isEmpty { parameters["comment"] = .string(comment) }
        if excluded { parameters["nomatch"] = true }
        return APIRequest(.post, scope.basePath + "/ipset/\(escapePath(set))", parameters: parameters)
    }

    public static func updateFirewallIPSetEntry(_ scope: FirewallScope, set: String, cidr: String, comment: String, excluded: Bool, digest: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["comment": .string(comment), "nomatch": .bool(excluded)]
        if let digest { parameters["digest"] = .string(digest) }
        return APIRequest(.put, scope.basePath + "/ipset/\(escapePath(set))/\(escapePath(cidr))", parameters: parameters)
    }

    public static func deleteFirewallIPSetEntry(_ scope: FirewallScope, set: String, cidr: String) -> APIRequest<Nothing> {
        APIRequest(.delete, scope.basePath + "/ipset/\(escapePath(set))/\(escapePath(cidr))")
    }

    // MARK: Security groups

    public static func firewallGroups() -> APIRequest<[FirewallGroup]> {
        APIRequest(.get, "/cluster/firewall/groups")
    }

    /// Creates a security group, or renames one like `saveFirewallIPSet`. Renaming updates the rules that use it.
    public static func saveFirewallGroup(name: String, comment: String, renaming: String? = nil) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["group": .string(name)]
        if renaming != nil || !comment.isEmpty { parameters["comment"] = .string(comment) }
        if let renaming { parameters["rename"] = .string(renaming) }
        return APIRequest(.post, "/cluster/firewall/groups", parameters: parameters)
    }

    /// The server refuses groups that still have rules.
    public static func deleteFirewallGroup(_ name: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/firewall/groups/\(escapePath(name))")
    }
}
