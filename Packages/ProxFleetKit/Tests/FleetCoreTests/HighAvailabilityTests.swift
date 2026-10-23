import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct HighAvailabilityTests {
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

    @Test func statusResourcesAndRules() async throws {
        let manager = HAManager(connection: try await connection())
        await manager.load()
        #expect(manager.quorum?.isQuorate == true && manager.master?.node == "pve1" && manager.fencing?.armedState == "armed")
        #expect(manager.localResourceManagers.map(\.node) == ["pve1", "pve2", "pve3"])
        #expect(manager.localResourceManagers.last?.status.contains("dead") == true)
        #expect(manager.resources?.map(\.sid) == ["vm:101", "vm:104", "ct:200"])
        #expect(manager.serviceStatus(of: "vm:101")?.node == "pve1" && manager.resource(forGuest: 101)?.maxRestart == 2)
        #expect(manager.rules?.map(\.kind) == [.nodeAffinity, .resourceAffinity])
        #expect(!manager.hasFewVotes)
        // The guest list shows the HA state too.
        #expect(manager.connection.snapshot?.guests.first { $0.vmid == 101 }?.haState == "started")
    }

    @Test func addEditMoveAndRemove() async throws {
        let manager = HAManager(connection: try await connection())
        var draft = HAResourceDraft(guest: 103, kind: .virtualMachine)
        draft.state = "stopped"
        try await manager.add(draft)
        let resource = try #require(manager.resource(forGuest: 103))
        #expect(resource.state == "stopped" && manager.serviceStatus(of: "vm:103")?.node == "pve2")
        #expect(manager.connection.snapshot?.guests.first { $0.vmid == 103 }?.haState == "stopped")

        var edit = HAResourceDraft(resource)
        edit.state = "started"
        edit.maxRelocate = "3"
        try await manager.update(resource.sid, edit.changes(from: HAResourceDraft(resource)))
        #expect(manager.resource(forGuest: 103)?.maxRelocate == 3)

        try await manager.move("vm:103", to: "pve1", relocate: false)
        #expect(manager.serviceStatus(of: "vm:103")?.state == "migrate")
        try await Task.sleep(for: .seconds(3.2))
        await manager.load()
        #expect(manager.serviceStatus(of: "vm:103")?.node == "pve1")

        try await manager.remove("vm:103", purgeFromRules: true)
        #expect(manager.resource(forGuest: 103) == nil)
    }

    @Test func blockedMovesAndRules() async throws {
        let manager = HAManager(connection: try await connection())
        await manager.load()
        var strict = HARuleDraft(kind: .nodeAffinity)
        strict.resources = ["vm:104"]
        strict.nodes = ["pve1": nil]
        strict.isStrict = true
        try await manager.add(strict)
        let rule = try #require(manager.rules?.first { $0.resources == ["vm:104"] && $0.isStrict })
        await #expect(throws: ConfigUpdateError.failed("HA cannot move vm:104 to pve2: vm:104 is not allowed on pve2 by a node affinity rule.")) {
            try await manager.move("vm:104", to: "pve2", relocate: true)
        }

        var edit = HARuleDraft(rule)
        edit.isEnabled = false
        try await manager.update(rule, edit.changes(from: HARuleDraft(rule)))
        #expect(manager.rules?.first { $0.id == rule.id }?.isEnabled == false)
        try await manager.remove(rule)
        #expect(manager.rules?.contains { $0.id == rule.id } == false)

        // Removing a resource with purge drops it from rules, and rules left without resources.
        try await manager.remove("ct:200", purgeFromRules: true)
        #expect(manager.rules?.first { $0.kind == .resourceAffinity }?.resources == ["vm:104"])
    }

    @Test func disarmAndArm() async throws {
        let manager = HAManager(connection: try await connection())
        try await manager.disarm(resourceMode: "freeze")
        #expect(manager.isDisarmed && manager.fencing?.resourceMode == "freeze")
        try await manager.arm()
        #expect(!manager.isDisarmed)
    }

    @Test func standaloneHasNoHA() async throws {
        #expect(!HAManager(connection: try await connection(cluster: .standalone)).isAvailable)
    }
}
