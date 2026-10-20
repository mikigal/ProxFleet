import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct GuestDetailTests {
    /// A connected demo server signed in as `username`.
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

    private func vm(_ vmid: Int, on node: String = "pve1") -> GuestReference {
        GuestReference(node: node, vmid: vmid, kind: .virtualMachine)
    }

    @Test func loadsStatusConfigHistoryAndAddresses() async throws {
        let detail = GuestDetail(reference: vm(101), connection: try await connection())
        await detail.load()

        #expect(detail.hasLoaded)
        #expect(detail.loadError == nil)
        #expect(detail.name == "truenas")
        #expect(detail.powerState == .running)
        #expect(detail.config?.disks.map(\.key) == ["ide2", "scsi0"])
        #expect(detail.config?.disks.first?.isCDROM == true)
        #expect(!detail.history.isEmpty)
        #expect(detail.interfaces?.first?.addresses == ["10.0.20.103/24"])
        #expect(detail.privileges?.contains("VM.PowerMgmt") == true)
        #expect(detail.availableActions.first == .shutdown)
    }

    @Test func stoppedGuestHasNoAddressesAndCanOnlyStart() async throws {
        let detail = GuestDetail(reference: vm(102, on: "pve2"), connection: try await connection())
        await detail.load()
        #expect(detail.powerState == .stopped)
        #expect(detail.interfaces == nil)
        #expect(detail.availableActions == [.start])
    }

    @Test func pauseAndResumeAreTrackedUntilDone() async throws {
        let connection = try await connection()
        let detail = GuestDetail(reference: vm(100), connection: connection)
        await detail.load()

        await detail.perform(.pause)
        #expect(detail.actionError == nil)
        #expect(detail.powerState == .paused)
        #expect(detail.availableActions == [.resume, .stop])
        let task = try #require(connection.tasks.tasks.first)
        #expect(task.state == .succeeded)
        #expect(task.title == "VM 100 – Pause")
        #expect(detail.recentTasks.contains { $0.upid == task.id })

        await detail.perform(.resume)
        #expect(detail.powerState == .running)
        #expect(connection.tasks.runningTasks.isEmpty)
    }

    @Test func failedTaskReportsServerMessage() async throws {
        let connection = try await connection()
        let detail = GuestDetail(reference: vm(100), connection: connection)
        await detail.load()

        await detail.perform(.start)

        #expect(detail.actionError == "VM 100 already running")
        #expect(connection.tasks.tasks.first?.state == .failed("VM 100 already running"))
        #expect(connection.tasks.unreportedFailure == nil)
    }

    @Test func readOnlyUserGetsNoPowerActions() async throws {
        let detail = GuestDetail(reference: vm(100), connection: try await connection(username: "limited"))
        await detail.load()
        #expect(detail.powerState == .running)
        #expect(detail.availableActions.isEmpty)
    }

    @Test func taskCenterReportsFailuresStartedElsewhere() async throws {
        let connection = try await connection()
        let task = try await connection.perform(.stop, on: GuestReference(node: "pve2", vmid: 102, kind: .virtualMachine))
        #expect(connection.tasks.runningTask(forGuest: 102)?.id == task.id)
        let result = await connection.tasks.result(of: task.id)
        #expect(result == .failed("VM 102 not running"))
        #expect(connection.tasks.unreportedFailure?.id == task.id)
        connection.tasks.acknowledgeFailure()
        #expect(connection.tasks.unreportedFailure == nil)
    }
}
