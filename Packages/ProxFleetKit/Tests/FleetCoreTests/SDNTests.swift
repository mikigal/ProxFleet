import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct SDNTests {
    private func settings() async throws -> SDNSettings {
        let transport = DemoTransport(cluster: .homelab)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: "root", realm: "pam"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        try #require(connection.state == .connected)
        return SDNSettings(connection: connection)
    }

    @Test func drafts() {
        var zone = SDNZoneDraft()
        zone.id = "toolongname"
        zone.type = .qinq
        let problems = zone.problems(isNew: true)
        #expect(problems["zone"] != nil && problems["bridge"] != nil && problems["tag"] != nil)
        zone.id = "office"
        zone.bridge = "vmbr0"
        zone.serviceVLAN = "100"
        zone.automaticDHCP = true
        #expect(zone.problems(isNew: true).isEmpty)
        // DHCP only applies to simple zones and is not sent for others.
        let parameters = PVE.createSDNZone(zone).parameters
        #expect(parameters["dhcp"] == nil && parameters["tag"] == "100")

        var vnet = SDNVNetDraft()
        vnet.id = "net1"
        vnet.zone = "office"
        #expect(vnet.problems(isNew: true, zoneType: .vlan)["tag"] != nil)
        #expect(vnet.problems(isNew: true, zoneType: .qinq).isEmpty)
        vnet.tag = "5000"
        #expect(vnet.problems(isNew: true, zoneType: .vlan)["tag"] != nil)
        #expect(vnet.problems(isNew: true, zoneType: .vxlan).isEmpty)

        var subnet = SDNSubnetDraft()
        subnet.cidr = "10.0.0.0"
        #expect(subnet.problems(isNew: true)["subnet"] != nil)
        subnet.cidr = "fd00:1::/64"
        subnet.ranges = [SDNDHCPRange(start: "fd00:1::100", end: "")]
        #expect(subnet.problems(isNew: true) == ["dhcp-range": String(localized: "Enter a start and an end address for each range.")])
        subnet.ranges = [SDNDHCPRange(start: "", end: "")]
        #expect(subnet.problems(isNew: true).isEmpty)
        #expect(PVE.createSDNSubnet(vnet: "net1", subnet).parameters.values("dhcp-range").isEmpty)
    }

    @Test func pendingChangesAndApply() async throws {
        let settings = try await settings()
        await settings.load()
        #expect(settings.zones?.map(\.id) == ["lab"] && settings.vnets?.map(\.id) == ["labnet"])
        #expect(!settings.hasPendingChanges)
        #expect(settings.zoneStatus.values.first?["lab"] == "available")
        let labSubnet = try #require(settings.subnets["labnet"]?.first)
        #expect(labSubnet["cidr"] == "10.50.0.0/24" && labSubnet.ranges.count == 1)

        var zone = SDNZoneDraft()
        zone.id = "office"
        zone.type = .vlan
        zone.bridge = "vmbr0"
        try await settings.createZone(zone)
        var vnet = SDNVNetDraft()
        vnet.id = "desks"
        vnet.zone = "office"
        vnet.tag = "20"
        try await settings.createVNet(vnet)
        var subnet = SDNSubnetDraft()
        subnet.cidr = "192.168.20.0/24"
        subnet.gateway = "192.168.20.1"
        subnet.ranges = [SDNDHCPRange(start: "192.168.20.100", end: "192.168.20.150")]
        try await settings.createSubnet(vnet: "desks", subnet)
        #expect(settings.hasPendingChanges)
        #expect(settings.zones?.first { $0.id == "office" }?.state == .new)
        let created = try #require(settings.subnets["desks"]?.first)
        #expect(created.state == .new && created.ranges == subnet.ranges)

        // Changing an applied subnet keeps its applied values until Apply.
        var edited = SDNSubnetDraft(labSubnet)
        let original = edited
        edited.ranges.append(SDNDHCPRange(start: "10.50.0.200", end: "10.50.0.210"))
        edited.snat = false
        try await settings.updateSubnet(vnet: "labnet", id: labSubnet.id, edited.changes(from: original))
        let changed = try #require(settings.subnets["labnet"]?.first)
        #expect(changed.state == .changed && changed.ranges.count == 2 && changed.runningRanges.count == 1 && changed["snat"] == nil)

        await #expect(throws: ConfigUpdateError.self) { try await settings.deleteZone("office") }
        try await settings.rollback()
        #expect(settings.zones?.map(\.id) == ["lab"] && settings.subnets["labnet"]?.first?.state == nil)

        try await settings.createZone(zone)
        try await settings.createVNet(vnet)
        let task = try await settings.apply()
        #expect(task.upid.type == "reloadnetworkall")
        try await Task.sleep(for: .seconds(2.5))
        await settings.load()
        #expect(!settings.hasPendingChanges && settings.zones?.first { $0.id == "office" }?.running["bridge"] == "vmbr0")

        try await settings.deleteVNet("desks")
        #expect(settings.vnets?.first { $0.id == "desks" }?.state == .deleted)
        let entries = try await settings.ipamEntries("pve")
        #expect(entries.contains { $0.isGateway && $0.ip == "10.50.0.1" })
    }

    @Test func routingObjectsAreAppliedWithTheRest() async throws {
        let settings = try await settings()
        await settings.load()
        #expect(settings.controllers.isEmpty && settings.prefixListNames == ["private"] && settings.routeMapNames == ["uplink-in"])
        #expect(settings.routeMaps.first?.entries.first?.match.first?.value == "private")

        var controller = SDNControllerDraft()
        controller.id = "evpn1"
        controller.peers = "10.0.10.11,10.0.10.12"
        try await settings.createController(controller)
        var second = controller
        second.id = "evpn2"
        // Proxmox allows one EVPN controller.
        await #expect(throws: ConfigUpdateError.self) { try await settings.createController(second) }

        var zone = SDNZoneDraft()
        zone.id = "evz"
        zone.type = .evpn
        zone.controller = "evpn1"
        zone.vrfVXLAN = "10000"
        try await settings.createZone(zone)
        let evpnZone = try #require(settings.zones?.first { $0.id == "evz" })
        #expect(evpnZone.state == .new && SDNZoneDraft(evpnZone).mac.isEmpty == false)
        await #expect(throws: ConfigUpdateError.self) { try await settings.deleteController("evpn1") }

        var fabric = SDNFabricDraft(protocol: .ospf)
        fabric.id = "under"
        fabric.ipPrefix = "10.255.0.0/24"
        fabric.redistribution = [SDNRedistribution(source: "connected")]
        try await settings.createFabric(fabric)
        var node = SDNFabricNodeDraft(protocol: .ospf)
        node.node = "pve1"
        node.ip = "10.255.0.1"
        node.interfaces = [SDNFabricInterface(name: "nic1")]
        try await settings.addFabricNode(fabric: "under", node)
        #expect(settings.nodes(ofFabric: "under").map(\.id) == ["pve1"])
        await #expect(throws: ConfigUpdateError.self) { try await settings.deleteFabric("under") }
        let saved = SDNFabricDraft(try #require(settings.fabrics.first))
        var edited = saved
        edited.area = "0.0.0.1"
        edited.redistribution = []
        try await settings.updateFabric("under", protocol: .ospf, edited.changes(from: saved))
        #expect(settings.fabrics.first?.lists["redistribute"] == nil && settings.fabrics.first?["area"] == "0.0.0.1")

        try await settings.createPrefixList("bogons")
        var entry = SDNPrefixListEntryDraft()
        entry.action = "deny"
        entry.prefix = "0.0.0.0/8"
        try await settings.createPrefixListEntry(list: "bogons", entry)
        try await settings.createPrefixListEntry(list: "bogons", entry)
        let entries = try await settings.prefixListEntries("bogons")
        #expect(entries.map(\.sequence) == [5, 10])
        var changedEntry = SDNPrefixListEntryDraft(entries[1])
        changedEntry.prefix = "127.0.0.0/8"
        try await settings.updatePrefixListEntry(list: "bogons", sequence: 10, changedEntry.changes(from: SDNPrefixListEntryDraft(entries[1])))
        try await settings.deletePrefixListEntry(list: "bogons", sequence: 5)
        #expect(try await settings.prefixListEntries("bogons").map(\.prefix) == ["127.0.0.0/8"])

        var routeEntry = SDNRouteMapEntryDraft(routeMap: "uplink-in", order: "20")
        routeEntry.action = "deny"
        routeEntry.match = [SDNRouteMapClause(key: "ip-address-prefix-list", value: "bogons")]
        try await settings.createRouteMapEntry(routeEntry)
        #expect(settings.routeMaps.first?.entries.map(\.order) == [10, 20])
        #expect(settings.hasPendingChanges)

        let task = try await settings.apply()
        #expect(task.upid.type == "reloadnetworkall")
        try await Task.sleep(for: .seconds(2.5))
        await settings.load()
        #expect(!settings.hasPendingChanges && settings.controllers.first?.running["peers"] == "10.0.10.11,10.0.10.12")

        try await settings.deleteRouteMapEntry(routeMap: "uplink-in", order: 20)
        #expect(settings.routeMaps.first?.entries.last?.state == .deleted)
        try await settings.rollback()
        #expect(settings.routeMaps.first?.entries.last?.state == nil)
    }

    @Test func ipMappings() async throws {
        let settings = try await settings()
        try await settings.createIPMapping(vnet: "labnet", zone: "lab", ip: "10.50.0.20", mac: "BC:24:11:00:00:20")
        #expect(try await settings.ipamEntries("pve").contains { $0.ip == "10.50.0.20" && $0.mac == "BC:24:11:00:00:20" })
        try await settings.updateIPMapping(vnet: "labnet", zone: "lab", ip: "10.50.0.21", mac: "BC:24:11:00:00:20", vmid: nil)
        try await settings.deleteIPMapping(vnet: "labnet", zone: "lab", ip: "10.50.0.21", mac: "BC:24:11:00:00:20")
        #expect(try await !settings.ipamEntries("pve").contains { $0.mac == "BC:24:11:00:00:20" })
    }

    @Test func vnetFirewall() async throws {
        let settings = try await settings()
        let firewall = Firewall(connection: settings.connection, scope: .vnet("labnet", zone: "lab"))
        await firewall.load()
        #expect(firewall.rules == [] && !firewall.isEnabled)
        var rule = FirewallRuleDraft()
        rule.type = "forward"
        rule.macro = "HTTPS"
        try await firewall.createRule(rule)
        #expect(firewall.rules?.first?.type == "forward")
    }
}
