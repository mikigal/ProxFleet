import Foundation
import ProxmoxCore

/// One entry of `GET /cluster/ha/status/current`: the quorum, the CRM master, fencing, a node's LRM or a resource.
public struct HAStatusEntry: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case quorum, master, fencing, lrm, service
    }

    /// `quorum`, `master`, `fencing`, `lrm:<node>` or `service:<sid>`.
    public var id: String
    public var kind: Kind?
    public var node: String
    /// A summary like `pve1 (active, watchdog active, …)` or `vm:100 (pve1, started)`.
    public var status: String

    // Resources only.
    public var sid: String?
    /// The state the resource is in, like `started`, `migrate`, `fence` or `error`.
    public var state: String?
    public var requestedState: String?

    // Quorum and fencing only.
    public var isQuorate: Bool?
    /// `armed`, `standby`, `disarming` or `disarmed`.
    public var armedState: String?
    /// While disarmed: `freeze` or `ignore`.
    public var resourceMode: String?

    public init(id: String, kind: Kind?, node: String, status: String, sid: String? = nil, state: String? = nil, armedState: String? = nil) {
        self.id = id
        self.kind = kind
        self.node = node
        self.status = status
        self.sid = sid
        self.state = state
        self.armedState = armedState
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = container.lossyString(AnyCodingKey("id")) ?? ""
        kind = container.lossyString(AnyCodingKey("type")).flatMap(Kind.init)
        node = container.lossyString(AnyCodingKey("node")) ?? ""
        status = container.lossyString(AnyCodingKey("status")) ?? ""
        sid = container.lossyString(AnyCodingKey("sid"))
        state = container.lossyString(AnyCodingKey("state"))
        requestedState = container.lossyString(AnyCodingKey("request_state"))
        isQuorate = container.lossyBool(AnyCodingKey("quorate"))
        armedState = container.lossyString(AnyCodingKey("armed-state"))
        resourceMode = container.lossyString(AnyCodingKey("resource_mode"))
    }
}

/// A guest under HA, `GET /cluster/ha/resources`.
public struct HAResource: Decodable, Sendable, Equatable, Identifiable {
    /// `vm:100` or `ct:200`.
    public var sid: String
    /// `started`, `stopped`, `ignored` or `disabled` (older configurations: `enabled`).
    public var state: String
    public var maxRestart: Int
    public var maxRelocate: Int
    public var failback: Bool
    public var autoRebalance: Bool
    public var comment: String?
    public var digest: String?

    public var id: String { sid }

    /// The guest's ID, for `vm:` and `ct:` resources.
    public var vmid: Int? { HAResource.vmid(of: sid) }
    public var kind: GuestKind? { sid.hasPrefix("ct:") ? .container : sid.hasPrefix("vm:") ? .virtualMachine : nil }

    public static func sid(for guest: Int, kind: GuestKind) -> String {
        "\(kind == .container ? "ct" : "vm"):\(guest)"
    }

    public static func vmid(of sid: String) -> Int? {
        sid.split(separator: ":").last.flatMap { Int($0) }
    }

    public init(sid: String, state: String = "started", maxRestart: Int = 1, maxRelocate: Int = 1, failback: Bool = true, autoRebalance: Bool = true, comment: String? = nil) {
        self.sid = sid
        self.state = state
        self.maxRestart = maxRestart
        self.maxRelocate = maxRelocate
        self.failback = failback
        self.autoRebalance = autoRebalance
        self.comment = comment
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        sid = container.lossyString(AnyCodingKey("sid")) ?? ""
        state = container.lossyString(AnyCodingKey("state")) ?? "started"
        maxRestart = container.lossyInt(AnyCodingKey("max_restart")) ?? 1
        maxRelocate = container.lossyInt(AnyCodingKey("max_relocate")) ?? 1
        failback = container.lossyBool(AnyCodingKey("failback")) ?? true
        autoRebalance = container.lossyBool(AnyCodingKey("auto-rebalance")) ?? true
        comment = container.lossyString(AnyCodingKey("comment"))
        digest = container.lossyString(AnyCodingKey("digest"))
    }
}

/// The web interface's HA resource dialog, also its Manage HA of a guest.
public struct HAResourceDraft: Sendable, Equatable {
    public static let states = ["started", "stopped", "ignored", "disabled"]

    public var guest: Int
    public var kind: GuestKind
    public var state = "started"
    public var maxRestart = "1"
    public var maxRelocate = "1"
    /// Moves the guest back to its preferred node when that node returns.
    public var failback = true
    /// The scheduler may move the guest to balance the nodes.
    public var autoRebalance = true
    public var comment = ""

    public init(guest: Int, kind: GuestKind) {
        self.guest = guest
        self.kind = kind
    }

