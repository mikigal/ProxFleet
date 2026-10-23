import Foundation
import ProxmoxCore

/// A guest under HA in demo mode, with its settings as the API names them.
struct DemoHAResource: Sendable {
    var sid: String
    var values: [String: String]

    var vmid: Int? { sid.split(separator: ":").last.flatMap { Int($0) } }
}

/// An HA rule in demo mode, with its settings as the API names them, `type` included.
struct DemoHARule: Sendable {
    var id: String
    var values: [String: String]
}

/// `/cluster/ha` in demo mode: the status follows the demo's nodes and guests; HA does not start or stop guests.
extension DemoState {
    static func sampleHAResources(for cluster: DemoCluster) -> [DemoHAResource] {
        guard cluster.clusterName != nil else { return [] }
        return [
            DemoHAResource(sid: "vm:101", values: ["state": "started", "max_restart": "2", "comment": "Storage for the lab"]),
            DemoHAResource(sid: "vm:104", values: ["state": "started"]),
            DemoHAResource(sid: "ct:200", values: ["state": "started", "max_relocate": "2"]),
        ]
    }

    static func sampleHARules(for cluster: DemoCluster) -> [DemoHARule] {
        guard cluster.clusterName != nil else { return [] }
        return [
            DemoHARule(id: "ha-rule-nas-on-big", values: ["type": "node-affinity", "resources": "vm:101", "nodes": "pve1:2,pve2:1", "comment": "TrueNAS prefers the big node"]),
            DemoHARule(id: "ha-rule-dns-docker", values: ["type": "resource-affinity", "resources": "ct:200,vm:104", "affinity": "positive"]),
        ]
    }

    private static let resourceKeys: Set<String> = ["state", "max_restart", "max_relocate", "failback", "auto-rebalance", "comment"]
    private static let ruleKeys: Set<String> = ["resources", "nodes", "strict", "affinity", "comment", "disable"]

    /// Routes below `/cluster/ha`. nil for other paths.
    func handleHA(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard parts.count >= 3, parts[0] == "cluster", parts[1] == "ha" else { return nil }
        let canModify = privileges(for: user).contains("Sys.Modify")
        if method != .get, !canModify { return failure(403, "Permission check failed (/, Sys.Console)") }
        switch (method, Array(parts.dropFirst(2))) {
        case (.get, ["status", "current"]):
            return success(.array(haStatus()))
        case (.post, ["status", "disarm-ha"]):
            guard let mode = parameters["resource-mode"], ["freeze", "ignore"].contains(mode) else {
                return fieldFailure(["resource-mode": "value '\(parameters["resource-mode"] ?? "")' does not have a value in the enumeration 'freeze, ignore'"])
            }
            haDisarmed = mode
            return success(nil)
        case (.post, ["status", "arm-ha"]):
            haDisarmed = nil
            return success(nil)
        case (.get, ["groups"]):
            return failure(500, "cannot index groups: ha groups have been migrated to rules")
        case (.get, ["resources"]):
            return success(.array(haResources.map(resourceJSON)))
        case (.post, ["resources"]):
            return addHAResource(parameters)
        case (.get, let rest) where rest.count == 2 && rest[0] == "resources":
            guard let resource = haResources.first(where: { $0.sid == rest[1] }) else { return failure(500, "no such resource '\(rest[1])'") }
            return success(resourceJSON(resource))
        case (.put, let rest) where rest.count == 2 && rest[0] == "resources":
            guard let index = haResources.firstIndex(where: { $0.sid == rest[1] }) else { return failure(500, "no such resource '\(rest[1])'") }
            if let state = parameters["state"], !["started", "stopped", "enabled", "disabled", "ignored"].contains(state) {
                return fieldFailure(["state": "value '\(state)' does not have a value in the enumeration 'started, stopped, enabled, disabled, ignored'"])
            }
            for key in (parameters["delete"] ?? "").split(separator: ",").map(String.init) { haResources[index].values[key] = nil }
            for (key, value) in parameters where Self.resourceKeys.contains(key) { haResources[index].values[key] = value }
            return success(nil)
        case (.delete, let rest) where rest.count == 2 && rest[0] == "resources":
            guard haResources.contains(where: { $0.sid == rest[1] }) else { return failure(500, "no such resource '\(rest[1])'") }
            haResources.removeAll { $0.sid == rest[1] }
            if parameters["purge"] != "0" { purgeFromRules(rest[1]) }
            return success(nil)
        case (.post, let rest) where rest.count == 3 && rest[0] == "resources" && ["migrate", "relocate"].contains(rest[2]):
            return moveHAResource(rest[1], to: parameters["node"] ?? "", user: user)
        case (.get, ["rules"]):
            return success(.array(haRules.enumerated().map { ruleJSON($0.element, order: $0.offset + 1) }))
        case (.post, ["rules"]):
            return addHARule(parameters)
        case (.get, let rest) where rest.count == 2 && rest[0] == "rules":
            guard let index = haRules.firstIndex(where: { $0.id == rest[1] }) else { return failure(500, "HA rule '\(rest[1])' does not exist") }
            return success(ruleJSON(haRules[index], order: index + 1))
        case (.put, let rest) where rest.count == 2 && rest[0] == "rules":
            guard let index = haRules.firstIndex(where: { $0.id == rest[1] }) else { return failure(500, "HA rule '\(rest[1])' does not exist") }
            guard parameters["type"] == haRules[index].values["type"] else { return fieldFailure(["type": "property is missing and it is not optional"]) }
            for key in (parameters["delete"] ?? "").split(separator: ",").map(String.init) { haRules[index].values[key] = nil }
            for (key, value) in parameters where Self.ruleKeys.contains(key) { haRules[index].values[key] = value }
            return success(nil)
        case (.delete, let rest) where rest.count == 2 && rest[0] == "rules":
            guard haRules.contains(where: { $0.id == rest[1] }) else { return failure(500, "HA rule '\(rest[1])' does not exist") }
            haRules.removeAll { $0.id == rest[1] }
            return success(nil)
        default:
            return nil
        }
    }

