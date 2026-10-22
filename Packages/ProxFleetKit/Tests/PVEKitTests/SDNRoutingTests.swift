import Foundation
import ProxmoxCore
@testable import PVEKit
import Testing

/// Controllers, EVPN zones, fabrics, prefix lists and route maps. The JSON is recorded from the test server.
struct SDNRoutingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func controllersAndEVPNZones() throws {
        let controllers = try decode([SDNObject].self, #"""
        [{"type": "bgp", "controller": "bgppve-claude", "state": "new", "pending": {"peers": "10.10.100.1", "node": "pve-claude", "asn": 65001, "ebgp": 1}, "digest": null},
         {"controller": "isispve-claude", "type": "isis", "state": "new", "pending": {"isis-ifaces": "nic0", "isis-domain": "pf", "node": "pve-claude", "isis-net": "49.0001.1720.1600.1001.00"}},
         {"pending": {"peers": "10.10.100.150", "asn": 65000}, "state": "new", "controller": "pfevpn", "type": "evpn"}]
        """#)
        #expect(controllers.map(\.id) == ["bgppve-claude", "isispve-claude", "pfevpn"])
        let bgp = SDNControllerDraft(controllers[0])
        #expect(bgp.type == .bgp && bgp.node == "pve-claude" && bgp.ebgp && bgp.asn == "65001" && bgp.resolvedID == "bgppve-claude")
        let isis = SDNControllerDraft(controllers[1])
        #expect(isis.problems(isNew: false).isEmpty && isis.isisNet == "49.0001.1720.1600.1001.00")

        var evpn = SDNControllerDraft()
        evpn.id = "evpn1"
        #expect(evpn.problems(isNew: true)["peers"] != nil)
        evpn.peers = "10.0.0.1 10.0.0.2"
        evpn.bgpMode = "internal"
        #expect(evpn.problems(isNew: true).isEmpty)
        #expect(PVE.createSDNController(evpn).parameters.formEncoded
            == "controller=evpn1&type=evpn&asn=65000&bgp-mode=internal&peers=10.0.0.1%2C10.0.0.2")
        var isisNew = SDNControllerDraft(type: .isis)
        isisNew.node = "pve1"
        isisNew.isisNet = "49.1"
        #expect(isisNew.problems(isNew: true).keys.sorted() == ["isis-domain", "isis-ifaces", "isis-net"])
        // The node is part of a per-node controller's ID.
        var moved = bgp
        moved.node = "pve2"
        moved.multipathRelax = true
        #expect(moved.changes(from: bgp).values == ["bgp-multipath-as-path-relax": "1"])

        let zone = try decode(SDNObject.self, #"""
        {"zone": "pfevz", "type": "evpn", "digest": null, "state": "new",
         "pending": {"vrf-vxlan": 10000, "controller": "pfevpn", "mtu": 1450, "exitnodes": "pve-claude", "mac": "BC:24:11:14:BB:C0"}}
        """#)
        #expect(zone.id == "pfevz" && zone["controller"] == "pfevpn")
        var draft = SDNZoneDraft(zone)
        #expect(draft.type == .evpn && draft.vrfVXLAN == "10000" && draft.exitNodes == ["pve-claude"] && draft.mac == "BC:24:11:14:BB:C0")
        #expect(draft.changes(from: draft).isEmpty)
        let original = draft
        draft.secondaryControllers = ["bgppve-claude"]
        draft.advertisesSubnets = true
        draft.exitNodes = []
        let update = draft.changes(from: original)
        #expect(update.lists == ["secondary-controllers": ["bgppve-claude"]] && update.values == ["advertise-subnets": "1"] && update.deletions == ["exitnodes"])
        #expect(update.parameters.formEncoded == "advertise-subnets=1&secondary-controllers=bgppve-claude&delete=exitnodes")

        var newZone = SDNZoneDraft()
        newZone.id = "evz"
        newZone.type = .evpn
        newZone.primaryExitNode = "pve2"
        newZone.exitNodes = ["pve1"]
        newZone.mac = "nope"
        #expect(newZone.problems(isNew: true).keys.sorted() == ["controller", "exitnodes-primary", "mac", "vrf-vxlan"])
        var vnet = SDNVNetDraft()
        vnet.id = "evnet"
        vnet.zone = "evz"
        vnet.tag = "11000"
        #expect(vnet.problems(isNew: true, zoneType: .evpn).isEmpty)
        vnet.tag = ""
        #expect(vnet.problems(isNew: true, zoneType: .evpn)["tag"] != nil)

        var vxlan = SDNZoneDraft()
        vxlan.id = "vx"
        vxlan.type = .vxlan
        #expect(vxlan.problems(isNew: true)["peers"] != nil)
        vxlan.fabric = "fab1"
        #expect(vxlan.problems(isNew: true).isEmpty && PVE.createSDNZone(vxlan).parameters["fabric"] == "fab1")
    }

    @Test func fabrics() throws {
        let all = try decode(SDNFabrics.self, #"""
        {"fabrics": [{"state": "new", "pending": {"ip_prefix": "10.202.0.0/24", "redistribute": ["source=connected"], "protocol": "ospf", "id": "pfospf", "area": "0"}, "digest": "c2"},
                     {"digest": "c2", "state": "new", "pending": {"protocol": "bgp", "id": "pfbgp", "bfd": 1, "ip_prefix": "10.201.0.0/24"}},
                     {"id": "pfof", "protocol": "openfabric", "hello_interval": 5, "ip_prefix": "10.200.0.0/24", "digest": "c2"}],
         "nodes": [{"digest": "c2", "state": "new", "pending": {"node_id": "pve-claude", "protocol": "openfabric", "interfaces": ["name=nic0", "name=nic1,ip=10.200.1.1/31,hello_multiplier=4"], "fabric_id": "pfof", "ip": "10.200.0.1"}}]}
        """#)
        #expect(all.fabrics.map(\.id) == ["pfospf", "pfbgp", "pfof"])
        let ospf = SDNFabricDraft(all.fabrics[0])
        #expect(ospf.protocolType == .ospf && ospf.redistribution == [SDNRedistribution(source: "connected")] && ospf.area == "0")
        #expect(SDNFabricDraft(all.fabrics[1]).bfd && all.fabrics[2].state == nil)

        let node = try #require(all.nodes.first)
        #expect(node.id == "pve-claude" && node.fabricID == "pfof")
        var nodeDraft = SDNFabricNodeDraft(node)
        #expect(nodeDraft.interfaces.map(\.name) == ["nic0", "nic1"] && nodeDraft.interfaces[1].helloMultiplier == "4")
        #expect(nodeDraft.changes(from: nodeDraft).isEmpty)
        let originalNode = nodeDraft
        nodeDraft.interfaces.removeFirst()
        nodeDraft.ip = ""
        // Interfaces keep settings the form does not show; deletions go as a list.
        #expect(nodeDraft.changes(from: originalNode).parameters.formEncoded
            == "interfaces=name%3Dnic1%2Cip%3D10.200.1.1%2F31%2Chello_multiplier%3D4&delete=ip")
        #expect(PVE.updateSDNFabricNode(fabric: "pfof", node: "pve-claude", protocol: .openfabric, nodeDraft.changes(from: originalNode)).parameters["protocol"] == "openfabric")

        var bgpNode = SDNFabricNodeDraft(protocol: .bgp)
        bgpNode.node = "pve1"
        bgpNode.ip = "10.201.0.1"
        bgpNode.interfaces = [SDNFabricInterface(name: "ens19")]
        #expect(bgpNode.problems(isNew: true).keys.sorted() == ["asn"])
        bgpNode.asn = "65010"
        #expect(PVE.addSDNFabricNode(fabric: "pfbgp", bgpNode).parameters.formEncoded
            == "node_id=pve1&protocol=bgp&role=internal&asn=65010&ip=10.201.0.1&interfaces=name%3Dens19")

        var fabric = SDNFabricDraft(protocol: .bgp)
        fabric.id = "-bad"
        #expect(fabric.problems(isNew: true).keys.sorted() == ["id", "ip_prefix"])
        fabric.id = "under1"
        fabric.ipPrefix = "10.9.0.0/24"
        fabric.redistribution = [SDNRedistribution(source: "connected", routeMap: "rm1")]
        fabric.bfd = true
        #expect(fabric.problems(isNew: true).isEmpty)
        #expect(PVE.createSDNFabric(fabric).parameters.formEncoded
            == "id=under1&protocol=bgp&bfd=1&ip_prefix=10.9.0.0%2F24&redistribute=source%3Dconnected%2Croute-map%3Drm1")
        var openFabric = SDNFabricDraft(all.fabrics[2])
        let originalFabric = openFabric
        openFabric.helloInterval = ""
        openFabric.csnpInterval = "20"
        #expect(PVE.updateSDNFabric("pfof", protocol: .openfabric, openFabric.changes(from: originalFabric)).parameters.formEncoded
            == "csnp_interval=20&delete=hello_interval&protocol=openfabric")
    }

    @Test func prefixListsAndRouteMaps() throws {
        let entries = try decode([SDNPrefixListEntry].self, #"""
        [{"seq": 5, "prefix": "10.0.0.0/8", "action": "permit", "le": 24}, {"prefix": "0.0.0.0/0", "seq": 20, "action": "deny"}]
        """#)
        #expect(entries.map(\.sequence) == [5, 20] && entries[0].le == 24 && entries[1].ge == nil)
        var entry = SDNPrefixListEntryDraft(entries[0])
        let original = entry
        entry.le = ""
        entry.ge = "16"
        #expect(entry.changes(from: original).parameters.formEncoded == "ge=16&delete=le")
        var newEntry = SDNPrefixListEntryDraft()
        newEntry.prefix = "fd00::/8"
        newEntry.le = "64"
        #expect(newEntry.problems.isEmpty)
        #expect(PVE.createSDNPrefixListEntry(list: "pl", newEntry).parameters.formEncoded == "action=permit&le=64&prefix=fd00%3A%3A%2F8")
        newEntry.ge = "80"
        newEntry.prefix = "10.0.0.0"
        #expect(newEntry.problems.keys.sorted() == ["ge", "prefix"])

        let objects = try decode([SDNObject].self, #"""
        [{"route-map-id": "pfrm", "action": "permit", "digest": "ca", "pending": {"action": "deny", "exit-action": "deleted"},
          "match": ["key=ip-address-prefix-list,value=pfpl"], "set": ["key=local-preference,value=200"], "exit-action": "key=on-match-next", "order": 10, "state": "changed"},
         {"state": "new", "pending": {"set": [], "action": "deny", "route-map-id": "pfrm", "match": [], "order": 20}, "digest": "d8"}]
        """#)
        let routeMap = objects.map(SDNRouteMapEntry.init)
        #expect(routeMap.map(\.id) == ["pfrm/10", "pfrm/20"])
        #expect(routeMap[0].action == "deny" && routeMap[0].state == .changed && routeMap[0].object.values["exit-action"] == nil)
        #expect(routeMap[0].match == [SDNRouteMapClause(key: "ip-address-prefix-list", value: "pfpl")])
        var draft = SDNRouteMapEntryDraft(routeMap[0])
        #expect(draft.exitAction == .exit && draft.set == [SDNRouteMapClause(key: "local-preference", value: "200")])
        let originalDraft = draft
        draft.set.append(SDNRouteMapClause(key: "ip-next-hop-unchanged"))
        draft.match = []
        draft.exitAction = .goto
        #expect(draft.problems(isNew: false)["exit-action"] != nil)
        draft.exitTarget = "20"
        #expect(draft.problems(isNew: false).isEmpty)
        #expect(PVE.updateSDNRouteMapEntry(routeMap: "pfrm", order: 10, draft.changes(from: originalDraft)).parameters.formEncoded
            == "exit-action=key%3Don-match-goto%2Cvalue%3D20&set=key%3Dlocal-preference%2Cvalue%3D200&set=key%3Dip-next-hop-unchanged&delete=match")

        var created = SDNRouteMapEntryDraft(routeMap: "in", order: "10")
        created.match = [SDNRouteMapClause(key: "metric", value: "abc")]
        #expect(created.problems(isNew: true).keys.sorted() == ["match"])
        created.match = [SDNRouteMapClause(key: "vni", value: "100")]
        created.exitAction = .next
        #expect(PVE.createSDNRouteMapEntry(created).parameters.formEncoded
            == "route-map-id=in&order=10&action=permit&exit-action=key%3Don-match-next&match=key%3Dvni%2Cvalue%3D100")
    }

    @Test func ipMappings() {
        #expect(PVE.updateIPMapping(vnet: "pfnet", zone: "pflive", ip: "10.77.0.150", mac: "BC:24:11:00:00:01", vmid: 101).parameters.formEncoded
            == "zone=pflive&ip=10.77.0.150&mac=BC%3A24%3A11%3A00%3A00%3A01&vmid=101")
        #expect(PVE.deleteIPMapping(vnet: "pfnet", zone: "pflive", ip: "10.77.0.150", mac: nil).method == .delete)
    }
}
