import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

/// The datacenter's bulk actions, the cluster log, system reports and changelogs in demo mode.
@MainActor
struct DatacenterToolsTests {
    private func connection() async throws -> ServerConnection {
        let transport = DemoTransport(cluster: .homelab)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: "root", realm: "pam"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        try #require(connection.state == .connected)
        return connection
    }

    @Test func clusterBulkActionParameters() {
        var draft = NodeBulkActionDraft(action: .hibernate, vmids: [101, 100])
        draft.maxWorkers = 2
        let request = PVE.clusterBulkAction(draft)
        #expect(request.path == "/cluster/bulk-action/guest/suspend")
        #expect(request.parameters.formEncoded == "vms=100&vms=101&max-workers=2&to-disk=1")
        var shutdown = NodeBulkActionDraft(action: .shutdown, vmids: [200])
        shutdown.timeout = 60
        shutdown.forceStop = false
        #expect(PVE.clusterBulkAction(shutdown).parameters.formEncoded == "vms=200&timeout=60&force-stop=0")
        #expect(PVE.clusterBulkAction(NodeBulkActionDraft(action: .start, vmids: [1])).path == "/cluster/bulk-action/guest/start")
    }

    @Test func bulkActionsAcrossNodes() async throws {
        let connection = try await connection()
        let snapshot = try #require(connection.snapshot)
        let stopped = NodeBulkAction.start.eligibleGuests(on: nil, in: snapshot)
        #expect(Set(stopped.map(\.node)).count > 1 || stopped.count == snapshot.guests.filter { !$0.isTemplate && $0.state == .stopped }.count)
        let task = try await connection.runBulkAction(NodeBulkActionDraft(action: .start, vmids: Set(stopped.map(\.vmid))))
        #expect(task.upid.type == "bulk-start")
        #expect(await connection.tasks.result(of: task.id) == .succeeded)
        try await Task.sleep(for: .seconds(2))
        await connection.refresh()
        let after = try #require(connection.snapshot)
        #expect(NodeBulkAction.start.eligibleGuests(on: nil, in: after).isEmpty)

        let log = try await connection.send(PVE.clusterLog(max: 20))
        #expect(log.contains { $0.message.contains("bulk-start") && $0.upid != nil })
        let report = try await connection.send(PVE.systemReport(node: after.nodes[0].name))
        #expect(report.contains("==== general system info ===="))
        let changelog = try await connection.send(PVE.packageChangelog(node: after.nodes[0].name, package: "pve-manager", version: "9.0.10"))
        #expect(changelog.hasPrefix("pve-manager (9.0.10)"))
    }
}