    /// The guest's HA state for `/cluster/resources`, like `started`; nil when HA does not manage it.
    func haState(of vmid: Int) -> String? {
        haResources.first { $0.vmid == vmid }?.values["state"] ?? (haResources.contains { $0.vmid == vmid } ? "started" : nil)
    }

    private func addHAResource(_ parameters: [String: String]) -> HTTPResponse {
        var sid = parameters["sid"] ?? ""
        if Int(sid) != nil {
            guard let guest = cluster.guests.first(where: { String($0.vmid) == sid }) else { return failure(500, "no such VM '\(sid)'") }
            sid = "\(guest.kind == .lxc ? "ct" : "vm"):\(sid)"
        }
        let parts = sid.split(separator: ":")
        guard parts.count == 2, ["vm", "ct"].contains(parts[0]), let vmid = Int(parts[1]),
              let guest = cluster.guests.first(where: { $0.vmid == vmid && ($0.kind == .lxc) == (parts[0] == "ct") })
        else { return failure(500, "no such resource '\(sid)'") }
        guard !guest.isTemplate else { return failure(500, "unable to add HA resource for template") }
        guard !haResources.contains(where: { $0.sid == sid }) else { return failure(500, "resource ID '\(sid)' already defined") }
        haResources.append(DemoHAResource(sid: sid, values: parameters.filter { Self.resourceKeys.contains($0.key) }))
        return success(nil)
    }

    private func moveHAResource(_ sid: String, to node: String, user: String) -> HTTPResponse {
        guard let resource = haResources.first(where: { $0.sid == sid }), let vmid = resource.vmid,
              let guest = cluster.guests.first(where: { $0.vmid == vmid })
        else { return failure(500, "service '\(sid)' not configured") }
        guard let target = cluster.nodes.first(where: { $0.name == node }) else { return fieldFailure(["node": "no such cluster node '\(node)'"]) }
        guard target.isOnline else { return failure(500, "service '\(sid)' - cannot migrate to offline node '\(node)'") }
        if node == guest.node { return failure(500, "service '\(sid)' is already on node '\(node)'") }
        // Strict node affinity rules and keep-separate rules block the move; Proxmox reports them without an error.
        var blocking: [JSONValue] = []
        for rule in haRules where rule.values["disable"] != "1" && (rule.values["resources"] ?? "").split(separator: ",").contains(Substring(sid)) {
            if rule.values["type"] == "node-affinity", rule.values["strict"] == "1" {
                let nodes = (rule.values["nodes"] ?? "").split(separator: ",").map { String($0.split(separator: ":")[0]) }
                let allowed = rule.values["affinity"] == "negative" ? !nodes.contains(node) : nodes.contains(node)
                if !allowed { blocking.append(["sid": .string(sid), "cause": "node-affinity"]) }
            }
            if rule.values["type"] == "resource-affinity", rule.values["affinity"] == "negative" {
                for other in (rule.values["resources"] ?? "").split(separator: ",").map(String.init) where other != sid {
                    if let otherID = Int(other.split(separator: ":").last ?? ""), cluster.guests.first(where: { $0.vmid == otherID })?.node == node {
                        blocking.append(["sid": .string(other), "cause": "resource-affinity"])
                    }
                }
            }
        }
        if blocking.isEmpty {
            _ = startTask(node: guest.node, type: "hamigrate", objectID: String(vmid), user: user, duration: 3) { $0.node = node }
        }
        var result: [String: JSONValue] = ["sid": .string(sid), "requested-node": .string(node)]
        if !blocking.isEmpty { result["blocking-resources"] = .array(blocking) }
        return success(.object(result))
    }

    private func addHARule(_ parameters: [String: String]) -> HTTPResponse {
        guard let id = parameters["rule"], id.first?.isLetter == true else { return fieldFailure(["rule": "invalid configuration ID"]) }
        guard let type = parameters["type"], ["node-affinity", "resource-affinity"].contains(type) else {
            return fieldFailure(["type": "value does not have a value in the enumeration 'node-affinity, resource-affinity'"])
        }
        guard !haRules.contains(where: { $0.id == id }) else { return failure(500, "HA rule '\(id)' already defined") }
        guard let resources = parameters["resources"], !resources.isEmpty else { return fieldFailure(["resources": "property is missing and it is not optional"]) }
        if type == "node-affinity", parameters["nodes"]?.isEmpty ?? true { return fieldFailure(["nodes": "property is missing and it is not optional"]) }
        if type == "resource-affinity", parameters["affinity"] == nil { return fieldFailure(["affinity": "property is missing and it is not optional"]) }
        var values = parameters.filter { Self.ruleKeys.contains($0.key) }
        values["type"] = type
        haRules.append(DemoHARule(id: id, values: values))
        return success(nil)
    }

