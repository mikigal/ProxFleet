import Foundation
import ProxmoxCore

/// A resource pool in demo mode.
struct DemoPool: Sendable {
    var id: String
    var comment: String?
    var guests: Set<Int> = []
    var storages: Set<String> = []

    static let sample = [DemoPool(id: "lab", comment: "Experiments", guests: [103, 105])]
}

/// `/pools` in demo mode.
extension DemoState {
    /// The guests of a pool that exist.
    func poolGuests(_ id: String) -> Set<Int> {
        let existing = Set(cluster.guests.map(\.vmid))
        return (pools.first { $0.id == id }?.guests ?? []).intersection(existing)
    }

    func pool(of vmid: Int) -> String? {
        pools.first { $0.guests.contains(vmid) }?.id
    }

    /// Routes below `/pools`. nil for other paths.
    func handlePools(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard parts == ["pools"] else { return nil }
        if method != .get, !privileges(for: user).contains("Pool.Allocate") {
            return failure(403, "Permission check failed (/pool/\(parameters["poolid"] ?? ""), Pool.Allocate)")
        }
        switch method {
        case .get:
            if let id = parameters["poolid"] {
                guard let pool = pools.first(where: { $0.id == id }) else { return failure(500, "pool '\(id)' does not exist") }
                return success([poolJSON(pool, withMembers: true)])
            }
            return success(.array(pools.sorted { $0.id < $1.id }.map { poolJSON($0, withMembers: false) }))
        case .post:
            return createPool(parameters)
        case .put:
            return updatePool(parameters)
        case .delete:
            guard let id = parameters["poolid"], let index = pools.firstIndex(where: { $0.id == id }) else {
                return failure(500, "pool '\(parameters["poolid"] ?? "")' does not exist")
            }
            if let vmid = poolGuests(id).sorted().first { return failure(500, "delete pool failed: pool '\(id)' is not empty (contains VM \(vmid))") }
            if let storage = pools[index].storages.sorted().first {
                return failure(500, "delete pool failed: pool '\(id)' is not empty (contains storage '\(storage)')")
            }
            if pools.contains(where: { $0.id.hasPrefix(id + "/") }) { return failure(500, "delete pool failed: pool '\(id)' is not empty (contains sub-pool)") }
            pools.remove(at: index)
            return success(nil)
        }
    }

    private func createPool(_ parameters: [String: String]) -> HTTPResponse {
        let id = parameters["poolid"] ?? ""
        let levels = id.split(separator: "/", omittingEmptySubsequences: false)
        guard levels.count <= 3 else { return fieldFailure(["poolid": "invalid format - pool name '\(id)' nested too deeply (max levels = 3)"]) }
        guard id.first?.isLetter == true else { return failure(500, "create pool failed: pool name must start with a letter") }
        guard !pools.contains(where: { $0.id == id }) else { return failure(500, "create pool failed: pool '\(id)' already exists") }
        if levels.count > 1 {
            let parent = levels.dropLast().joined(separator: "/")
            guard pools.contains(where: { $0.id == parent }) else { return failure(500, "create pool failed: parent '\(parent)' of pool '\(id)' does not exist") }
        }
        pools.append(DemoPool(id: id, comment: parameters["comment"].flatMap { $0.isEmpty ? nil : $0 }))
        return success(nil)
    }

    private func updatePool(_ parameters: [String: String]) -> HTTPResponse {
        let id = parameters["poolid"] ?? ""
        guard let index = pools.firstIndex(where: { $0.id == id }) else { return failure(500, "pool '\(id)' does not exist") }
        let vmids = (parameters["vms"] ?? "").split(separator: ",").compactMap { Int($0) }
        let storages = (parameters["storage"] ?? "").split(separator: ",").map(String.init)
        if let comment = parameters["comment"] { pools[index].comment = comment.isEmpty ? nil : comment }
        if parameters["delete"] == "1" {
            pools[index].guests.subtract(vmids)
            pools[index].storages.subtract(storages)
            return success(nil)
        }
        for vmid in vmids {
            guard cluster.guests.contains(where: { $0.vmid == vmid }) else { return failure(500, "VM \(vmid) does not exist") }
            if let current = pool(of: vmid), current != id {
                guard parameters["allow-move"] == "1" else { return failure(500, "VM \(vmid) belongs already to pool '\(current)' and allow-move is not set") }
                if let other = pools.firstIndex(where: { $0.id == current }) { pools[other].guests.remove(vmid) }
            }
        }
        for storage in storages where !storageConfigs.contains(where: { $0.id == storage }) {
            return failure(500, "storage '\(storage)' does not exist")
        }
        pools[index].guests.formUnion(vmids)
        pools[index].storages.formUnion(storages)
        return success(nil)
    }

    private func poolJSON(_ pool: DemoPool, withMembers: Bool) -> JSONValue {
        var object: [String: JSONValue] = ["poolid": .string(pool.id)]
        if let comment = pool.comment { object["comment"] = .string(comment) }
        guard withMembers else { return .object(object) }
        var members: [JSONValue] = cluster.guests.filter { poolGuests(pool.id).contains($0.vmid) }.map { guest in
            [
                "id": .string("\(guest.kind.rawValue)/\(guest.vmid)"), "type": .string(guest.kind.rawValue), "vmid": .int(guest.vmid),
                "name": .string(guest.name), "node": .string(guest.node), "status": guest.isRunning ? "running" : "stopped",
                "template": .int(guest.isTemplate ? 1 : 0),
            ]
        }
        for node in cluster.nodes {
            for config in storageConfigs where pool.storages.contains(config.id) && config.isAvailable(on: node.name) {
                members.append([
                    "id": .string("storage/\(node.name)/\(config.id)"), "type": "storage", "storage": .string(config.id),
                    "node": .string(node.name), "status": "available", "plugintype": .string(config.type),
                ])
            }
        }
        object["members"] = .array(members)
        return .object(object)
    }
}
