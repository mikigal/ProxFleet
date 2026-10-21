import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct NodeDetailTests {
    private func connection(username: String = "root") async throws -> ServerConnection {
        let transport = DemoTransport(cluster: .homelab)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: username, realm: "pve"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        try #require(connection.state == .connected)
        return connection
    }

    @Test func loadsStatusHistoryAndLists() async throws {
        let detail = NodeDetail(node: "pve1", connection: try await connection())
        await detail.load()
        let status = try #require(detail.status)
        #expect(status.cpuCount == 16 && status.memoryTotal > 0 && status.loadAverage.count == 3)
        #expect(status.pveVersion == "9.0.10")
        #expect(detail.history.contains { $0.loadAverage != nil })
        #expect(detail.can("Sys.PowerMgmt"))

        #expect(await detail.loadServices() == nil)
        #expect(detail.services?.first { $0.name == "pveproxy" }?.isRunning == true)
        #expect(await detail.loadUpdates() == nil)
        #expect(detail.updates?.map(\.package) == ["pve-manager", "proxmox-widget-toolkit"])
        #expect(detail.versions?.contains { $0.runningKernel != nil } == true)
        #expect(await detail.loadJournal(lastEntries: 20) == nil)
        #expect(detail.journal?.count == 20)
        #expect(detail.journal?.allSatisfy { $0.contains("pve1") } == true)
    }

    @Test func serviceActionsAndPackageRefreshAreTracked() async throws {
        let connection = try await connection()
        let detail = NodeDetail(node: "pve1", connection: connection)
        await detail.loadServices()
        let chrony = try #require(detail.services?.first { $0.name == "chrony" })
        try await detail.perform(.stop, on: chrony)
        #expect(detail.services?.first { $0.name == "chrony" }?.isRunning == false)
        try await detail.refreshPackageIndex()
        #expect(connection.tasks.tasks.first?.title == "Update Package Database")
        await detail.loadTasks()
        #expect(detail.tasks?.map(\.type).prefix(2) == ["aptupdate", "srvstop"])
    }

    @Test func rebootTakesTheNodeOffline() async throws {
        let connection = try await connection()
        let detail = NodeDetail(node: "pve2", connection: connection)
        try await detail.power(.reboot)
        await connection.refresh()
        #expect(connection.snapshot?.nodes.first { $0.name == "pve2" }?.isOnline == false)
        #expect(connection.snapshot?.guests.filter { $0.node == "pve2" }.allSatisfy { $0.state != .running } == true)
    }

    @Test func auditorCannotRestartServices() async throws {
        let detail = NodeDetail(node: "pve1", connection: try await connection(username: "auditor"))
        await detail.load()
        #expect(!detail.can("Sys.Modify"))
        await detail.loadServices()
        let cron = try #require(detail.services?.first { $0.name == "cron" })
        await #expect(throws: ConfigUpdateError.self) {
            try await detail.perform(.restart, on: cron)
        }
    }
}
