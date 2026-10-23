import Foundation
import ProxmoxCore

/// The state of the applied SDN on each node in demo mode: zones, bridges, EVPN VRFs and fabric routing.
extension DemoState {
    /// `/cluster/resources` entries of type `network` for a node: its own bridges, the applied zones and fabrics.
    func sdnNetworkResources(node: String) -> [JSONValue] {
        var entries: [JSONValue] = [
            ["id": .string("network/\(node)/zone/localnetwork"), "type": "network", "network-type": "zone", "network": "localnetwork", "node": .string(node), "status": "ok"],
        ]
        for zone in sdn.zones where zone.running != nil && !zone.isDeleted {
            entries.append([
                "id": .string("network/\(node)/zone/\(zone.id)"), "type": "network", "network-type": "zone", "network": .string(zone.id), "node": .string(node),
                "zone-type": .string(zone.type), "status": "ok",
            ])
        }
        for fabric in sdn.fabrics where fabric.running != nil && !fabric.isDeleted && fabricNode(fabric.id, node) != nil {
            entries.append([
                "id": .string("network/\(node)/fabric/\(fabric.id)"), "type": "network", "network-type": "fabric", "network": .string(fabric.id), "node": .string(node),
                "protocol": .string(fabric.running?["protocol"] ?? fabric.type), "status": "ok",
            ])
        }
        return entries
    }

    private func fabricNode(_ fabric: String, _ node: String) -> DemoSDNObject? {
        sdn.fabricNodes.first { $0.id == "\(fabric)/\(node)" && $0.running != nil && !$0.isDeleted }
    }

    private func appliedVNets(of zone: String) -> [DemoSDNObject] {
        sdn.vnets.filter { $0.running?["zone"] == zone && !$0.isDeleted }.sorted { $0.id < $1.id }
    }

    /// Routes below `/nodes/{node}/sdn/zones/{zone}`, `/nodes/{node}/sdn/vnets/{vnet}` and
    /// `/nodes/{node}/sdn/fabrics/{fabric}`. nil for other paths.
    func handleSDNNodeStatus(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard method == .get, parts.count == 6, parts[0] == "nodes", parts[2] == "sdn" else { return nil }
        let node = parts[1]
        guard let info = cluster.nodes.first(where: { $0.name == node }) else { return failure(500, "no such node '\(node)'") }
        guard info.isOnline else { return failure(595, "Connection refused: node '\(node)' seems to be offline") }
        let name = parts[4]
        switch (parts[3], parts[5]) {
        case ("zones", "bridges"):
            if name == "localnetwork" {
                let ports: [JSONValue] = cluster.guests.filter { $0.node == node && $0.isRunning }.map { guest in
                    ["name": .string("\(guest.kind == .qemu ? "tap" : "veth")\(guest.vmid)i0"), "vmid": .int(guest.vmid), "index": "net0"]
                } + [["name": "eno1"]]
                return success([["name": "vmbr0", "vlan_filtering": "0", "ports": .array(ports)]])
            }
            guard sdn.zones.contains(where: { $0.id == name && $0.running != nil }) else { return failure(500, "zone '\(name)' does not exist") }
            return success(.array(appliedVNets(of: name).map { ["name": .string($0.id), "vlan_filtering": .string($0.running?["vlanaware"] == "1" ? "1" : "0"), "ports": []] }))
        case ("zones", "content"):
            guard name.count <= 8 else { return fieldFailure(["zone": "value may only be 8 characters long"]) }
            guard sdn.zones.contains(where: { $0.id == name && $0.running != nil }) else { return failure(500, "zone '\(name)' does not exist") }
            return success(.array(appliedVNets(of: name).map { ["vnet": .string($0.id), "status": "available"] }))
        case ("zones", "ip-vrf"):
            guard let zone = sdn.zones.first(where: { $0.id == name && $0.running != nil }) else { return failure(500, "zone '\(name)' does not exist") }
            guard zone.type == "evpn" else { return failure(500, "zone '\(name)' is not an EVPN zone") }
            var routes: [JSONValue] = [["ip": "0.0.0.0/0", "protocol": "bgp", "metric": 20, "nexthops": .array(cluster.nodes.filter { $0.isOnline && $0.name != node }.prefix(1).map { .string($0.ip) })]]
            for vnet in appliedVNets(of: name) {
                for subnet in sdn.subnets[vnet.id] ?? [] where subnet.running != nil {
                    routes.append(["ip": .string(subnet.running?["cidr"] ?? ""), "protocol": "connected", "metric": 0, "nexthops": [.string(vnet.id)]])
                }
            }
            return success(.array(routes))
        case ("vnets", "mac-vrf"):
            guard let vnet = sdn.vnets.first(where: { $0.id == name && $0.running != nil }) else { return failure(500, "vnet '\(name)' does not exist") }
            guard sdn.zones.first(where: { $0.id == vnet.running?["zone"] })?.type == "evpn" else { return failure(500, "vnet '\(name)' is not in an EVPN zone") }
            let subnet = sdn.subnets[name]?.first?.running?["cidr"].flatMap { $0.split(separator: "/").first.map(String.init) }
            let others = cluster.nodes.filter { $0.isOnline && $0.name != node }
            return success(.array(others.enumerated().map { index, other in
                var entry: [String: JSONValue] = [
                    "mac": .string(String(format: "BC:24:11:5E:%02X:%02X", index + 1, 0x10 + index)), "nexthop": .string(other.ip),
                ]
                if let subnet, let last = subnet.split(separator: ".").last.flatMap({ Int($0) }) {
                    entry["ip"] = .string(subnet.split(separator: ".").dropLast().joined(separator: ".") + ".\(last + 10 + index)")
                }
                return .object(entry)
            }))
        case ("fabrics", let part):
            guard sdn.fabrics.contains(where: { $0.id == name && $0.running != nil }), let own = fabricNode(name, node) else {
                return failure(500, "fabric '\(name)' does not exist on node '\(node)'")
            }
            let peers = sdn.fabricNodes.filter { $0.id.hasPrefix("\(name)/") && $0.running != nil && $0.id != own.id }
                .compactMap { object -> (node: String, ip: String)? in
                    let peer = String(object.id.dropFirst(name.count + 1))
                    guard cluster.nodes.first(where: { $0.name == peer })?.isOnline == true, let ip = object.running?["ip"] else { return nil }
                    return (peer, ip)
                }
            let interfaces = (own.running?["interfaces"] ?? "").components(separatedBy: Self.listSeparator).compactMap { PropertyString(parsing: $0)["name"] }
            switch part {
            case "routes":
                return success(.array(peers.map { ["route": .string("\($0.ip)/32"), "via": .array(interfaces.prefix(1).map { .string($0) })] }))
            case "neighbors":
                return success(.array(peers.map { ["neighbor": .string($0.node), "status": "Up", "uptime": "3d02h11m"] }))
            case "interfaces":
                return success(.array(interfaces.map { ["name": .string($0), "state": "Up", "type": "Point-to-Point"] }))
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
