import Foundation
import ProxmoxCore

/// An SDN zone, VNet or subnet in demo mode: the applied values and the changes waiting for Apply.
struct DemoSDNObject: Sendable {
    var id: String
    var type: String
    /// nil for objects created since the last Apply.
    var running: [String: String]?
    var pending: [String: String]?
    var isDeleted = false
    var runningRanges: [String] = []
    var pendingRanges: [String]?

    var current: [String: String] { pending ?? running ?? [:] }
    var currentRanges: [String] { pendingRanges ?? runningRanges }
}

struct DemoSDN: Sendable {
    var zones: [DemoSDNObject]
    var vnets: [DemoSDNObject]
    /// Subnets by VNet.
    var subnets: [String: [DemoSDNObject]]

    static let sample = DemoSDN(
        zones: [DemoSDNObject(id: "lab", type: "simple", running: ["ipam": "pve", "dhcp": "dnsmasq", "mtu": "1450"])],
        vnets: [DemoSDNObject(id: "labnet", type: "vnet", running: ["zone": "lab", "alias": "Lab network"])],
        subnets: ["labnet": [DemoSDNObject(id: "lab-10.50.0.0-24", type: "subnet", running: ["cidr": "10.50.0.0/24", "gateway": "10.50.0.1", "snat": "1"],
                                           runningRanges: ["start-address=10.50.0.100,end-address=10.50.0.199"])]]
    )
}

/// `/cluster/sdn` and `/nodes/{node}/sdn` in demo mode.
extension DemoState {
    private static let zoneKeys: Set<String> = ["nodes", "mtu", "ipam", "dns", "reversedns", "dnszone", "dhcp", "bridge", "tag", "vlan-protocol", "peers", "vxlan-port"]
    private static let vnetKeys: Set<String> = ["zone", "alias", "tag", "vlanaware", "isolate-ports"]
    private static let subnetKeys: Set<String> = ["gateway", "snat", "dnszoneprefix", "dhcp-dns-server"]

