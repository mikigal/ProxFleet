import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct CephTests {
    private func connection(cluster: DemoCluster = .homelab) async throws -> ServerConnection {
        let transport = DemoTransport(cluster: cluster)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: "root", realm: "pve"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        try #require(connection.state == .connected)
        return connection
    }

    /// The home lab runs Ceph with pve3 down.
    @Test func homelabStatus() async throws {
        let manager = CephManager(connection: try await connection(), node: "pve1")
        await manager.load()
        let status = try #require(manager.status)
        #expect(manager.setupState == .ready && status.health == "HEALTH_WARN")
        #expect(status.checks.map(\.code).contains("MON_DOWN") && status.checks.map(\.code).contains("OSD_DOWN"))
        #expect(status.quorum == ["pve1", "pve2"] && status.osdsUp == 4 && status.osdCount == 6)
        #expect(manager.services[.monitor]?.map(\.state) == ["running", "running", "stopped"])
        #expect(manager.osdTree?.hosts == ["pve1", "pve2", "pve3"] && manager.osdTree?.osds.filter(\.isUp).count == 4)
        #expect(manager.pools?.map(\.name) == [".mgr", "cephfs_data", "cephfs_metadata", "vm-pool"])
        #expect(manager.fileSystems?.map(\.name) == ["cephfs"] && manager.rules == ["replicated_rule"])
        #expect(manager.flags?.count == 11)
    }

    /// The standalone node installs Ceph, then gets its configuration and first monitor.
    @Test func setUpFromScratch() async throws {
        let connection = try await connection(cluster: .standalone)
        let manager = CephManager(connection: connection, node: "pve")
        await manager.load()
        #expect(manager.setupState == .notInstalled)
        #expect(await manager.releases().map(\.name) == ["squid", "tentacle"])
        // The demo counts opening the install shell as installing.
        _ = try await connection.session.send(APIRequest<Nothing>(.post, "/nodes/pve/termproxy", parameters: ["cmd": "ceph_install"]))
        await manager.load()
        #expect(manager.setupState == .notInitialized)
        #expect(CephManager.network(of: "192.168.1.20/24") == "192.168.1.0/24" && CephManager.network(of: "fd00::1/64") == nil)
        try await manager.initialize(network: "192.168.1.0/24", clusterNetwork: nil, size: 2, minSize: 2)
        #expect(manager.setupState == .ready && manager.services[.monitor]?.map(\.name) == ["pve"] && manager.services[.manager]?.count == 1)

        let disk = try #require(await manager.unusedDisks(on: "pve").first)
        try await manager.createOSD(on: "pve", CephOSDDraft(device: disk.path))
        #expect(manager.osdTree?.osds.map(\.host) == ["pve"])
        #expect(await manager.unusedDisks(on: "pve").contains { $0.path == disk.path } == false)
        #expect(manager.status?.checks.map(\.code).contains("TOO_FEW_OSDS") == true)
    }

    @Test func servicesOSDsAndFlags() async throws {
        let manager = CephManager(connection: try await connection(), node: "pve1")
        await manager.load()
        // pve3 is offline, and pve1 has a manager already.
        await #expect(throws: ConfigUpdateError.self) { try await manager.create(.manager, on: "pve3") }
        await #expect(throws: ConfigUpdateError.self) { try await manager.create(.manager, on: "pve1") }
        try await manager.create(.metadataServer, on: "pve1", id: "pve1-b", hotStandby: true)
        #expect(manager.services[.metadataServer]?.map(\.name) == ["pve1", "pve1-b", "pve2"])
        let standby = try #require(manager.services[.manager]?.first { $0.name == "pve2" })
        try await manager.perform("stop", service: "mgr.pve2", host: "pve2")
        #expect(manager.services[.manager]?.first { $0.name == "pve2" }?.state == "stopped")
        try await manager.destroy(.manager, standby)
        #expect(manager.services[.manager]?.contains { $0.name == "pve2" } == false)

        let osd = try #require(manager.osdTree?.osds.first { $0.id == 3 })
        #expect(await manager.safety(of: "osd", id: "3", action: "stop", host: "pve2")?.isSafe == false)
        await #expect(throws: ConfigUpdateError.self) { try await manager.destroy(osd, cleanup: true) }
        try await manager.set(osd, in: false)
        try await manager.perform("stop", service: "osd.3", host: "pve2")
        try await manager.destroy(osd, cleanup: true)
        #expect(manager.osdTree?.osds.contains { $0.id == 3 } == false)

        try await manager.setFlags(["noout": true])
        #expect(manager.flags?.first { $0.name == "noout" }?.isSet == true && manager.status?.checks.contains { $0.code == "OSDMAP_FLAGS" } == true)
    }

    @Test func poolsAndFileSystems() async throws {
        let connection = try await connection()
        let manager = CephManager(connection: connection, node: "pve1")
        await manager.load()
        var draft = CephPoolDraft()
        draft.name = "db-pool"
        draft.size = 2
        try await manager.createPool(draft)
        let pool = try #require(manager.pools?.first { $0.name == "db-pool" })
        #expect(pool.size == 2 && pool.applications == ["rbd"])
        #expect(connection.snapshot?.storages.contains { $0.name == "db-pool" } == true)

        var edit = CephPoolDraft(pool)
        edit.placementGroups = "64"
        try await manager.updatePool(pool.name, edit.changes(from: CephPoolDraft(pool)))
        #expect(manager.pools?.first { $0.name == "db-pool" }?.placementGroups == 64)
        try await manager.destroyPool("db-pool", removeStorages: true)
        #expect(manager.pools?.contains { $0.name == "db-pool" } == false)

        try await manager.createFileSystem(name: "media", placementGroups: 32, addStorage: false)
        #expect(manager.fileSystems?.map(\.name) == ["cephfs", "media"] && manager.pools?.contains { $0.name == "media_data" } == true)
        #expect(try await manager.configFile().contains("public_network = 10.0.10.0/24"))
        #expect(try await manager.crushMap().contains("rule replicated_rule"))
        #expect(try await !manager.log().isEmpty)
        #expect(try await !manager.configDatabase().isEmpty)
    }
}
