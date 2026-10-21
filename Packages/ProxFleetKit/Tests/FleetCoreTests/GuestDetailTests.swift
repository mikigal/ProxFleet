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

    @Test func conflictMessagesAreRecognized() {
        for message in ["detected modified configuration - file changed by other user? Try again.", "checksum mismatch"] {
            #expect(ConfigUpdateError(ProxmoxError.api(status: 500, message: message, fieldErrors: [:])) == .conflict)
        }
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

    @Test func createsVMsAndContainers() async throws {
        let connection = try await connection()
        let vmid = try await connection.send(PVE.nextVMID()).value
        #expect(vmid == 106)
        // Node-level lists the forms need.
        #expect(try await connection.send(PVE.storages(node: "pve1", content: "images")).map(\.storage) == ["local-lvm"])
        #expect(try await !connection.send(PVE.bridges(node: "pve1")).isEmpty)
        #expect(try await connection.send(PVE.pools()).map(\.id) == ["lab"])

        var vm = VMCreationDraft(node: "pve1", vmid: 100)
        vm.diskStorage = "local-lvm"
        do {
            _ = try await connection.start(PVE.createVM(vm))
            Issue.record("VM 100 exists")
        } catch .invalid(_, let fields) {
            #expect(fields["vmid"] != nil)
        }

        vm.vmid = vmid
        vm.name = "fresh"
        vm.startAfterCreation = true
        let task = try await connection.start(PVE.createVM(vm))
        #expect(task.title == "VM \(vmid) – Create")
        #expect(await connection.tasks.result(of: task.id) == .succeeded)
        let detail = GuestDetail(reference: GuestReference(node: "pve1", vmid: vmid, kind: .virtualMachine), connection: connection)
        await detail.load()
        #expect(detail.name == "fresh")
        #expect(detail.powerState == .running)
        #expect(detail.config?["scsi0"] == "local-lvm:vm-\(vmid)-disk-0,discard=on,iothread=1,size=32G")
        #expect(detail.config?.bootOrder == ["scsi0", "net0"])

        // A downloaded template becomes available for a container.
        let download = try await connection.start(PVE.downloadTemplate(node: "pve1", storage: "local", template: "alpine-3.22-default_20250617_amd64.tar.xz"))
        #expect(await connection.tasks.result(of: download.id) == .succeeded)
        let templates = try await connection.send(PVE.storageContent(node: "pve1", storage: "local", content: "vztmpl"))
        #expect(templates.contains { $0.volumeID == "local:vztmpl/alpine-3.22-default_20250617_amd64.tar.xz" })

        var container = ContainerCreationDraft(node: "pve1", vmid: try await connection.send(PVE.nextVMID()).value)
        container.template = "local:vztmpl/alpine-3.22-default_20250617_amd64.tar.xz"
        container.rootStorage = "local-lvm"
        container.password = "secret"
        container.passwordConfirmation = "secret"
        let created = try await connection.start(PVE.createContainer(container))
        #expect(await connection.tasks.result(of: created.id) == .succeeded)
        let config = try await connection.send(PVE.guestConfig(GuestReference(node: "pve1", vmid: container.vmid, kind: .container)))
        #expect(config.osType == "alpine")
        #expect(config["rootfs"] == "local-lvm:vm-\(container.vmid)-disk-0,size=8G")
        #expect(config["password"] == nil)
        await connection.refresh()
        #expect(connection.snapshot?.containers.contains { $0.vmid == container.vmid && $0.state == .stopped } == true)
    }
}