    /// Routes below the SDN paths. nil for other paths.
    func handleSDN(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        if parts.count == 4, parts[0] == "nodes", parts[2] == "sdn", parts[3] == "zones", method == .get {
            let zones = sdn.zones.filter { $0.running != nil }
            return success(.array(zones.map { ["zone": .string($0.id), "status": "available"] }))
        }
        guard parts.count >= 2, parts[0] == "cluster", parts[1] == "sdn" else { return nil }
        let rest = Array(parts.dropFirst(2))
        if method != .get, !privileges(for: user).contains("SDN.Allocate") { return failure(403, "Permission check failed (/sdn, SDN.Allocate)") }
        switch (method, rest) {
        case (.put, []):
            applySDN()
            return startTask(node: cluster.nodes.first?.name ?? "pve", type: "reloadnetworkall", objectID: "", user: user, duration: 2)
        case (.post, ["rollback"]):
            rollbackSDN()
            return success(nil)
        case (.get, ["ipams"]):
            return success([["ipam": "pve", "type": "pve"]])
        case (.get, ["dns"]):
            return success([])
        case (.get, ["ipams", "pve", "status"]):
            return success(.array(ipamEntries()))
        case (.get, ["zones"]):
            return success(.array(sdn.zones.map { objectJSON($0, idKey: "zone") }))
        case (.post, ["zones"]):
            guard let id = parameters["zone"], let type = parameters["type"] else { return fieldFailure(["zone": "property is missing and it is not optional"]) }
            guard id.count <= 8 else { return fieldFailure(["zone": "value may only be 8 characters long"]) }
            guard !sdn.zones.contains(where: { $0.id == id }) else { return failure(500, "create sdn zone object failed: sdn zone object ID '\(id)' already defined") }
            sdn.zones.append(DemoSDNObject(id: id, type: type, pending: parameters.filter { Self.zoneKeys.contains($0.key) }))
            return success(nil)
        case (.put, let path) where path.count == 2 && path[0] == "zones":
            return update(&sdn.zones, id: path[1], keys: Self.zoneKeys, parameters: parameters)
        case (.delete, let path) where path.count == 2 && path[0] == "zones":
            if let vnet = sdn.vnets.first(where: { !$0.isDeleted && $0.current["zone"] == path[1] }) {
                return failure(500, "delete sdn zone object failed: zone \(path[1]) is used by vnet \(vnet.id)")
            }
            return delete(&sdn.zones, id: path[1])
        case (.get, ["vnets"]):
            return success(.array(sdn.vnets.map { objectJSON($0, idKey: "vnet") }))
        case (.post, ["vnets"]):
            guard let id = parameters["vnet"], let zone = parameters["zone"] else { return fieldFailure(["zone": "property is missing and it is not optional"]) }
            guard id.count <= 8 else { return fieldFailure(["vnet": "value may only be 8 characters long"]) }
            let zoneType = sdn.zones.first { $0.id == zone }?.type
            if zoneType == "simple", parameters["tag"] != nil { return failure(500, "create sdn vnet object failed: 400 Parameter verification failed.\ntag: vlan tag is not allowed on simple zone") }
            if ["vlan", "vxlan"].contains(zoneType), parameters["tag"] == nil { return failure(500, "create sdn vnet object failed: 400 Parameter verification failed.\ntag: missing vlan tag") }
            sdn.vnets.append(DemoSDNObject(id: id, type: "vnet", pending: parameters.filter { Self.vnetKeys.contains($0.key) }))
            return success(nil)
        case (.put, let path) where path.count == 2 && path[0] == "vnets":
            return update(&sdn.vnets, id: path[1], keys: Self.vnetKeys, parameters: parameters)
        case (.delete, let path) where path.count == 2 && path[0] == "vnets":
            if sdn.subnets[path[1]]?.contains(where: { !$0.isDeleted }) == true {
                return failure(500, "delete sdn vnet object failed: 400 Parameter verification failed.\nvnet: Can't delete vnet if subnets exists")
            }
            return delete(&sdn.vnets, id: path[1])
        case (.get, let path) where path.count == 3 && path[0] == "vnets" && path[2] == "subnets":
            return success(.array((sdn.subnets[path[1]] ?? []).map { subnetJSON($0, vnet: path[1]) }))
        case (.post, let path) where path.count == 3 && path[0] == "vnets" && path[2] == "subnets":
            guard let vnet = sdn.vnets.first(where: { $0.id == path[1] }), let cidr = parameters["subnet"], cidr.contains("/") else {
                return fieldFailure(["subnet": "invalid format - value does not look like a valid CIDR network"])
            }
            let zone = vnet.current["zone"] ?? ""
            var values = parameters.filter { Self.subnetKeys.contains($0.key) }
            values["cidr"] = cidr
            let id = "\(zone)-\(cidr.replacingOccurrences(of: "/", with: "-"))"
            let ranges = (parameters["dhcp-range"] ?? "").split(separator: Character(Self.listSeparator)).map(String.init).filter { !$0.isEmpty }
            sdn.subnets[path[1], default: []].append(DemoSDNObject(id: id, type: "subnet", pending: values, pendingRanges: ranges))
            return success(nil)
        case (.put, let path) where path.count == 4 && path[0] == "vnets" && path[2] == "subnets":
            var subnets = sdn.subnets[path[1]] ?? []
            let response = update(&subnets, id: path[3], keys: Self.subnetKeys, parameters: parameters)
            sdn.subnets[path[1]] = subnets
            return response
        case (.delete, let path) where path.count == 4 && path[0] == "vnets" && path[2] == "subnets":
            var subnets = sdn.subnets[path[1]] ?? []
            let response = delete(&subnets, id: path[3])
            sdn.subnets[path[1]] = subnets
            return response
        default:
            return nil
        }
    }

    private func update(_ objects: inout [DemoSDNObject], id: String, keys: Set<String>, parameters: [String: String]) -> HTTPResponse {
        guard let index = objects.firstIndex(where: { $0.id == id }) else { return failure(500, "sdn object '\(id)' does not exist") }
        var values = objects[index].current
        let deletions = (parameters["delete"] ?? "").split(separator: ",").map(String.init)
        for key in deletions { values[key] = nil }
        for (key, value) in parameters where keys.contains(key) { values[key] = value }
        objects[index].pending = values
        if deletions.contains("dhcp-range") { objects[index].pendingRanges = [] }
        if let ranges = parameters["dhcp-range"] {
            objects[index].pendingRanges = ranges.split(separator: Character(Self.listSeparator)).map(String.init)
        }
        return success(nil)
    }

    private func delete(_ objects: inout [DemoSDNObject], id: String) -> HTTPResponse {
        guard let index = objects.firstIndex(where: { $0.id == id }) else { return failure(500, "sdn object '\(id)' does not exist") }
        if objects[index].running == nil {
            objects.remove(at: index)
        } else {
            objects[index].isDeleted = true
        }
        return success(nil)
    }

