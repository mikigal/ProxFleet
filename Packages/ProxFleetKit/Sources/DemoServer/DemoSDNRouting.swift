import Foundation
import ProxmoxCore

/// SDN controllers, fabrics, prefix lists, route maps and IP mappings in demo mode.
extension DemoState {
    private static let controllerKeys: Set<String> = [
        "asn", "peers", "fabric", "route-map-in", "route-map-out", "peer-group-name", "nodes", "bgp-mode", "ebgp-multihop", "node", "loopback",
        "ebgp", "bgp-multipath-as-path-relax", "isis-domain", "isis-net", "isis-ifaces",
    ]
    private static let fabricKeys: Set<String> = [
        "protocol", "ip_prefix", "ip6_prefix", "hello_interval", "csnp_interval", "area", "route_filter", "redistribute", "bfd", "route_map_in", "route_map_out",
    ]
    private static let fabricNodeKeys: Set<String> = ["protocol", "ip", "ip6", "asn", "interfaces", "role"]
    private static let routeMapKeys: Set<String> = ["action", "match", "set", "call", "exit-action"]

    /// Routes below `/cluster/sdn` the zone handler does not answer. nil for other paths.
    func handleSDNRouting(_ method: HTTPMethod, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        switch (method, rest) {
        case (.get, ["controllers"]):
            return success(.array(sdn.controllers.map { objectJSON($0, idKey: "controller") }))
        case (.post, ["controllers"]):
            guard let id = parameters["controller"], let type = parameters["type"] else { return fieldFailure(["controller": "property is missing and it is not optional"]) }
            guard !sdn.controllers.contains(where: { $0.id == id }) else { return failure(500, "create sdn controller object failed: sdn controller object ID '\(id)' already defined") }
            if type == "evpn", let other = sdn.controllers.first(where: { $0.type == "evpn" && !$0.isDeleted }) {
                return failure(500, "create sdn controller object failed: only 1 evpn controller can be defined (\(other.id) already exists)")
            }
            sdn.controllers.append(DemoSDNObject(id: id, type: type, pending: parameters.filter { Self.controllerKeys.contains($0.key) }))
            return success(nil)
        case (.put, let path) where path.count == 2 && path[0] == "controllers":
            return update(&sdn.controllers, id: path[1], keys: Self.controllerKeys, parameters: parameters)
        case (.delete, let path) where path.count == 2 && path[0] == "controllers":
            if let zone = sdn.zones.first(where: { !$0.isDeleted && $0.current["controller"] == path[1] }) {
                return failure(500, "delete sdn controller object failed: controller \(path[1]) is used by zone \(zone.id)")
            }
            return delete(&sdn.controllers, id: path[1])

        case (.get, ["fabrics", "all"]):
            return success([
                "fabrics": .array(sdn.fabrics.map { objectJSON($0, idKey: "id") }),
                "nodes": .array(sdn.fabricNodes.map(fabricNodeJSON)),
            ])
        case (.post, ["fabrics", "fabric"]):
            guard let id = parameters["id"], parameters["protocol"] != nil else { return fieldFailure(["id": "property is missing and it is not optional"]) }
            guard !sdn.fabrics.contains(where: { $0.id == id }) else { return failure(500, "fabric '\(id)' already exists") }
            sdn.fabrics.append(DemoSDNObject(id: id, type: "fabric", pending: parameters.filter { Self.fabricKeys.contains($0.key) }))
            return success(.string(""))
        case (.put, let path) where path.count == 3 && path[0] == "fabrics" && path[1] == "fabric":
            return update(&sdn.fabrics, id: path[2], keys: Self.fabricKeys, parameters: parameters)
        case (.delete, let path) where path.count == 3 && path[0] == "fabrics" && path[1] == "fabric":
            if sdn.fabricNodes.contains(where: { !$0.isDeleted && $0.id.hasPrefix(path[2] + "/") }) {
                return failure(500, "fabric '\(path[2])' still has nodes")
            }
            return delete(&sdn.fabrics, id: path[2])
        case (.post, let path) where path.count == 3 && path[0] == "fabrics" && path[1] == "node":
            guard let node = parameters["node_id"] else { return fieldFailure(["node_id": "property is missing and it is not optional"]) }
            guard sdn.fabrics.contains(where: { $0.id == path[2] && !$0.isDeleted }) else { return failure(500, "fabric '\(path[2])' does not exist") }
            let id = "\(path[2])/\(node)"
            guard !sdn.fabricNodes.contains(where: { $0.id == id }) else { return failure(500, "adding node failed: node '\(node)' is already part of the fabric") }
            let interfaces = (parameters["interfaces"] ?? "").components(separatedBy: Self.listSeparator).compactMap { PropertyString(parsing: $0)["name"] }
            for other in sdn.fabricNodes where !other.isDeleted && other.id.hasSuffix("/\(node)") {
                let used = (other.current["interfaces"] ?? "").components(separatedBy: Self.listSeparator).compactMap { PropertyString(parsing: $0)["name"] }
                if !Set(used).isDisjoint(with: interfaces) { return failure(500, "adding node failed: interface is already in use by another fabric") }
            }
            sdn.fabricNodes.append(DemoSDNObject(id: id, type: "node", pending: parameters.filter { Self.fabricNodeKeys.contains($0.key) }))
            return success(.string(""))
        case (.put, let path) where path.count == 4 && path[0] == "fabrics" && path[1] == "node":
            return update(&sdn.fabricNodes, id: "\(path[2])/\(path[3])", keys: Self.fabricNodeKeys, parameters: parameters)
        case (.delete, let path) where path.count == 4 && path[0] == "fabrics" && path[1] == "node":
            return delete(&sdn.fabricNodes, id: "\(path[2])/\(path[3])")

        case (.get, ["prefix-lists"]):
            return success(.array(sdn.prefixLists.map { list in
                var json: [String: JSONValue] = ["id": .string(list.id)]
                if list.isDeleted { json["state"] = "deleted" } else if list.running == nil { json["state"] = "new" } else if list.pending != nil, list.pending != list.running { json["state"] = "changed" }
                return .object(json)
            }))
        case (.post, ["prefix-lists"]):
            guard let id = parameters["id"], !id.isEmpty else { return fieldFailure(["id": "property is missing and it is not optional"]) }
            guard !sdn.prefixLists.contains(where: { $0.id == id }) else { return failure(500, "prefix list '\(id)' already exists") }
            sdn.prefixLists.append(DemoSDNObject(id: id, type: "prefix-list", pending: ["entries": parameters["entries"] ?? ""]))
            return success(nil)
        case (.delete, let path) where path.count == 2 && path[0] == "prefix-lists":
            return delete(&sdn.prefixLists, id: path[1])
        case (.get, let path) where path.count == 3 && path[0] == "prefix-lists" && path[2] == "entries":
            guard let list = sdn.prefixLists.first(where: { $0.id == path[1] }) else { return failure(500, "prefix list '\(path[1])' does not exist") }
            return success(.array(prefixEntries(list).map { entry in
                .object(entry.reduce(into: [:]) { $0[$1.key] = ["seq", "le", "ge"].contains($1.key) ? (Int($1.value).map(JSONValue.int) ?? .string($1.value)) : .string($1.value) })
            }))
        case (.post, let path) where path.count == 3 && path[0] == "prefix-lists" && path[2] == "entries":
            guard let index = sdn.prefixLists.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "prefix list '\(path[1])' does not exist") }
            var entries = prefixEntries(sdn.prefixLists[index])
            let sequence = parameters["seq"] ?? String(((entries.compactMap { Int($0["seq"] ?? "") }.max() ?? 0) / 5 + 1) * 5)
            guard !entries.contains(where: { $0["seq"] == sequence }) else { return fieldFailure(["seq": "an entry with sequence number \(sequence) already exists"]) }
            var entry = parameters.filter { ["action", "prefix", "le", "ge"].contains($0.key) }
            entry["seq"] = sequence
            entries.append(entry)
            setPrefixEntries(entries, at: index)
            return success(nil)
        case (.put, let path) where path.count == 4 && path[0] == "prefix-lists" && path[2] == "entries":
            guard let index = sdn.prefixLists.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "prefix list '\(path[1])' does not exist") }
            var entries = prefixEntries(sdn.prefixLists[index])
            guard let position = entries.firstIndex(where: { $0["seq"] == path[3] }) else { return failure(500, "entry \(path[3]) does not exist") }
            for key in (parameters["delete"] ?? "").components(separatedBy: Self.listSeparator) { entries[position][key] = nil }
            for (key, value) in parameters where ["action", "prefix", "le", "ge", "seq"].contains(key) { entries[position][key] = value }
            setPrefixEntries(entries, at: index)
            return success(nil)
        case (.delete, let path) where path.count == 4 && path[0] == "prefix-lists" && path[2] == "entries":
            guard let index = sdn.prefixLists.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "prefix list '\(path[1])' does not exist") }
            setPrefixEntries(prefixEntries(sdn.prefixLists[index]).filter { $0["seq"] != path[3] }, at: index)
            return success(nil)

        case (.get, ["route-maps"]):
            return success(.array(Set(sdn.routeMapEntries.map { $0.id.components(separatedBy: "/")[0] }).sorted().map { ["id": .string($0)] }))
        case (.get, ["route-maps", "entries"]):
            return success(.array(sdn.routeMapEntries.map { objectJSON($0, idKey: nil) }))
        case (.post, ["route-maps", "entries"]):
            guard let map = parameters["route-map-id"], let order = parameters["order"], parameters["action"] != nil else {
                return fieldFailure(["action": "property is missing and it is not optional"])
            }
            let id = "\(map)/\(order)"
            guard !sdn.routeMapEntries.contains(where: { $0.id == id }) else { return fieldFailure(["order": "route map entry \(id) already exists"]) }
            var values = parameters.filter { Self.routeMapKeys.contains($0.key) }
            values["route-map-id"] = map
            values["order"] = order
            sdn.routeMapEntries.append(DemoSDNObject(id: id, type: "route-map-entry", pending: values))
            return success(nil)
        case (.put, let path) where path.count == 5 && path[0] == "route-maps" && path[3] == "entry":
            return update(&sdn.routeMapEntries, id: "\(path[2])/\(path[4])", keys: Self.routeMapKeys, parameters: parameters)
        case (.delete, let path) where path.count == 5 && path[0] == "route-maps" && path[3] == "entry":
            return delete(&sdn.routeMapEntries, id: "\(path[2])/\(path[4])")

        case (.post, let path) where path.count == 3 && path[0] == "vnets" && path[2] == "ips":
            guard let ip = parameters["ip"], let mac = parameters["mac"] else { return fieldFailure(["mac": "property is missing and it is not optional"]) }
            sdn.ipMappings.append(["zone": parameters["zone"] ?? "", "vnet": path[1], "ip": ip, "mac": mac])
            return success(nil)
        case (.put, let path) where path.count == 3 && path[0] == "vnets" && path[2] == "ips":
            guard let ip = parameters["ip"] else { return fieldFailure(["ip": "property is missing and it is not optional"]) }
            if let index = sdn.ipMappings.firstIndex(where: { $0["vnet"] == path[1] && $0["mac"] == parameters["mac"] }) {
                sdn.ipMappings[index]["ip"] = ip
            } else {
                sdn.ipMappings.append(["zone": parameters["zone"] ?? "", "vnet": path[1], "ip": ip, "mac": parameters["mac"] ?? "", "vmid": parameters["vmid"] ?? ""])
            }
            return success(nil)
        case (.delete, let path) where path.count == 3 && path[0] == "vnets" && path[2] == "ips":
            sdn.ipMappings.removeAll { $0["vnet"] == path[1] && $0["ip"] == parameters["ip"] }
            return success(nil)
        default:
            return nil
        }
    }

    private func fabricNodeJSON(_ node: DemoSDNObject) -> JSONValue {
        guard case .object(var json) = objectJSON(node, idKey: nil) else { return .null }
        let parts = node.id.components(separatedBy: "/")
        json["fabric_id"] = .string(parts[0])
        json["node_id"] = .string(parts[1])
        json["type"] = nil
        return .object(json)
    }

    /// The entries as they will be after Apply, as property strings parsed into dictionaries.
    private func prefixEntries(_ list: DemoSDNObject) -> [[String: String]] {
        (list.current["entries"] ?? "").components(separatedBy: Self.listSeparator).filter { !$0.isEmpty }.map { text in
            PropertyString(parsing: text).items.reduce(into: [:]) { if let key = $1.key { $0[key] = $1.value } }
        }
    }

    private func setPrefixEntries(_ entries: [[String: String]], at index: Int) {
        let sorted = entries.sorted { Int($0["seq"] ?? "") ?? 0 < Int($1["seq"] ?? "") ?? 0 }
        let text = sorted.map { entry in
            ["action", "prefix", "le", "ge", "seq"].compactMap { key in entry[key].map { "\(key)=\($0)" } }.joined(separator: ",")
        }.joined(separator: Self.listSeparator)
        var values = sdn.prefixLists[index].current
        values["entries"] = text
        sdn.prefixLists[index].pending = values
    }
}