    public init(_ resource: HAResource) {
        guest = resource.vmid ?? 0
        kind = resource.kind ?? .virtualMachine
        // Older configurations say `enabled`, which means started.
        state = resource.state == "enabled" ? "started" : resource.state
        maxRestart = String(resource.maxRestart)
        maxRelocate = String(resource.maxRelocate)
        failback = resource.failback
        autoRebalance = resource.autoRebalance
        comment = resource.comment ?? ""
    }

    public var sid: String { HAResource.sid(for: guest, kind: kind) }

    /// Values as stored, nil for the defaults, which the web interface leaves out.
    func serialized() -> [String: String?] {
        let comment = comment.trimmingCharacters(in: .whitespaces)
        return [
            "state": state,
            "max_restart": maxRestart == "1" ? nil : maxRestart,
            "max_relocate": maxRelocate == "1" ? nil : maxRelocate,
            "failback": failback ? nil : "0",
            "auto-rebalance": autoRebalance ? nil : "0",
            "comment": comment.isEmpty ? nil : comment,
        ]
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["sid": .string(sid)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        return parameters
    }

    public func changes(from original: HAResourceDraft) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let old = original.serialized()
        for (key, value) in serialized() where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        return update
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if !(100...999_999_999).contains(guest) { problems["sid"] = String(localized: "Choose a guest.") }
        for key in ["max_restart", "max_relocate"] {
            let value = key == "max_restart" ? maxRestart : maxRelocate
            if !(Int(value).map { (0...10).contains($0) } ?? false) { problems[key] = String(localized: "Enter a number from 0 to 10.") }
        }
        return problems
    }
}

/// A rule of `GET /cluster/ha/rules` (PVE 9): which nodes resources run on, or which resources stay together.
public struct HARule: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case nodeAffinity = "node-affinity"
        case resourceAffinity = "resource-affinity"

        public var id: String { rawValue }
    }

    /// The rule's ID.
    public var id: String
    public var kind: Kind
    /// Resource IDs like `vm:100`.
    public var resources: [String]
    /// Node affinity: nodes with their priority, if set.
    public var nodes: [(name: String, priority: Int?)]
    /// Node affinity: the resources may only run on these nodes (positive) or never on them (negative).
    public var isStrict: Bool
    /// `positive` or `negative`: prefer or avoid the nodes, keep the resources together or apart.
    public var affinity: String
    public var comment: String?
    public var isEnabled: Bool
    /// Why Proxmox does not apply the rule, by setting.
    public var errors: [String: [String]]
    public var digest: String?

    public init(id: String, kind: Kind, resources: [String], nodes: [(name: String, priority: Int?)] = [], isStrict: Bool = false, affinity: String = "positive", comment: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.resources = resources
        self.nodes = nodes
        self.isStrict = isStrict
        self.affinity = affinity
        self.comment = comment
        self.isEnabled = isEnabled
        errors = [:]
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = container.lossyString(AnyCodingKey("rule")) ?? ""
        kind = container.lossyString(AnyCodingKey("type")).flatMap(Kind.init) ?? .nodeAffinity
        resources = (container.lossyString(AnyCodingKey("resources")) ?? "").split(separator: ",").map(String.init)
        nodes = HARule.parseNodes(container.lossyString(AnyCodingKey("nodes")) ?? "")
        isStrict = container.lossyBool(AnyCodingKey("strict")) ?? false
        affinity = container.lossyString(AnyCodingKey("affinity")) ?? "positive"
        comment = container.lossyString(AnyCodingKey("comment"))
        isEnabled = !(container.lossyBool(AnyCodingKey("disable")) ?? false)
        errors = (try? container.decodeIfPresent([String: [String]].self, forKey: AnyCodingKey("errors"))) ?? [:]
        digest = container.lossyString(AnyCodingKey("digest"))
    }

    /// `pve1:2,pve2` into names with priorities.
    static func parseNodes(_ text: String) -> [(name: String, priority: Int?)] {
        text.split(separator: ",").map { item in
            let parts = item.split(separator: ":", maxSplits: 1)
            return (String(parts[0]), parts.count > 1 ? Int(parts[1]) : nil)
        }
    }

    public static func == (lhs: HARule, rhs: HARule) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.resources == rhs.resources && lhs.nodes.map(\.name) == rhs.nodes.map(\.name)
            && lhs.nodes.map(\.priority) == rhs.nodes.map(\.priority) && lhs.isStrict == rhs.isStrict && lhs.affinity == rhs.affinity
            && lhs.comment == rhs.comment && lhs.isEnabled == rhs.isEnabled && lhs.errors == rhs.errors && lhs.digest == rhs.digest
    }
}

/// The web interface's node and resource affinity rule dialogs.
public struct HARuleDraft: Sendable, Equatable {
    public var kind: HARule.Kind
    public var resources: Set<String> = []
    /// Node affinity: chosen nodes with their priority; nil means no priority.
    public var nodes: [String: Int?] = [:]
    public var isStrict = false
    public var affinity = "positive"
    public var comment = ""
    public var isEnabled = true

    public init(kind: HARule.Kind) {
        self.kind = kind
    }

