import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct SDNStatusTests {
    private func connection() async throws -> ServerConnection {
        let transport = DemoTransport(cluster: .homelab)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: "root", realm: "pve"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        try #require(connection.state == .connected)
        return connection
    }

    @Test func localBridgesAndSimpleZone() async throws {
        let connection = try await connection()
        let networks = try await connection.send(PVE.sdnNodeNetworks()).filter { $0.kind != nil && $0.node == "pve1" }
        #expect(networks.map(\.name) == ["localnetwork", "lab"])
        // The snapshot still reads the guests among the network entries.
        #expect(connection.snapshot?.guests.isEmpty == false)
        let bridges = try await connection.send(PVE.sdnZoneBridges(node: "pve1", zone: "localnetwork"))
        #expect(bridges.first?.ports.contains { $0.vmid == 100 && $0.name == "tap100i0" } == true)
        #expect(try await connection.send(PVE.sdnZoneContent(node: "pve1", zone: "lab")).map(\.vnet) == ["labnet"])
        await #expect(throws: ProxmoxError.self) { _ = try await connection.send(PVE.sdnIPVRF(node: "pve1", zone: "lab")) }
    }

    /// An EVPN zone and an OpenFabric fabric on pve1 and pve2, applied, show their routes and neighbors.
    @Test func evpnAndFabricAfterApply() async throws {
        let connection = try await connection()
        let session = connection.session
        var controller = SDNControllerDraft()
        controller.id = "evpn1"
        controller.peers = "10.0.10.11,10.0.10.12"
        _ = try await session.send(PVE.createSDNController(controller))
        var zone = SDNZoneDraft()
        zone.id = "evz"
        zone.type = .evpn
        zone.controller = "evpn1"
        zone.vrfVXLAN = "10000"
        _ = try await session.send(PVE.createSDNZone(zone))
        var vnet = SDNVNetDraft()
        vnet.id = "evnet"
        vnet.zone = "evz"
        vnet.tag = "11000"
        _ = try await session.send(PVE.createSDNVNet(vnet, zoneType: .evpn))
        var subnet = SDNSubnetDraft()
        subnet.cidr = "10.60.0.0/24"
        subnet.gateway = "10.60.0.1"
        _ = try await session.send(PVE.createSDNSubnet(vnet: "evnet", subnet))
        var fabric = SDNFabricDraft(protocol: .openfabric)
        fabric.id = "under"
        fabric.ipPrefix = "10.250.0.0/24"
        _ = try await session.send(PVE.createSDNFabric(fabric))
        for (node, ip) in [("pve1", "10.250.0.1"), ("pve2", "10.250.0.2")] {
            var member = SDNFabricNodeDraft(protocol: .openfabric)
            member.node = node
            member.ip = ip
            member.interfaces = [SDNFabricInterface(name: "ens19")]
            _ = try await session.send(PVE.addSDNFabricNode(fabric: "under", member))
        }
        _ = try await session.send(PVE.applySDN())

        let networks = try await session.send(PVE.sdnNodeNetworks()).filter { $0.kind != nil && $0.node == "pve1" }
        #expect(networks.contains { $0.name == "evz" && $0.zoneType == "evpn" } && networks.contains { $0.name == "under" && $0.fabricProtocol == "openfabric" })
        let ipVRF = try await session.send(PVE.sdnIPVRF(node: "pve1", zone: "evz"))
        #expect(ipVRF.contains { $0.prefix == "10.60.0.0/24" && $0.nexthops == ["evnet"] })
        #expect(try await session.send(PVE.sdnMACVRF(node: "pve1", vnet: "evnet")).first?.nexthop == "10.0.10.12")
        #expect(try await session.send(PVE.sdnFabricNeighbors(node: "pve1", fabric: "under")).map(\.neighbor) == ["pve2"])
        #expect(try await session.send(PVE.sdnFabricRoutes(node: "pve1", fabric: "under")).map(\.route) == ["10.250.0.2/32"])
        #expect(try await session.send(PVE.sdnFabricInterfaces(node: "pve1", fabric: "under")).map(\.name) == ["ens19"])
        // pve3 is offline and not in the fabric.
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.sdnFabricRoutes(node: "pve3", fabric: "under")) }
    }
}
