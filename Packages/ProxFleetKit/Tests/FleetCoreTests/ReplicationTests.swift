import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct ReplicationTests {
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

    @Test func datacenterListShowsTheStateFromEachNode() async throws {
        let list = ReplicationJobList(connection: try await connection(), scope: .datacenter)
        #expect(list.isAvailable)
        await list.load()
        let jobs = try #require(list.jobs)
        #expect(jobs.map(\.id) == ["101-0", "104-0", "200-0", "202-0"])
        #expect(jobs[0].lastSync != nil && jobs[0].rate == 100)
        #expect(jobs[1].error?.contains("exit code 255") == true && jobs[1].failCount == 96)
        #expect(!jobs[3].isEnabled)
    }

    @Test func nodeAndGuestListsCoverTheirGuests() async throws {
        let connection = try await connection()
        let node = ReplicationJobList(connection: connection, scope: .node("pve2"))
        await node.load()
        #expect(node.jobs?.isEmpty == true)
        let guest = ReplicationJobList(connection: connection, scope: .guest(GuestReference(node: "pve1", vmid: 101, kind: .virtualMachine)))
        await guest.load()
        #expect(guest.jobs?.map(\.id) == ["101-0"])
    }

    @Test func createRunEditAndRemove() async throws {
        let connection = try await connection()
        let list = ReplicationJobList(connection: connection, scope: .guest(GuestReference(node: "pve1", vmid: 101, kind: .virtualMachine)))
        var draft = ReplicationJobDraft(guest: 101, target: "pve3")
        draft.schedule = "*/5"
        try await list.create(draft)
        let job = try #require(list.jobs?.first { $0.id == "101-1" })
        #expect(job.schedule == "*/5" && job.lastSync == nil && job.isPending())

        try await list.runNow(job)
        #expect(list.jobs?.first { $0.id == "101-1" }?.isRunning == true)
        try await Task.sleep(for: .seconds(3.2))
        await list.load()
        // pve3 is offline, so the run fails.
        #expect(list.jobs?.first { $0.id == "101-1" }?.failCount == 1)

        var edit = ReplicationJobDraft(job)
        edit.rate = "20"
        try await list.update(job.id, edit.changes(from: ReplicationJobDraft(job)))
        #expect(list.jobs?.first { $0.id == "101-1" }?.rate == 20)

        try await list.delete(job)
        #expect(list.jobs?.first { $0.id == "101-1" }?.removal == "full")
        try await Task.sleep(for: .seconds(3.2))
        await list.load()
        #expect(list.jobs?.contains { $0.id == "101-1" } == false)
        #expect(try await list.log(of: try #require(list.jobs?.first)).last?.text.hasSuffix("end replication job") == true)
    }

    @Test func refusals() async throws {
        let list = ReplicationJobList(connection: try await connection(), scope: .datacenter)
        await #expect(throws: ConfigUpdateError.failed("Source and target must not be identical")) {
            try await list.create(ReplicationJobDraft(guest: 101, target: "pve1"))
        }
        var draft = ReplicationJobDraft(guest: 101, target: "pve2")
        draft.schedule = "whenever"
        await #expect(throws: ConfigUpdateError.self) { try await list.create(draft) }
        #expect(await list.nextRuns(of: "*/15").map(\.count) == .success(3))
    }

    @Test func standaloneHasNoReplication() async throws {
        let list = ReplicationJobList(connection: try await connection(cluster: .standalone), scope: .datacenter)
        #expect(!list.isAvailable)
    }
}