    public init(_ rule: HARule) {
        kind = rule.kind
        resources = Set(rule.resources)
        nodes = Dictionary(rule.nodes.map { ($0.name, $0.priority) }) { first, _ in first }
        isStrict = rule.isStrict
        affinity = rule.affinity
        comment = rule.comment ?? ""
        isEnabled = rule.isEnabled
    }

    /// Like the web interface: `ha-rule-` and the start of a random UUID.
    public static func newID() -> String {
        "ha-rule-" + String(UUID().uuidString.lowercased().prefix(13))
    }

    func serialized() -> [String: String?] {
        let comment = comment.trimmingCharacters(in: .whitespaces)
        var values: [String: String?] = [
            "resources": resources.sorted { (HAResource.vmid(of: $0) ?? 0, $0) < (HAResource.vmid(of: $1) ?? 0, $1) }.joined(separator: ","),
            "comment": comment.isEmpty ? nil : comment,
            "disable": isEnabled ? nil : "1",
            "affinity": affinity,
        ]
        if kind == .nodeAffinity {
            values["nodes"] = nodes.sorted { $0.key < $1.key }.map { name, priority in priority.map { "\(name):\($0)" } ?? name }.joined(separator: ",")
            values["strict"] = isStrict ? "1" : nil
            // Positive is the default for node affinity; resource affinity needs it spelled out.
            if affinity == "positive" { values["affinity"] = nil }
        }
        return values
    }

    func creationParameters(id: String) -> APIParameters {
        var parameters: APIParameters = ["rule": .string(id), "type": .string(kind.rawValue)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        return parameters
    }

    public func changes(from original: HARuleDraft) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let old = original.serialized()
        for (key, value) in serialized() where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        return update
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if resources.isEmpty { problems["resources"] = String(localized: "Choose at least one HA resource.") }
        switch kind {
        case .nodeAffinity:
            if nodes.isEmpty { problems["nodes"] = String(localized: "Choose at least one node.") }
        case .resourceAffinity:
            if resources.count < 2 { problems["resources"] = String(localized: "Choose at least two HA resources.") }
        }
        return problems
    }
}

/// The answer to an HA migration or relocation request. Proxmox answers without an error when rules block it.
public struct HAMoveResult: Decodable, Sendable, Equatable {
    public var blockingResources: [MigrationPreconditions.BlockingHAResource]
    /// Resources that move along because of a positive affinity rule.
    public var movedAlong: [String]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        blockingResources = (try? container.decodeIfPresent([MigrationPreconditions.BlockingHAResource].self, forKey: AnyCodingKey("blocking-resources"))) ?? []
        movedAlong = (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("comigrated-resources"))) ?? []
    }
}

extension PVE {
    public static func haStatus() -> APIRequest<[HAStatusEntry]> {
        APIRequest(.get, "/cluster/ha/status/current")
    }

    public static func haResources() -> APIRequest<[HAResource]> {
        APIRequest(.get, "/cluster/ha/resources")
    }

    public static func createHAResource(_ draft: HAResourceDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/ha/resources", parameters: draft.creationParameters)
    }

    public static func updateHAResource(_ sid: String, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/cluster/ha/resources/\(escapePath(sid))", parameters: update.parameters)
    }

    /// Takes the guest out of HA; it keeps running as it is. `purge` also removes it from rules, and rules left
    /// without resources.
    public static func deleteHAResource(_ sid: String, purge: Bool = true) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/ha/resources/\(escapePath(sid))", parameters: purge ? [:] : ["purge": false])
    }

    /// Asks HA to move the resource while it runs (`migrate`) or by stopping and starting it there (`relocate`).
    public static func moveHAResource(_ sid: String, to node: String, relocate: Bool = false) -> APIRequest<HAMoveResult> {
        APIRequest(.post, "/cluster/ha/resources/\(escapePath(sid))/\(relocate ? "relocate" : "migrate")", parameters: ["node": .string(node)])
    }

    public static func haRules() -> APIRequest<[HARule]> {
        APIRequest(.get, "/cluster/ha/rules")
    }

    public static func createHARule(_ draft: HARuleDraft, id: String) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/ha/rules", parameters: draft.creationParameters(id: id))
    }

    /// The rule's type must be sent with every change.
    public static func updateHARule(_ id: String, kind: HARule.Kind, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        var parameters = update.parameters
        parameters["type"] = .string(kind.rawValue)
        return APIRequest(.put, "/cluster/ha/rules/\(escapePath(id))", parameters: parameters)
    }

    public static func deleteHARule(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/ha/rules/\(escapePath(id))")
    }

    /// Releases the watchdogs on every node, e.g. for maintenance of the whole cluster. `freeze` keeps resources
    /// as they are; `ignore` lets them be managed as if HA were off.
    public static func disarmHA(resourceMode: String) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/ha/status/disarm-ha", parameters: ["resource-mode": .string(resourceMode)])
    }

    public static func armHA() -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/ha/status/arm-ha")
    }
}
