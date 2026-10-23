import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct MigrationTests {
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

    private func draft(_ detail: GuestDetail, to target: String) async throws -> MigrationDraft {
        var draft = MigrationDraft(guest: detail.reference, target: target)
        (draft.preconditions, draft.targetSupportsConntrackState) = try await detail.migrationPreconditions(target: target)
        return draft
    }

    /// home-assistant runs on pve1 with its disk on local-lvm, so it moves live and copies the disk.
    @Test func runningVMMovesLiveAndTheDetailFollows() async throws {
        let connection = try await connection()
        let detail = GuestDetail(reference: GuestReference(node: "pve1", vmid: 100, kind: .virtualMachine), connection: connection)
        await detail.load()
        let draft = try await draft(detail, to: "pve2")
        #expect(draft.mode == .online && draft.showsConntrackState && draft.canMigrate)
        #expect(draft.notes.map(\.text) == ["Migration with local disk might take long: local-lvm:vm-100-disk-0 (32 GB)"])

        let task = try await detail.migrate(draft)
        #expect(task.title == "VM 100 – Migrate")
        #expect(await connection.tasks.result(of: task.id) == .succeeded)
        for _ in 0..<20 where detail.reference.node != "pve2" { try await Task.sleep(for: .milliseconds(100)) }
        #expect(detail.reference.node == "pve2" && detail.status?.powerState == .running)
        #expect(connection.snapshot?.guests.first { $0.vmid == 100 }?.node == "pve2")
    }

    @Test func localISOKeepsAVMWhereItIs() async throws {
        let detail = GuestDetail(reference: GuestReference(node: "pve2", vmid: 103, kind: .virtualMachine), connection: try await connection())
        let draft = try await draft(detail, to: "pve1")
        #expect(!draft.canMigrate && draft.notes.first?.severity == .error && draft.notes.first?.text.contains("ubuntu-24.04.3") == true)
        // The server refuses as well, in the task.
        let task = try await detail.migrate(draft)
        guard case .failed(let message) = await detail.connection.tasks.result(of: task.id) else {
            Issue.record("expected the migration to fail")
            return
        }
        #expect(message.contains("local cdrom image"))
    }

    /// A guest moved by someone else, or by HA, is followed once its old node no longer has it.
    @Test func detailFollowsAGuestMovedElsewhere() async throws {
        let connection = try await connection()
        let detail = GuestDetail(reference: GuestReference(node: "pve1", vmid: 202, kind: .container), connection: connection)
        await detail.load()
        var draft = MigrationDraft(guest: detail.reference, target: "pve2")
        draft.preconditions = try await connection.session.send(PVE.migrationPreconditions(detail.reference, target: "pve2"))
        #expect(draft.mode == .restart)
        let upid = try await connection.session.send(PVE.migrate(draft))
        #expect(await connection.tasks.result(of: try connection.tasks.track(upid).id) == .succeeded)
        await detail.refresh()
        #expect(detail.reference.node == "pve2" && detail.loadError == nil)
    }

    @Test func bulkMigrationFromANodeAndTheDatacenter() async throws {
        let connection = try await connection()
        let snapshot = try #require(connection.snapshot)
        #expect(NodeBulkAction.migrate.eligibleGuests(on: "pve1", in: snapshot).map(\.vmid) == [100, 101, 104, 200, 202, 9000])

        var draft = NodeBulkActionDraft(action: .migrate, vmids: [200, 9000])
        draft.target = "pve2"
        let task = try await NodeDetail(node: "pve1", connection: connection).run(draft)
        #expect(task.title == "Bulk Migrate")
        #expect(await connection.tasks.result(of: task.id) == .succeeded)
        try await Task.sleep(for: .seconds(3.5))
        await connection.refresh()
        #expect(connection.snapshot?.guests.filter { [200, 9000].contains($0.vmid) }.allSatisfy { $0.node == "pve2" } == true)

        var back = NodeBulkActionDraft(action: .migrate, vmids: [200, 201])
        back.target = "pve1"
        let bulk = try await connection.runBulkAction(back)
        #expect(bulk.title == "Bulk Migrate")
        #expect(await connection.tasks.result(of: bulk.id) == .succeeded)
        try await Task.sleep(for: .seconds(3.5))
        await connection.refresh()
        #expect(connection.snapshot?.guests.filter { [200, 201].contains($0.vmid) }.allSatisfy { $0.node == "pve1" } == true)
    }
}