    private func purgeFromRules(_ sid: String) {
        for index in haRules.indices.reversed() {
            let remaining = (haRules[index].values["resources"] ?? "").split(separator: ",").map(String.init).filter { $0 != sid }
            if remaining.isEmpty {
                haRules.remove(at: index)
            } else {
                haRules[index].values["resources"] = remaining.joined(separator: ",")
            }
        }
    }

    private func haStatus() -> [JSONValue] {
        let now = Int(Date().timeIntervalSince1970)
        // Like Proxmox: `Fri Oct 23 13:23:47 2026`.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let stamp = formatter.string(from: Date())
        let master = cluster.nodes.first(where: \.isOnline)?.name ?? "pve"
        var entries: [JSONValue] = [
            ["id": "quorum", "type": "quorum", "node": .string(master), "quorate": 1, "status": "OK"],
        ]
        guard !haResources.isEmpty else {
            entries.append(["id": "fencing", "type": "fencing", "node": .string(master), "armed-state": "standby", "status": "standby (CRM watchdog standby)"])
            return entries
        }
        entries.append(["id": "master", "type": "master", "node": .string(master), "timestamp": .int(now), "status": .string("\(master) (active, \(stamp))")])
        if let mode = haDisarmed {
            entries.append(["id": "fencing", "type": "fencing", "node": .string(master), "armed-state": "disarmed", "resource_mode": .string(mode), "status": .string("disarmed (resource mode: \(mode))")])
        } else {
            entries.append(["id": "fencing", "type": "fencing", "node": .string(master), "armed-state": "armed", "status": "armed (CRM watchdog active)"])
        }
        for node in cluster.nodes {
            let hosts = haResources.contains { resource in cluster.guests.first { $0.vmid == resource.vmid }?.node == node.name }
            let status = node.isOnline
                ? "\(node.name) (\(hosts && haDisarmed == nil ? "active, watchdog active" : "idle, watchdog standby"), \(stamp))"
                : "\(node.name) (old timestamp - dead?, \(stamp))"
            entries.append(["id": .string("lrm:\(node.name)"), "type": "lrm", "node": .string(node.name), "timestamp": .int(now), "status": .string(status)])
        }
        for resource in haResources {
            guard let guest = cluster.guests.first(where: { $0.vmid == resource.vmid }) else { continue }
            let requested = resource.values["state"] ?? "started"
            let online = cluster.nodes.first { $0.name == guest.node }?.isOnline ?? false
            let migrating = tasks.contains { $0.type == "hamigrate" && $0.objectID == String(guest.vmid) && !$0.isApplied }
            let state = !online ? "fence" : migrating ? "migrate" : requested == "disabled" ? "stopped" : requested
            var entry: [String: JSONValue] = [
                "id": .string("service:\(resource.sid)"), "type": "service", "sid": .string(resource.sid), "node": .string(guest.node),
                "state": .string(state), "crm_state": .string(state), "request_state": .string(requested),
                "status": .string("\(resource.sid) (\(guest.node), \(state))"),
                "max_restart": .int(Int(resource.values["max_restart"] ?? "") ?? 1), "max_relocate": .int(Int(resource.values["max_relocate"] ?? "") ?? 1),
                "failback": .int(resource.values["failback"] == "0" ? 0 : 1), "auto-rebalance": .int(resource.values["auto-rebalance"] == "0" ? 0 : 1),
            ]
            if let comment = resource.values["comment"] { entry["comment"] = .string(comment) }
            entries.append(.object(entry))
        }
        return entries
    }

    private func resourceJSON(_ resource: DemoHAResource) -> JSONValue {
        var object: [String: JSONValue] = [
            "sid": .string(resource.sid), "type": .string(String(resource.sid.split(separator: ":")[0])), "digest": "d3m0",
            "state": .string(resource.values["state"] ?? "started"),
        ]
        for (key, value) in resource.values where key != "state" {
            object[key] = Int(value).map { JSONValue.int($0) } ?? .string(value)
        }
        return .object(object)
    }

    private func ruleJSON(_ rule: DemoHARule, order: Int) -> JSONValue {
        var object: [String: JSONValue] = ["rule": .string(rule.id), "order": .int(order), "digest": "d3m0"]
        for (key, value) in rule.values {
            object[key] = ["strict", "disable"].contains(key) ? .int(Int(value) ?? 0) : .string(value)
        }
        if rule.values["type"] == "node-affinity" {
            if object["strict"] == nil { object["strict"] = 0 }
            if object["affinity"] == nil { object["affinity"] = "positive" }
        }
        return .object(object)
    }
}
