import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct SDNStatusTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// `/cluster/resources` of the test cluster on PVE 9.2: networks next to other resources.
    @Test func nodeNetworksFromClusterResources() throws {
        let json = #"[{"type": "network", "network-type": "zone", "status": "ok", "node": "test2", "network": "localnetwork", "id": "network/test2/zone/localnetwork"}, {"type": "node", "node": "test2", "id": "node/test2", "status": "online"}, {"type": "network", "network-type": "fabric", "network": "under", "node": "pve-claude", "protocol": "openfabric", "status": "ok", "id": "network/pve-claude/fabric/under"}, {"type": "network", "network-type": "zone", "network": "evz", "zone-type": "evpn", "node": "pve-claude", "status": "available", "id": "network/pve-claude/zone/evz"}]"#
        let networks = try decode([SDNNodeNetwork].self, json).filter { $0.kind != nil }
        #expect(networks.map(\.name) == ["localnetwork", "under", "evz"])
        #expect(networks[0].isLocalNetwork && networks[1].kind == .fabric && networks[1].fabricProtocol == "openfabric")
        #expect(networks[2].zoneType == "evpn" && networks[2].id == "pve-claude/zone/evz")
    }

    /// `GET /nodes/pve-claude/sdn/zones/localnetwork/bridges` of the test cluster.
    @Test func bridgesAsRecorded() throws {
        let json = #"[{"name": "vmbr0", "vlan_filtering": 0, "ports": [{"vmid": "102", "index": "net0", "name": "tap102i0"}, {"index": "net0", "vmid": "100", "name": "tap100i0"}, {"vmid": "201", "index": "net0", "name": "veth201i0"}, {"name": "nic0"}, {"index": "net0", "vmid": "200", "name": "veth200i0", "primary_vlan": 10, "vlans": ["20", "30-40"]}]}]"#
        let bridge = try #require(try decode([SDNBridge].self, json).first)
        #expect(bridge.name == "vmbr0" && !bridge.isVLANAware)
        // Guests first by ID, then physical ports.
        #expect(bridge.ports.map(\.name) == ["tap100i0", "tap102i0", "veth200i0", "veth201i0", "nic0"])
        #expect(bridge.ports[0].vmid == 100 && bridge.ports[0].device == "net0" && bridge.ports[4].vmid == nil)
        #expect(bridge.ports[2].primaryVLAN == 10 && bridge.ports[2].vlans == ["20", "30-40"])
    }

    @Test func zoneContentVRFsAndFabrics() throws {
        let content = try decode([SDNZoneContentEntry].self, #"[{"vnet": "evnet", "status": "available"}, {"vnet": "broken", "status": "error", "statusmsg": "missing bridge"}]"#)
        #expect(content[1].statusMessage == "missing bridge")
        let ipVRF = try decode([SDNIPVRFRoute].self, #"[{"ip": "10.0.0.0/24", "metric": 0, "nexthops": ["evnet"], "protocol": "connected"}]"#)
        #expect(ipVRF[0].prefix == "10.0.0.0/24" && ipVRF[0].nexthops == ["evnet"] && ipVRF[0].protocolName == "connected")
        let macVRF = try decode([SDNMACVRFEntry].self, #"[{"ip": "10.0.0.20", "mac": "bc:24:11:00:00:01", "nexthop": "10.10.100.151"}]"#)
        #expect(macVRF[0].mac == "bc:24:11:00:00:01" && macVRF[0].nexthop == "10.10.100.151")
        let routes = try decode([SDNFabricRoute].self, #"[{"route": "10.250.0.2/32", "via": ["10.250.0.2"]}]"#)
        #expect(routes[0].via == ["10.250.0.2"])
        let neighbors = try decode([SDNFabricNeighbor].self, #"[{"neighbor": "test2", "status": "Up", "uptime": "8h24m12s"}]"#)
        #expect(neighbors[0].uptime == "8h24m12s")
        let interfaces = try decode([SDNFabricInterfaceStatus].self, #"[{"name": "vmbr94", "state": "Up", "type": "Broadcast"}]"#)
        #expect(interfaces[0].type == "Broadcast")
        #expect(PVE.sdnZoneBridges(node: "pve", zone: "localnetwork").path == "/nodes/pve/sdn/zones/localnetwork/bridges")
        #expect(PVE.sdnMACVRF(node: "pve", vnet: "evnet").path == "/nodes/pve/sdn/vnets/evnet/mac-vrf")
        #expect(PVE.sdnFabricNeighbors(node: "pve", fabric: "under").path == "/nodes/pve/sdn/fabrics/under/neighbors")
    }

    @Test func draidPools() {
        var draft = DiskStorageDraft(kind: .zfs)
        draft.name = "wide"
        draft.raidLevel = "draid2"
        draft.devices = ["/dev/sdb", "/dev/sdc", "/dev/sdd", "/dev/sde"]
        #expect(draft.isDRAID && Set(draft.problems.keys) == ["draid-data", "draid-spares"])
        draft.draidData = "2"
        draft.draidSpares = "1"
        // Two parity, two data and one spare need five disks.
        #expect(draft.problems["devices"] == "This dRAID layout needs at least 5 disks.")
        draft.devices.append("/dev/sdf")
        #expect(draft.problems.isEmpty)
        #expect(PVE.createDiskStorage(node: "pve", draft).parameters["draid-config"] == .string("data=2,spares=1"))
        #expect(PVE.createDiskStorage(node: "pve", draft).parameters["raidlevel"] == .string("draid2"))
        draft.raidLevel = "raidz"
        #expect(PVE.createDiskStorage(node: "pve", draft).parameters["draid-config"] == nil)
        #expect(DiskStorageDraft.minimumDisks(for: "draid3") == 5)
    }
}