    private func applySDN() {
        func commit(_ objects: [DemoSDNObject]) -> [DemoSDNObject] {
            objects.filter { !$0.isDeleted }.map { object in
                var object = object
                object.running = object.current
                object.runningRanges = object.currentRanges
                object.pending = nil
                object.pendingRanges = nil
                return object
            }
        }
        sdn.zones = commit(sdn.zones)
        sdn.vnets = commit(sdn.vnets)
        sdn.subnets = sdn.subnets.mapValues(commit)
    }

    private func rollbackSDN() {
        func revert(_ objects: [DemoSDNObject]) -> [DemoSDNObject] {
            objects.filter { $0.running != nil }.map { object in
                var object = object
                object.pending = nil
                object.pendingRanges = nil
                object.isDeleted = false
                return object
            }
        }
        sdn.zones = revert(sdn.zones)
        sdn.vnets = revert(sdn.vnets)
        sdn.subnets = sdn.subnets.mapValues(revert)
    }

    /// As `GET` with `pending=1` lists objects: applied values at the top, changed ones under `pending`.
    private func objectJSON(_ object: DemoSDNObject, idKey: String) -> JSONValue {
        var json: [String: JSONValue] = [idKey: .string(object.id), "type": .string(object.type)]
        for (key, value) in object.running ?? [:] { json[key] = Self.value(key, value) }
        if object.isDeleted {
            json["state"] = "deleted"
        } else if object.running == nil {
            json["state"] = "new"
            json["pending"] = .object(object.current.mapValues { .string($0) })
        } else if let pending = object.pending, pending != object.running || object.pendingRanges != nil {
            json["state"] = "changed"
            var changes: [String: JSONValue] = [:]
            for (key, value) in pending where object.running?[key] != value { changes[key] = Self.value(key, value) }
            for key in (object.running ?? [:]).keys where pending[key] == nil { changes[key] = "deleted" }
            if let ranges = object.pendingRanges, ranges != object.runningRanges {
                changes["dhcp-range"] = ranges.isEmpty ? "deleted" : .array(ranges.map { .string($0) })
            }
            json["pending"] = .object(changes)
        }
        return .object(json)
    }

    private func subnetJSON(_ subnet: DemoSDNObject, vnet: String) -> JSONValue {
        guard case .object(var json) = objectJSON(subnet, idKey: "subnet") else { return .null }
        let cidr = subnet.current["cidr"] ?? subnet.running?["cidr"] ?? ""
        json["cidr"] = .string(cidr)
        json["vnet"] = .string(vnet)
        json["id"] = .string(subnet.id)
        json["dhcp-range"] = .array(subnet.runningRanges.map { text in
            let property = PropertyString(parsing: text)
            return ["start-address": .string(property["start-address"] ?? ""), "end-address": .string(property["end-address"] ?? "")]
        })
        if subnet.running == nil, var pending = json["pending"], case .object(var values) = pending {
            values["dhcp-range"] = .array(subnet.currentRanges.map { .string($0) })
            pending = .object(values)
            json["pending"] = pending
        }
        return .object(json)
    }

    private static func value(_ key: String, _ value: String) -> JSONValue {
        ["mtu", "tag", "snat", "vlanaware", "isolate-ports", "vxlan-port"].contains(key) ? (Int(value).map(JSONValue.int) ?? .string(value)) : .string(value)
    }

    /// Gateways of applied subnets, and the first address of each DHCP range for a running guest.
    private func ipamEntries() -> [JSONValue] {
        var entries: [JSONValue] = []
        for (vnet, subnets) in sdn.subnets {
            let zone = sdn.vnets.first { $0.id == vnet }?.running?["zone"] ?? ""
            for subnet in subnets where subnet.running != nil {
                let cidr = subnet.running?["cidr"] ?? ""
                if let gateway = subnet.running?["gateway"] {
                    entries.append(["zone": .string(zone), "vnet": .string(vnet), "subnet": .string(cidr), "ip": .string(gateway), "gateway": 1])
                }
                if let range = subnet.runningRanges.first, let start = PropertyString(parsing: range)["start-address"],
                   let guest = cluster.guests.first(where: { $0.isRunning && $0.kind == .qemu }) {
                    entries.append([
                        "zone": .string(zone), "vnet": .string(vnet), "subnet": .string(cidr), "ip": .string(start),
                        "mac": "BC:24:11:5E:00:01", "hostname": .string(guest.name), "vmid": .int(guest.vmid),
                    ])
                }
            }
        }
        return entries
    }
}
