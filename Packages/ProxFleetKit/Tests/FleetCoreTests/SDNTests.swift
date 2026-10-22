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
