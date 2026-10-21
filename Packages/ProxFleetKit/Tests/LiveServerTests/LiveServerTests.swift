import CryptoKit
import Foundation
import ProxmoxCore
import ProxmoxURLSession
import ProxmoxConsole
import PVEKit
import Synchronization
import Testing

/// Settings from the env file named by `PROXFLEET_TEST_SERVER_ENV` (see `Config/TestServer.example.env`).
/// Without it, every test in this file is skipped.
private struct LiveServer {
    var values: [String: String]

    static let current: LiveServer? = {
        guard let path = ProcessInfo.processInfo.environment["PROXFLEET_TEST_SERVER_ENV"],
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return LiveServer(values: values)
    }()

    var address: ServerAddress { ServerAddress(parsing: values["ADDRESS"] ?? "", defaultPort: 8006)! }

    subscript(key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
}

@Suite(.enabled(if: LiveServer.current != nil, "Set PROXFLEET_TEST_SERVER_ENV to run against a real server"), .serialized, .timeLimit(.minutes(1)))
struct LiveServerTests {
    private let server = LiveServer.current!

    /// Accepts the certificate the way a user would, and returns a session using it.
    private func trustedSession() async throws -> ProxmoxSession {
        let transport = URLSessionTransport()
        let probe = ProxmoxSession(address: server.address, transport: transport)
        do {
            _ = try await probe.sendUnauthenticated(ProxmoxAccess.realms())
        } catch ProxmoxError.untrustedCertificate(let certificate) {
            if let expected = server["FINGERPRINT"] {
                #expect(certificate.sha256Fingerprint == expected.uppercased())
            }
            transport.pin(certificate.sha256Fingerprint)
        }
        return ProxmoxSession(address: server.address, transport: transport)
    }

    @Test func selfSignedCertificateIsRejectedUntilPinned() async throws {
        let session = ProxmoxSession(address: server.address, transport: URLSessionTransport())
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.sendUnauthenticated(ProxmoxAccess.realms())
        }
        let realms = try await trustedSession().sendUnauthenticated(ProxmoxAccess.realms())
        #expect(realms.contains { $0.realm == "pam" })
    }

    @Test func passwordLoginRenewalAndSnapshot() async throws {
        let session = try await trustedSession()
        let outcome = try await session.login(username: try #require(server["USER"]), password: try #require(server["PASSWORD"]), realm: server["REALM"])
        guard case .authenticated(let ticket) = outcome else {
            Issue.record("expected a full ticket")
            return
        }
        #expect(ticket.username.contains("@"))

        // Tickets carry a timestamp in seconds, so a renewal in the same second may return the same ticket.
        let renewed = try await session.renewTicket()
        #expect(renewed.username == ticket.username)
        #expect(!renewed.csrfToken.isEmpty)

        let snapshot = try await session.fetchClusterSnapshot()
        #expect(!snapshot.nodes.isEmpty)
        #expect(snapshot.nodes.allSatisfy { $0.cpuCount > 0 })
        let version = try await session.send(PVE.version())
        #expect(!version.version.isEmpty)
    }

    @Test func wrongPasswordIsUnauthorized() async throws {
        let session = try await trustedSession()
        await #expect(throws: ProxmoxError.unauthorized("authentication failure")) {
            _ = try await session.login(username: try #require(server["USER"]), password: "not-the-password", realm: server["REALM"])
        }
    }

    @Test func apiErrorsCarryMessagesAndFieldErrors() async throws {
        let session = try await trustedSession()
        _ = try await session.login(username: try #require(server["USER"]), password: try #require(server["PASSWORD"]), realm: server["REALM"])
        let node = try #require(try await session.fetchClusterSnapshot().nodes.first?.name)

        do {
            _ = try await session.send(APIRequest<Nothing>(.get, "/nodes/\(node)/qemu/99999/status/current"))
            Issue.record("expected an error")
        } catch ProxmoxError.api(let status, let message, _) {
            #expect(status == 500)
            #expect(message?.contains("does not exist") == true)
        }

        do {
            _ = try await session.send(APIRequest<Nothing>(.put, "/nodes/\(node)/qemu/99999/config", parameters: ["memory": "abc"]))
            Issue.record("expected an error")
        } catch ProxmoxError.api(let status, _, let fieldErrors) {
            #expect(status == 400)
            #expect(fieldErrors["memory"] != nil)
        }
    }

    /// Pauses and resumes VM 102 from the seed script, and checks that a failing task reports its message.
    @Test func powerActionTasks() async throws {
        let session = try await trustedSession()
        _ = try await session.login(username: try #require(server["USER"]), password: try #require(server["PASSWORD"]), realm: server["REALM"])
        let node = try #require(try await session.fetchClusterSnapshot().nodes.first?.name)
        let vm = GuestReference(node: node, vmid: 102, kind: .virtualMachine)
        try #require(try await session.send(PVE.guestStatus(vm)).powerState == .running)

        func finish(_ upid: String) async throws -> TaskStatus {
            for _ in 0..<60 {
                let status = try await session.send(PVE.taskStatus(node: node, upid: upid))
                if !status.isRunning { return status }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw ProxmoxError.invalidResponse("task did not finish")
        }

        #expect(try await finish(try await session.send(PVE.powerAction(.pause, on: vm))).succeeded)
        #expect(try await session.send(PVE.guestStatus(vm)).powerState == .paused)
        #expect(try await finish(try await session.send(PVE.powerAction(.resume, on: vm))).succeeded)
        #expect(try await session.send(PVE.guestStatus(vm)).powerState == .running)

        let failed = try await finish(try await session.send(PVE.powerAction(.start, on: vm)))
        #expect(!failed.succeeded)
        #expect(failed.exitStatus == "VM 102 already running")

        let config = try await session.send(PVE.guestConfig(vm))
        #expect(config.name == "db-server")
        #expect(!config.disks.isEmpty)
        let history = try await session.send(PVE.guestRRD(vm, timeframe: .hour))
        #expect(!history.isEmpty)
        #expect(try await session.privileges(on: vm.aclPath).contains("VM.PowerMgmt"))
    }

    private func rootSession() async throws -> (ProxmoxSession, String) {
        let session = try await trustedSession()
        _ = try await session.login(username: try #require(server["USER"]), password: try #require(server["PASSWORD"]), realm: server["REALM"])
        let node = try #require(try await session.fetchClusterSnapshot().nodes.first?.name)
        return (session, node)
    }

    /// Container 200 from the seed script shows a login prompt on its console after Enter.
    @Test func containerTerminal() async throws {
        let (session, node) = try await rootSession()
        let terminal = try await TerminalConnection.open(.container(GuestReference(node: node, vmid: 200, kind: .container)), session: session)
        defer { terminal.close() }
        try await terminal.resize(columns: 80, rows: 24)
        try await Task.sleep(for: .seconds(1))
        try await terminal.send("\r")

        var text = ""
        for try await chunk in terminal.output {
            text += String(decoding: chunk, as: UTF8.self)
            if text.contains("login:") { break }
        }
        #expect(text.contains("login:"), "terminal output: \(text.suffix(300))")
    }

    @Test func nodeShell() async throws {
        let (session, node) = try await rootSession()
        let terminal = try await TerminalConnection.open(.node(node), session: session)
        defer { terminal.close() }
        try await terminal.resize(columns: 100, rows: 30)
        try await terminal.send("hostname; echo shell-$((6*7))\n")
        var text = ""
        let deadline = Date().addingTimeInterval(15)
        for try await chunk in terminal.output {
            text += String(decoding: chunk, as: UTF8.self)
            if text.contains("shell-42") || Date() > deadline { break }
        }
        #expect(text.contains("shell-42"), "shell output: \(text.suffix(300))")
    }

    /// VM 100 boots the Alpine ISO (see README). Connects, waits for a screen and types into it.
    @Test func vmConsole() async throws {
        let (session, node) = try await rootSession()
        let vm = GuestReference(node: node, vmid: 100, kind: .virtualMachine)
        try #require(try await session.send(PVE.guestStatus(vm)).powerState == .running)

        let client = try await VNCClient.open(vm, session: session)
        var updates = 0
        var sawPixels = false
        for try await event in client.events {
            if case .updated = event {
                updates += 1
                let framebuffer = await client.framebuffer
                sawPixels = framebuffer.pixels.contains { $0 != 0 }
                if updates == 1 {
                    await client.type("root\n")
                }
                if sawPixels && updates >= 2 { break }
            }
        }
        let framebuffer = await client.framebuffer
        print("VNC screen \(framebuffer.width)x\(framebuffer.height), name \(await client.name), updates \(updates)")
        #expect(framebuffer.width > 0 && framebuffer.height > 0)
        #expect(sawPixels)
        await client.close()
    }

    /// Edits VM 101 (stopped) and VM 102 (running) from the seed script and puts everything back.
    @Test func configEditing() async throws {
        let (session, node) = try await rootSession()
        func finish(_ upid: String?) async throws {
            guard let upid else { return }
            for _ in 0..<60 {
                if try await !session.send(PVE.taskStatus(node: node, upid: upid)).isRunning { return }
                try await Task.sleep(for: .milliseconds(500))
            }
        }

        // Stopped VM: a new network device applies directly.
        let stopped = GuestReference(node: node, vmid: 101, kind: .virtualMachine)
        var config = try await session.send(PVE.guestConfig(stopped))
        let key = try #require(config.nextFreeKey(prefix: "net", slots: 32))
        var nic = NetworkDeviceDraft()
        nic.vlanTag = 42
        var update = GuestConfigUpdate(digest: config.digest)
        update.set(key, nic.stringValue)
        try await finish(try await session.send(PVE.updateConfig(stopped, update)))
        config = try await session.send(PVE.guestConfig(stopped))
        #expect(config.networks.first { $0.key == key }?.vlanTag == "42")

        // The old digest is now outdated.
        var stale = GuestConfigUpdate(digest: update.digest)
        stale.set("description", "stale")
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.send(PVE.updateConfig(stopped, stale))
        }
        var removal = GuestConfigUpdate()
        removal.set(key, nil)
        try await finish(try await session.send(PVE.updateConfig(stopped, removal)))
        #expect(try await session.send(PVE.guestConfig(stopped)).networks.allSatisfy { $0.key != key })

        // Running VM: memory waits for a restart, and can be reverted.
        let running = GuestReference(node: node, vmid: 102, kind: .virtualMachine)
        let memory = try #require(try await session.send(PVE.guestConfig(running)).memoryMiB)
        var change = GuestConfigUpdate()
        change.set("memory", String(memory + 512))
        try await finish(try await session.send(PVE.updateConfig(running, change)))
        #expect(try await session.send(PVE.guestConfig(running)).memoryMiB == memory)
        let pending = try await session.send(PVE.pendingConfig(running)).first { $0.key == "memory" }
        #expect(pending?.pending == String(memory + 512))
        var revert = GuestConfigUpdate()
        revert.reverts = ["memory"]
        try await finish(try await session.send(PVE.updateConfig(running, revert)))
        #expect(try await session.send(PVE.pendingConfig(running)).allSatisfy { !$0.hasPendingChange })
    }

    /// Creates a Windows 11 VM and a container the way the creation forms do, checks them, and destroys them again.
    @Test func guestCreation() async throws {
        let (session, node) = try await rootSession()
        func finish(_ upid: String) async throws -> TaskStatus {
            for _ in 0..<80 {
                let status = try await session.send(PVE.taskStatus(node: node, upid: upid))
                if !status.isRunning { return status }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw ProxmoxError.invalidResponse("task did not finish")
        }
        func destroy(_ guest: GuestReference) async throws {
            let request = APIRequest<String>(.delete, guest.path, parameters: ["purge": true, "destroy-unreferenced-disks": true])
            #expect(try await finish(try await session.send(request)).succeeded)
        }

        do {
            _ = try await session.send(PVE.checkVMID(100))
            Issue.record("VM 100 should exist")
        } catch ProxmoxError.api(_, _, let fieldErrors) {
            #expect(fieldErrors["vmid"] != nil)
        }
        #expect(try await !session.send(PVE.applianceTemplates(node: node)).isEmpty)
        let storage = try #require(try await session.send(PVE.storages(node: node, content: "images")).first?.storage)
        let iso = try await session.send(PVE.storageContent(node: node, storage: "local", content: "iso")).first?.volumeID

        var vm = VMCreationDraft(node: node, vmid: try await session.send(PVE.nextVMID()).value)
        vm.name = "creation-test"
        vm.applyDefaults(for: "win11")
        vm.isoVolume = iso
        vm.disks[0].storage = storage
        vm.efiStorage = storage
        vm.tpmStorage = storage
        vm.disks[0].sizeGiB = 1
        vm.addDisk()
        vm.disks[1].bus = .scsi
        vm.disks[1].sizeGiB = 1
        vm.disks[1].options.includeInBackup = false
        // Options of the wizard's advanced mode.
        vm.startup.order = "5"
        vm.tags = ["creation-test"]
        vm.display = "virtio"
        vm.disks[0].options.cache = "writeback"
        vm.disks[0].options.includeInBackup = false
        vm.disks[0].options.limits = ["mbps_rd": "200"]
        vm.cpu.flags = ["aes": true]
        vm.cpu.limit = 1.5
        vm.cpu.units = "200"
        vm.memoryShares = "500"
        vm.allowKSM = false
        vm.networks[0].device.mtu = 1400
        vm.networks[0].device.queues = 2
        vm.networks[0].device.model = "virtio"
        vm.addNetworkDevice()
        vm.networks[1].device.vlanTag = 30
        #expect(vm.problems.isEmpty)
        let created = try await finish(try await session.send(PVE.createVM(vm)))
        #expect(created.succeeded, "\(created.exitStatus ?? "")")
        let vmReference = GuestReference(node: node, vmid: vm.vmid, kind: .virtualMachine)
        let vmConfig = try await session.send(PVE.guestConfig(vmReference))
        #expect(vmConfig.name == "creation-test")
        #expect(vmConfig.bios == "ovmf")
        #expect(vmConfig["efidisk0"] != nil && vmConfig["tpmstate0"] != nil && vmConfig["sata0"] != nil)
        #expect(vmConfig.bootOrder.first == "sata0")
        #expect(vmConfig["scsi0"]?.contains("size=1G") == true && vmConfig["scsi0"]?.contains("backup=0") == true)
        #expect(vmConfig["startup"] == "order=5")
        #expect(vmConfig["tags"] == "creation-test")
        #expect(vmConfig["vga"] == "virtio")
        #expect(vmConfig["sata0"]?.contains("cache=writeback") == true)
        #expect(vmConfig["sata0"]?.contains("backup=0") == true)
        #expect(vmConfig["sata0"]?.contains("mbps_rd=200") == true)
        #expect(vmConfig["cpu"] == "x86-64-v2-AES,flags=+aes")
        #expect(vmConfig["cpulimit"] == "1.5")
        #expect(vmConfig["shares"] == "500")
        #expect(vmConfig["allow-ksm"] == "0")
        #expect(vmConfig["net0"]?.contains("mtu=1400") == true && vmConfig["net0"]?.contains("queues=2") == true)
        #expect(vmConfig["net1"]?.hasPrefix("e1000e=") == true && vmConfig["net1"]?.contains("tag=30") == true)
        try await destroy(vmReference)

        let template = try #require(try await session.send(PVE.storageContent(node: node, storage: "local", content: "vztmpl")).first?.volumeID)
        let rootStorage = try #require(try await session.send(PVE.storages(node: node, content: "rootdir")).first?.storage)
        var container = ContainerCreationDraft(node: node, vmid: try await session.send(PVE.nextVMID()).value)
        container.hostname = "creation-test"
        container.template = template
        container.rootStorage = rootStorage
        container.rootSizeGiB = 1
        container.password = UUID().uuidString
        container.passwordConfirmation = container.password
        container.nameservers = "1.1.1.1"
        container.startAfterCreation = true
        container.tags = ["creation-test"]
        container.rootFS.mountOptions = ["noatime"]
        container.rootFS.replicate = false
        container.cpuLimit = 1
        container.cpuUnits = "50"
        container.networks[0].device.mtu = 1450
        container.networks[0].device.rateLimit = 10
        container.addNetworkDevice()
        container.networks[1].device.ipv4Mode = .none
        container.addMountPoint()
        container.mountPoints[0].sizeGiB = 1
        container.mountPoints[0].options.path = "/data"
        #expect(container.problems.isEmpty)
        let createdContainer = try await finish(try await session.send(PVE.createContainer(container)))
        #expect(createdContainer.succeeded, "\(createdContainer.exitStatus ?? "")")
        let containerReference = GuestReference(node: node, vmid: container.vmid, kind: .container)
        let containerConfig = try await session.send(PVE.guestConfig(containerReference))
        #expect(containerConfig.name == "creation-test")
        #expect(containerConfig.isUnprivileged)
        #expect(containerConfig["features"] == "nesting=1")
        #expect(containerConfig["tags"] == "creation-test")
        #expect(containerConfig["rootfs"]?.contains("mountoptions=noatime") == true)
        #expect(containerConfig["rootfs"]?.contains("replicate=0") == true)
        #expect(containerConfig["cpulimit"] == "1")
        #expect(containerConfig["cpuunits"] == "50")
        #expect(containerConfig["net0"]?.contains("mtu=1450") == true)
        #expect(containerConfig["net1"]?.contains("name=eth1") == true)
        #expect(containerConfig["mp0"]?.contains("mp=/data") == true && containerConfig["mp0"]?.contains("backup=1") == true)
        // The start runs as its own task after the creation, and takes longer with more interfaces.
        var isRunning = false
        for _ in 0..<40 where !isRunning {
            isRunning = try await session.send(PVE.guestStatus(containerReference)).powerState == .running
            if !isRunning { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(isRunning)
        _ = try await finish(try await session.send(PVE.powerAction(.stop, on: containerReference)))
        try await destroy(containerReference)
    }

    /// Snapshots of container 202, clones of template 9000 and container 202, conversion to a template and deletion.
    @Test func snapshotsClonesAndDeletion() async throws {
        let (session, node) = try await rootSession()
        func finish(_ upid: String?) async throws {
            guard let upid else { return }
            for _ in 0..<80 {
                let status = try await session.send(PVE.taskStatus(node: node, upid: upid))
                if !status.isRunning {
                    #expect(status.succeeded, "\(status.type): \(status.exitStatus ?? "")")
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw ProxmoxError.invalidResponse("task did not finish")
        }

        // Snapshots of a stopped container.
        let container = GuestReference(node: node, vmid: 202, kind: .container)
        let name = "live\(Int(Date().timeIntervalSince1970) % 100_000)"
        try await finish(try await session.send(PVE.createSnapshot(container, name: name, description: "from the live test", includeRAM: false)))
        var snapshots = try await session.send(PVE.snapshots(container))
        #expect(snapshots.first { $0.name == name }?.description == "from the live test")
        #expect(snapshots.first(where: \.isCurrent)?.parent == name)
        #expect(GuestSnapshot.tree(snapshots).last?.snapshot.isCurrent == true)
        try await finish(try await session.send(PVE.updateSnapshotDescription(container, name: name, description: "edited")))
        try await finish(try await session.send(PVE.rollbackSnapshot(container, name: name, start: false)))
        snapshots = try await session.send(PVE.snapshots(container))
        #expect(snapshots.first { $0.name == name }?.description == "edited")

        // A full clone from that snapshot, converted to a template, then deleted.
        var clone = CloneDraft(source: container, isTemplate: false, vmid: try await session.send(PVE.nextVMID()).value)
        clone.name = "clone-test"
        clone.snapshot = name
        try await finish(try await session.send(PVE.clone(clone)))
        let cloned = GuestReference(node: node, vmid: clone.vmid, kind: .container)
        #expect(try await session.send(PVE.guestConfig(cloned)).name == "clone-test")
        // Containers answer without a task ID and convert in the background.
        #expect(try await session.send(PVE.convertToTemplate(cloned)) == nil)
        var isTemplate = false
        for _ in 0..<40 where !isTemplate {
            try await Task.sleep(for: .milliseconds(500))
            isTemplate = try await session.send(PVE.guestConfig(cloned))["template"] == "1"
        }
        #expect(isTemplate)
        try await finish(try await session.send(PVE.destroy(cloned, purge: true, destroyUnreferencedDisks: true)))
        try await finish(try await session.send(PVE.deleteSnapshot(container, name: name)))
        #expect(try await session.send(PVE.snapshots(container)).allSatisfy { $0.name != name })

        // A linked clone of the VM template.
        let template = GuestReference(node: node, vmid: 9000, kind: .virtualMachine)
        var linked = CloneDraft(source: template, isTemplate: true, vmid: try await session.send(PVE.nextVMID()).value)
        linked.name = "linked-test"
        try await finish(try await session.send(PVE.clone(linked)))
        let linkedVM = GuestReference(node: node, vmid: linked.vmid, kind: .virtualMachine)
        #expect(try await session.send(PVE.guestConfig(linkedVM)).name == "linked-test")
        try await finish(try await session.send(PVE.destroy(linkedVM, purge: true, destroyUnreferencedDisks: true)))

        // A running guest cannot be deleted.
        do {
            _ = try await session.send(PVE.destroy(GuestReference(node: node, vmid: 100, kind: .virtualMachine), purge: false, destroyUnreferencedDisks: false))
            Issue.record("deleting a running VM should fail")
        } catch ProxmoxError.api(_, let message, _) {
            #expect(message?.contains("running") == true)
        }
    }

    /// Backs up container 202, edits and protects the backup, restores it as a new container and over that one,
    /// and removes everything again.
    @Test func backupAndRestore() async throws {
        let (session, node) = try await rootSession()
        func finish(_ upid: String?) async throws -> TaskStatus? {
            guard let upid else { return nil }
            for _ in 0..<100 {
                let status = try await session.send(PVE.taskStatus(node: node, upid: upid))
                if !status.isRunning { return status }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw ProxmoxError.invalidResponse("task did not finish")
        }

        let container = GuestReference(node: node, vmid: 202, kind: .container)
        let storage = try #require(try await session.send(PVE.storages(node: node, content: "backup")).first?.storage)
        var draft = BackupDraft(guest: container)
        draft.storage = storage
        draft.notes = "{{guestname}} live test"
        let before = Set(try await session.send(PVE.backups(node: node, storage: storage, vmid: 202)).map(\.volumeID))
        #expect(try await finish(try await session.send(PVE.backupNow(draft)))?.succeeded == true)
        let backup = try #require(try await session.send(PVE.backups(node: node, storage: storage, vmid: 202)).first { !before.contains($0.volumeID) })
        #expect(backup.notes == "backup-agent live test")
        #expect(backup.subtype == "lxc")

        try await _ = finish(try await session.send(PVE.updateBackup(node: node, volume: backup.volumeID, notes: "edited", isProtected: true)))
        let updated = try await session.send(PVE.backups(node: node, storage: storage, vmid: 202)).first { $0.volumeID == backup.volumeID }
        #expect(updated?.notes == "edited" && updated?.isProtected == true)
        // A protected backup cannot be deleted; the task fails.
        #expect(try await finish(try await session.send(PVE.deleteBackup(node: node, volume: backup.volumeID)))?.succeeded == false)
        try await _ = finish(try await session.send(PVE.updateBackup(node: node, volume: backup.volumeID, isProtected: false)))

        let configuration = try await session.send(PVE.backupConfiguration(node: node, volume: backup.volumeID))
        #expect(GuestConfig.displayLines(ofBackupConfiguration: configuration).contains("hostname: backup-agent"))

        // As a new container, then over that new container.
        let rootStorage = try #require(try await session.send(PVE.storages(node: node, content: "rootdir")).first?.storage)
        var restore = RestoreDraft(backup: backup, source: container)
        restore.overwrites = false
        restore.vmid = try await session.send(PVE.nextVMID()).value
        restore.storage = rootStorage
        restore.uniqueMACAddresses = true
        #expect(restore.problems.isEmpty)
        #expect(try await finish(try await session.send(PVE.restore(restore)))?.succeeded == true)
        let restored = GuestReference(node: node, vmid: restore.vmid, kind: .container)
        #expect(try await session.send(PVE.guestConfig(restored)).name == "backup-agent")
        var overwrite = RestoreDraft(backup: backup, source: restored)
        overwrite.storage = rootStorage
        #expect(try await finish(try await session.send(PVE.restore(overwrite)))?.succeeded == true)

        #expect(try await finish(try await session.send(PVE.destroy(restored, purge: true, destroyUnreferencedDisks: true)))?.succeeded == true)
        #expect(try await finish(try await session.send(PVE.deleteBackup(node: node, volume: backup.volumeID)))?.succeeded == true)
        #expect(try await session.send(PVE.backups(node: node, storage: storage, vmid: 202)).allSatisfy { $0.volumeID != backup.volumeID })
    }

    /// Status, history, services, packages, journal and tasks of the node, and a service restart.
    @Test func nodeDetails() async throws {
        let (session, node) = try await rootSession()
        let status = try await session.send(PVE.nodeStatus(node))
        #expect(status.pveVersion?.hasPrefix("9.") == true)
        #expect(status.memoryTotal > 0 && status.rootTotal > 0 && status.cpuCount > 0)
        #expect(status.loadAverage.count == 3)
        let history = try await session.send(PVE.nodeRRD(node, timeframe: .hour)).filter(\.hasData)
        #expect(history.contains { $0.loadAverage != nil && $0.memoryTotal != nil })

        let services = try await session.send(PVE.services(node: node))
        let chrony = try #require(services.first { $0.name == "chrony" })
        #expect(chrony.isRunning)
        let upid = try #require(try await session.send(PVE.serviceAction(node: node, service: "chrony", .restart)))
        var finished: TaskStatus?
        for _ in 0..<40 where finished == nil {
            try await Task.sleep(for: .milliseconds(500))
            let task = try await session.send(PVE.taskStatus(node: node, upid: upid))
            if !task.isRunning { finished = task }
        }
        #expect(finished?.succeeded == true)
        #expect(TaskDescription.title(type: finished?.type ?? "", objectID: finished?.objectID) == "chrony – Restart Service")

        // The journal answers compressed; URLSession unpacks it.
        let journal = NodeJournal.lines(try await session.send(PVE.journal(node: node, lastEntries: 20)))
        #expect(!journal.isEmpty && journal.allSatisfy { !$0.hasPrefix("s=") })
        #expect(try await !session.send(PVE.packageVersions(node: node)).isEmpty)
        _ = try await session.send(PVE.packageUpdates(node: node))
        #expect(try await !session.send(PVE.nodeTasks(node: node, limit: 5)).isEmpty)
    }

    /// DNS, hosts and time zone are written back unchanged; a port-less bridge is created, applied and removed again.
    @Test func nodeSystemAndNetwork() async throws {
        let (session, node) = try await rootSession()
        func finish(_ upid: String?) async throws -> TaskStatus? {
            guard let upid else { return nil }
            for _ in 0..<60 {
                let status = try await session.send(PVE.taskStatus(node: node, upid: upid))
                if !status.isRunning { return status }
                try await Task.sleep(for: .milliseconds(500))
            }
            return nil
        }

        let dns = try await session.send(PVE.nodeDNS(node))
        #expect(!dns.searchDomain.isEmpty && !dns.servers[0].isEmpty)
        _ = try await session.send(PVE.updateNodeDNS(node, dns))
        #expect(try await session.send(PVE.nodeDNS(node)) == dns)
        let hosts = try await session.send(PVE.nodeHosts(node))
        #expect(hosts.text.contains(node) && hosts.digest != nil)
        _ = try await session.send(PVE.updateNodeHosts(node, text: hosts.text, digest: hosts.digest))
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.send(PVE.updateNodeHosts(node, text: hosts.text, digest: "0000"))
        }
        let time = try await session.send(PVE.nodeTime(node))
        #expect(abs(time.time.timeIntervalSinceNow) < 120)
        _ = try await session.send(PVE.setNodeTimeZone(node, time.timeZone))

        let before = try await session.send(PVE.network(node: node))
        try #require(before.pendingChanges == nil, "the test server has unapplied network changes")
        let name = "vmbr97"
        var draft = NetworkInterfaceDraft(creating: .bridge, existing: before.interfaces)
        draft.name = name
        draft.comments = "ProxFleet live test"
        draft.vlanAware = true
        _ = try await session.send(PVE.createInterface(node: node, draft))
        let pending = try await session.send(PVE.network(node: node))
        #expect(pending.pendingChanges?.contains("+auto \(name)") == true)
        let created = try #require(pending.interfaces.first { $0.name == name })
        #expect(created.comments == "ProxFleet live test" && created.bridgeVLANAware && !created.isActive)

        var edit = NetworkInterfaceDraft(created)
        edit.vlanAware = false
        edit.mtu = "9000"
        _ = try await session.send(PVE.updateInterface(node: node, name: name, type: "bridge", edit.changes(from: NetworkInterfaceDraft(created))))
        let edited = try #require(try await session.send(PVE.network(node: node)).interfaces.first { $0.name == name })
        #expect(edited.mtu == 9000 && !edited.bridgeVLANAware && edited.bridgeVIDs == nil)

        #expect(try await finish(try await session.send(PVE.applyNetwork(node: node)))?.succeeded == true)
        let applied = try await session.send(PVE.network(node: node))
        #expect(applied.pendingChanges == nil)
        #expect(applied.interfaces.first { $0.name == name }?.isActive == true)

        _ = try await session.send(PVE.deleteInterface(node: node, name: name))
        #expect(try await finish(try await session.send(PVE.applyNetwork(node: node)))?.succeeded == true)
        let after = try await session.send(PVE.network(node: node))
        #expect(after.pendingChanges == nil && !after.interfaces.contains { $0.name == name })

        // Revert drops staged changes.
        _ = try await session.send(PVE.createInterface(node: node, draft))
        _ = try await session.send(PVE.revertNetwork(node: node))
        #expect(try await session.send(PVE.network(node: node)).pendingChanges == nil)
    }

    /// Disks, SMART and the storage panels. Read only: the test server has no spare disk.
    @Test func nodeDisks() async throws {
        let (session, node) = try await rootSession()
        let disks = try await session.send(PVE.disks(node: node))
        let grouped = NodeDisk.grouped(disks)
        let system = try #require(grouped.first)
        #expect(system.disk.size > 0 && system.disk.hasGPT)
        #expect(system.partitions.count >= 2 && system.partitions.allSatisfy { $0.parent == system.disk.path })
        let smart = try await session.send(PVE.smart(node: node, disk: system.disk.path))
        #expect(!smart.health.isEmpty)
        #expect(smart.text != nil || !smart.attributes.isEmpty)
        let groups = try await session.send(PVE.volumeGroups(node: node)).groups
        #expect(groups.first { $0.name == "pve" }?.physicalVolumes.isEmpty == false)
        #expect(try await session.send(PVE.thinPools(node: node)).contains { $0.name == "data" && $0.volumeGroup == "pve" })
        _ = try await session.send(PVE.zfsPools(node: node))
        _ = try await session.send(PVE.directoryMounts(node: node))
    }

    /// Spare disks for the storage tests: unused whole disks. The test server has three virtual ones of different
    /// sizes (8, 16 and 4 GiB); without them the storage tests fail early with a clear message.
    private func spareDisks(_ session: ProxmoxSession, node: String) async throws -> [NodeDisk] {
        try await session.send(PVE.disks(node: node)).filter { !$0.isPartition && $0.isUnused }.sorted { $0.path < $1.path }
    }

    private func finishTask(_ session: ProxmoxSession, node: String, _ upid: String?) async throws -> TaskStatus? {
        guard let upid else { return nil }
        for _ in 0..<60 {
            let status = try await session.send(PVE.taskStatus(node: node, upid: upid))
            if !status.isRunning { return status }
            try await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// GPT, wipe, refusals for the system disk, and a ZFS pool added as storage and removed with its disk wiped.
    @Test(.timeLimit(.minutes(2))) func zfsPoolOnSpareDisks() async throws {
        let (session, node) = try await rootSession()
        let spares = try await spareDisks(session, node: node)
        try #require(spares.count >= 2, "the test server has no spare disks")
        let system = try #require(try await session.send(PVE.disks(node: node)).first { !$0.isPartition && !$0.isUnused })
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.initializeGPT(node: node, disk: system.path)) }
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.wipeDisk(node: node, disk: system.path)) }

        let disk = spares[0]
        #expect(try await finishTask(session, node: node, try await session.send(PVE.initializeGPT(node: node, disk: disk.path)))?.succeeded == true)
        #expect(try await session.send(PVE.disks(node: node)).first { $0.path == disk.path }?.hasGPT == true)
        #expect(try await finishTask(session, node: node, try await session.send(PVE.wipeDisk(node: node, disk: disk.path)))?.succeeded == true)
        #expect(try await session.send(PVE.disks(node: node)).first { $0.path == disk.path }?.hasGPT == false)

        if Set(spares.prefix(2).map(\.size)).count > 1 {
            // The form refuses a mirror of different sizes, and so does zpool.
            var mirror = DiskStorageDraft(kind: .zfs)
            mirror.name = "pflive"
            mirror.raidLevel = "mirror"
            mirror.devices = spares.prefix(2).map(\.path)
            mirror.deviceSizes = Dictionary(uniqueKeysWithValues: spares.map { ($0.path, $0.size) })
            #expect(mirror.problems["devices"] != nil)
            #expect(try await finishTask(session, node: node, try await session.send(PVE.createDiskStorage(node: node, mirror)))?.succeeded == false)
        }

        var pool = DiskStorageDraft(kind: .zfs)
        pool.name = "pflive"
        pool.devices = [disk.path]
        pool.compression = "lz4"
        #expect(try await finishTask(session, node: node, try await session.send(PVE.createDiskStorage(node: node, pool)))?.succeeded == true)
        let created = try #require(try await session.send(PVE.zfsPools(node: node)).first { $0.name == "pflive" })
        #expect(created.isHealthy && created.size > 0)
        let status = try await session.send(PVE.zfsPoolStatus(node: node, name: "pflive"))
        #expect(status.state == "ONLINE" && status.errors == "No known data errors")
        #expect(status.devices.flatMap { $0.flattened() }.last?.device.displayName.hasSuffix("-part1") == true)
        // The disk shows as partitioned; its partitions are ZFS and ZFS reserved.
        let partitions = try await session.send(PVE.disks(node: node, includePartitions: true)).filter { $0.parent == disk.path }
        #expect(partitions.compactMap(\.usage).sorted() == ["ZFS", "ZFS reserved"])
        #expect(try await session.send(PVE.storages(node: node)).contains { $0.storage == "pflive" })

        let removal = PVE.deleteDiskStorage(node: node, kind: .zfs, name: "pflive", cleanupConfig: true, wipeDisks: true)
        #expect(try await finishTask(session, node: node, try await session.send(removal))?.succeeded == true)
        #expect(try await !session.send(PVE.zfsPools(node: node)).contains { $0.name == "pflive" })
        #expect(try await !session.send(PVE.storages(node: node)).contains { $0.storage == "pflive" })
        #expect(try await session.send(PVE.disks(node: node)).first { $0.path == disk.path }?.isUnused == true)
    }

    /// An LVM volume group, an LVM thin pool and a directory, each added as storage and removed with its disk wiped.
    @Test(.timeLimit(.minutes(3))) func lvmThinPoolAndDirectoryOnSpareDisks() async throws {
        let (session, node) = try await rootSession()
        let spares = try await spareDisks(session, node: node)
        try #require(spares.count >= 3, "the test server has no spare disks")

        func create(_ kind: DiskStorageKind, _ name: String, on disk: NodeDisk) async throws {
            var draft = DiskStorageDraft(kind: kind)
            draft.name = name
            draft.devices = [disk.path]
            #expect(draft.problems.isEmpty)
            #expect(try await finishTask(session, node: node, try await session.send(PVE.createDiskStorage(node: node, draft)))?.succeeded == true)
        }
        try await create(.lvm, "pflivevg", on: spares[0])
        try await create(.lvmThin, "pflivethin", on: spares[1])
        try await create(.directory, "pflivedir", on: spares[2])

        let groups = try await session.send(PVE.volumeGroups(node: node)).groups
        #expect(groups.first { $0.name == "pflivevg" }?.physicalVolumes.map(\.name) == [spares[0].path])
        #expect(groups.first { $0.name == "pflivethin" }?.volumeCount == 1)
        let thin = try #require(try await session.send(PVE.thinPools(node: node)).first { $0.name == "pflivethin" })
        #expect(thin.volumeGroup == "pflivethin" && thin.size > 0 && thin.metadataSize > 0)
        let mount = try #require(try await session.send(PVE.directoryMounts(node: node)).first { $0.name == "pflivedir" })
        #expect(mount.path == "/mnt/pve/pflivedir" && mount.fileSystem == "ext4")
        let disks = try await session.send(PVE.disks(node: node, includePartitions: true))
        #expect(disks.first { $0.path == spares[0].path }?.usage == "LVM")
        #expect(disks.contains { $0.parent == spares[2].path && $0.usage == "ext4" && $0.isMounted })
        let storages = try await session.send(PVE.storages(node: node)).map(\.storage)
        #expect(["pflivevg", "pflivethin", "pflivedir"].allSatisfy(storages.contains))

        func remove(_ kind: DiskStorageKind, _ name: String, volumeGroup: String? = nil) async throws {
            let request = PVE.deleteDiskStorage(node: node, kind: kind, name: name, volumeGroup: volumeGroup, cleanupConfig: true, wipeDisks: true)
            #expect(try await finishTask(session, node: node, try await session.send(request))?.succeeded == true)
        }
        try await remove(.lvm, "pflivevg")
        // Wiping the thin pool's disk removes its volume group too.
        try await remove(.lvmThin, "pflivethin", volumeGroup: "pflivethin")
        try await remove(.directory, "pflivedir")
        #expect(try await !session.send(PVE.volumeGroups(node: node)).groups.contains { $0.name.hasPrefix("pflive") })
        #expect(try await !session.send(PVE.directoryMounts(node: node)).contains { $0.name == "pflivedir" })
        #expect(try await spareDisks(session, node: node).count == spares.count)
        #expect(try await !session.send(PVE.storages(node: node)).contains { $0.storage.hasPrefix("pflive") })
    }

    /// Downloads a 2.5 MB ISO from the internet to `local`, uploads a generated one with a checksum, and deletes both.
    @Test func storageDownloadUploadAndDelete() async throws {
        let (session, node) = try await rootSession()
        let status = try await session.send(PVE.storageStatus(node: node, storage: "local"))
        #expect(status.isActive && status.contentTypes.contains(.iso))
        let disks = try await session.send(PVE.storageVolumes(node: node, storage: "local-lvm", content: .images))
        #expect(disks.contains { $0.vmid == 100 && $0.format == "raw" })

        var download = StorageFileDraft(content: .iso)
        download.url = "https://boot.netboot.xyz/ipxe/netboot.xyz.iso"
        let metadata = try await session.send(PVE.urlMetadata(node: node, url: download.url))
        #expect(metadata.fileName == "netboot.xyz.iso" && (metadata.size ?? 0) > 0)
        download.fileName = "proxfleet-live-download.iso"
        #expect(download.problems().isEmpty)
        #expect(try await finishTask(session, node: node, try await session.send(PVE.downloadURL(node: node, storage: "local", download)))?.succeeded == true)

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "source.iso")
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: file)
        var upload = StorageFileDraft(content: .iso)
        upload.fileName = "proxfleet-live-upload.iso"
        upload.checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let progress = Mutex<Int64>(0)
        let upid = try await session.upload(PVE.uploadFile(node: node, storage: "local", upload), fileField: "filename",
                                            fileName: upload.fileName, source: file) { sent, _ in progress.withLock { $0 = sent } }
        #expect(progress.withLock { $0 } > 3_000_000)
        #expect(try await finishTask(session, node: node, upid)?.succeeded == true)

        let isos = try await session.send(PVE.storageVolumes(node: node, storage: "local", content: .iso))
        #expect(isos.first { $0.fileName == "proxfleet-live-upload.iso" }?.size == 3_000_000)
        #expect(isos.contains { $0.fileName == "proxfleet-live-download.iso" })
        // A wrong checksum is refused once the upload arrived.
        upload.checksum = String(repeating: "0", count: 64)
        upload.fileName = "proxfleet-live-bad.iso"
        let bad = try await session.upload(PVE.uploadFile(node: node, storage: "local", upload), fileField: "filename",
                                           fileName: upload.fileName, source: file) { _, _ in }
        #expect(try await finishTask(session, node: node, bad)?.succeeded == false)

        for name in ["proxfleet-live-upload.iso", "proxfleet-live-download.iso"] {
            #expect(try await finishTask(session, node: node, try await session.send(PVE.deleteVolume(node: node, storage: "local", volume: "local:iso/\(name)")))?.succeeded == true)
        }
        #expect(try await !session.send(PVE.storageVolumes(node: node, storage: "local", content: .iso)).contains { $0.fileName.hasPrefix("proxfleet-live") })
    }

    /// A directory storage and an LVM storage on a volume group of a spare disk: created, changed and removed again.
    @Test(.timeLimit(.minutes(2))) func storageDefinitions() async throws {
        let (session, node) = try await rootSession()
        let configs = try await session.send(PVE.storageConfigs())
        #expect(configs.contains { $0.storage == "local" && $0.location == "/var/lib/vz" })
        try #require(!configs.contains { $0.storage.hasPrefix("pflive") }, "left over from an earlier run")

        var dir = StorageConfigDraft(type: .dir)
        dir.storage = "pflive-dir"
        dir.path = "/var/lib/vz/pflive"
        dir.content = ["iso", "backup"]
        dir.nodes = [node]
        dir.prune.counts = ["keep-last": "2"]
        _ = try await session.send(PVE.createStorage(dir))
        let created = try #require(try await session.send(PVE.storageConfig("pflive-dir")))
        let original = try #require(StorageConfigDraft(created))
        #expect(original.prune.serialized == "keep-last=2" && original.nodes == [node] && original.content == ["iso", "backup"])
        #expect(try await session.send(PVE.storageStatus(node: node, storage: "pflive-dir")).isActive)

        var edit = original
        edit.content = ["iso"]
        edit.nodes = []
        edit.isEnabled = false
        var update = edit.changes(from: original)
        update.digest = created.digest
        _ = try await session.send(PVE.updateStorage("pflive-dir", update))
        let changed = try await session.send(PVE.storageConfig("pflive-dir"))
        #expect(changed.isDisabled && changed.content == ["iso"] && changed.nodes.isEmpty && changed.values["prune-backups"] == nil)
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.updateStorage("pflive-dir", update)) }
        _ = try await session.send(PVE.deleteStorage("pflive-dir"))

        // LVM on a volume group created without a storage entry, found by the scan.
        let spare = try #require(try await spareDisks(session, node: node).first, "the test server has no spare disks")
        var group = DiskStorageDraft(kind: .lvm)
        group.name = "pflivevg"
        group.devices = [spare.path]
        group.addStorage = false
        #expect(try await finishTask(session, node: node, try await session.send(PVE.createDiskStorage(node: node, group)))?.succeeded == true)
        #expect(try await session.send(PVE.scanVolumeGroups(node: node)).contains { $0.name == "pflivevg" })
        var lvm = StorageConfigDraft(type: .lvm)
        lvm.storage = "pflive-lvm"
        lvm.volumeGroup = "pflivevg"
        lvm.isShared = false
        _ = try await session.send(PVE.createStorage(lvm))
        #expect(try await session.send(PVE.storageStatus(node: node, storage: "pflive-lvm")).contentTypes == [.images, .rootdir])
        _ = try await session.send(PVE.deleteStorage("pflive-lvm"))
        let removal = PVE.deleteDiskStorage(node: node, kind: .lvm, name: "pflivevg", cleanupConfig: false, wipeDisks: true)
        #expect(try await finishTask(session, node: node, try await session.send(removal))?.succeeded == true)
        #expect(try await !session.send(PVE.storageConfigs()).contains { $0.storage.hasPrefix("pflive") })
    }

    /// A backup job for container 202: created, analysed, changed, run now, and removed with its backup.
    @Test(.timeLimit(.minutes(2))) func backupJob() async throws {
        let (session, node) = try await rootSession()
        let before = try await session.send(PVE.backupJobs())
        try #require(!before.contains { $0.comment == "ProxFleet live test" }, "left over from an earlier run")
        #expect(try await session.send(PVE.scheduleRuns("mon..fri 21:00")).count == 3)
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.scheduleRuns("whenever")) }

        var draft = BackupJobDraft()
        draft.storage = "local"
        draft.schedule = "sat 03:15"
        draft.selectionMode = .guests
        draft.guests = [202]
        draft.backupMode = "stop"
        draft.comment = "ProxFleet live test"
        draft.notesTemplate = "{{guestname}} live"
        draft.customRetention = true
        draft.prune.counts = ["keep-last": "1"]
        _ = try await session.send(PVE.createBackupJob(draft))
        let job = try #require(try await session.send(PVE.backupJobs()).first { $0.comment == "ProxFleet live test" })
        #expect(job.selection == .guests([202]) && job.prune?.serialized == "keep-last=1" && job.nextRun != nil)
        #expect(try await !session.send(PVE.guestsWithoutBackupJob()).contains { $0.vmid == 202 })

        let original = BackupJobDraft(job)
        var edit = original
        edit.isEnabled = false
        edit.selectionMode = .exclude
        edit.guests = [100, 101, 102, 200, 201, 9000]
        _ = try await session.send(PVE.updateBackupJob(job.id, edit.changes(from: original)))
        let changed = try #require(try await session.send(PVE.backupJobs()).first { $0.id == job.id })
        // Disabled jobs still report their next run; the app does not show it for them.
        #expect(!changed.isEnabled && changed.selection == .all(excluding: [100, 101, 102, 200, 201, 9000]))

        let snapshot = try await session.fetchClusterSnapshot()
        let runs = changed.runNowRequests(in: snapshot)
        #expect(runs.map(\.node) == [node])
        let upid = try await session.send(runs[0].request)
        #expect(try await finishTask(session, node: node, upid)?.succeeded == true)
        let backups = try await session.send(PVE.backups(node: node, storage: "local", vmid: 202))
        let made = try #require(backups.first { $0.notes == "backup-agent live" })
        #expect(try await finishTask(session, node: node, try await session.send(PVE.deleteBackup(node: node, volume: made.volumeID)))?.succeeded == true)

        _ = try await session.send(PVE.deleteBackupJob(job.id))
        #expect(try await !session.send(PVE.backupJobs()).contains { $0.id == job.id })
    }

    /// A group, a user in it, a custom role, a permission and an API token: created, changed and removed again.
    @Test func usersAndPermissions() async throws {
        let (session, _) = try await rootSession()
        try #require(try await !session.send(PVE.users()).contains { $0.userid == "pflive@pve" }, "left over from an earlier run")
        let roles = try await session.send(PVE.roles())
        #expect(roles.contains { $0.roleid == "Administrator" && $0.isBuiltIn && $0.privileges.contains("Sys.Modify") })
        #expect(AccessRole.privilegesByArea(roles).contains { $0.area == "VM" })

        _ = try await session.send(PVE.createGroup("pflive-group", comment: "ProxFleet live test"))
        var draft = UserDraft()
        draft.name = "pflive"
        draft.password = "Live-test-\(UUID().uuidString.prefix(8))"
        draft.passwordConfirmation = draft.password
        draft.firstName = "Live"
        draft.groups = ["pflive-group"]
        draft.expires = Date(timeIntervalSinceNow: 86_400 * 30)
        #expect(draft.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createUser(draft))
        let user = try #require(try await session.send(PVE.users()).first { $0.userid == "pflive@pve" })
        #expect(user.groups == ["pflive-group"] && user.firstName == "Live" && user.expires != nil && user.realmType == "pve")
        #expect(try await session.send(PVE.groups()).first { $0.groupid == "pflive-group" }?.members == ["pflive@pve"])

        var edit = UserDraft(user)
        edit.firstName = ""
        edit.isEnabled = false
        edit.expires = nil
        _ = try await session.send(PVE.updateUser(user.userid, edit.changes(from: UserDraft(user))))
        let changed = try #require(try await session.send(PVE.users()).first { $0.userid == "pflive@pve" })
        #expect(changed.firstName == nil && !changed.isEnabled && changed.expires == nil)
        _ = try await session.send(PVE.changePassword(userid: user.userid, password: "Another-\(UUID().uuidString.prefix(8))", confirmation: nil))

        _ = try await session.send(PVE.createRole("PFLiveRole", privileges: ["VM.Audit"]))
        _ = try await session.send(PVE.updateRole("PFLiveRole", privileges: ["VM.Audit", "VM.Console"]))
        #expect(try await session.send(PVE.roles()).first { $0.roleid == "PFLiveRole" }?.privileges == ["VM.Audit", "VM.Console"])
        let permission = ACLEntry(path: "/vms/100", subject: .group, subjectID: "pflive-group", role: "PFLiveRole", propagates: false)
        _ = try await session.send(PVE.addPermission(permission))
        #expect(try await session.send(PVE.acl()).contains(permission))

        let token = try await session.send(PVE.createToken(userid: user.userid, tokenid: "live", comment: "test", separated: true, expires: nil))
        #expect(token.fullID == "pflive@pve!live" && token.secret.count == 36)
        let tokenPermission = ACLEntry(path: "/", subject: .token, subjectID: token.fullID, role: "PVEAuditor")
        _ = try await session.send(PVE.addPermission(tokenPermission))
        #expect(try await session.send(PVE.users()).first { $0.userid == "pflive@pve" }?.tokens.map(\.tokenid) == ["live"])

        _ = try await session.send(PVE.removePermission(tokenPermission))
        _ = try await session.send(PVE.deleteToken(userid: user.userid, tokenid: "live"))
        _ = try await session.send(PVE.removePermission(permission))
        #expect(try await !session.send(PVE.acl()).contains(permission))
        _ = try await session.send(PVE.deleteRole("PFLiveRole"))
        _ = try await session.send(PVE.deleteUser(user.userid))
        _ = try await session.send(PVE.deleteGroup("pflive-group"))
        #expect(try await !session.send(PVE.users()).contains { $0.userid == "pflive@pve" })
        #expect(try await !session.send(PVE.groups()).contains { $0.groupid == "pflive-group" })
    }

    /// Disables and enables the Ceph repository again, and reads the subscription.
    /// Aliases, an IP set, a security group and rules for the datacenter, a node and a guest: created, changed,
    /// moved and removed again. The datacenter firewall stays off, so nothing filters the test server's traffic.
    @Test(.timeLimit(.minutes(2))) func firewall() async throws {
        let (session, node) = try await rootSession()
        let guest = FirewallScope.guest(GuestReference(node: node, vmid: 100, kind: .virtualMachine))
        try #require(try await !session.send(PVE.firewallAliases(.datacenter)).contains { $0.name == "pflive-net" }, "left over from an earlier run")
        try #require(!(try await session.send(PVE.firewallOptions(.datacenter))).isEnabled(in: .datacenter), "the datacenter firewall must stay off")
        #expect(try await session.send(PVE.firewallMacros()).contains { $0.name == "SSH" && !$0.description.isEmpty })

        _ = try await session.send(PVE.createFirewallAlias(.datacenter, name: "pflive-net", cidr: "192.0.2.0/24", comment: "ProxFleet live test"))
        _ = try await session.send(PVE.saveFirewallIPSet(.datacenter, name: "pflive-set", comment: ""))
        _ = try await session.send(PVE.addFirewallIPSetEntry(.datacenter, set: "pflive-set", cidr: "pflive-net", comment: "", excluded: false))
        _ = try await session.send(PVE.addFirewallIPSetEntry(.datacenter, set: "pflive-set", cidr: "198.51.100.0/24", comment: "excluded", excluded: true))
        var entries = try await session.send(PVE.firewallIPSetEntries(.datacenter, set: "pflive-set"))
        #expect(entries.map(\.cidr).sorted() == ["198.51.100.0/24", "pflive-net"] && entries.first { $0.cidr == "198.51.100.0/24" }?.isExcluded == true)
        let network = try #require(entries.first { $0.cidr == "198.51.100.0/24" })
        _ = try await session.send(PVE.updateFirewallIPSetEntry(.datacenter, set: "pflive-set", cidr: network.cidr, comment: "", excluded: false, digest: network.digest))
        _ = try await session.send(PVE.deleteFirewallIPSetEntry(.datacenter, set: "pflive-set", cidr: network.cidr))
        entries = try await session.send(PVE.firewallIPSetEntries(.datacenter, set: "pflive-set"))
        #expect(entries.map(\.cidr) == ["pflive-net"])
        let references = try await session.send(PVE.firewallReferences(guest))
        #expect(references.contains { $0.reference == "+pflive-set" && $0.isIPSet && $0.scope == "dc" })

        _ = try await session.send(PVE.saveFirewallGroup(name: "pflive-grp", comment: "ProxFleet live test"))
        var groupRule = FirewallRuleDraft()
        groupRule.macro = "SSH"
        groupRule.source = "+pflive-set"
        _ = try await session.send(PVE.createFirewallRule(.group("pflive-grp"), groupRule))
        #expect(try await session.send(PVE.firewallRules(.group("pflive-grp"))).first?.macro == "SSH")

        // Two rules at the top of the datacenter's, in front of anything already there.
        let existing = try await session.send(PVE.firewallRules(.datacenter)).count
        var first = FirewallRuleDraft()
        first.proto = "tcp"
        first.destinationPort = "8006"
        first.source = "pflive-net"
        first.comment = "pflive web"
        first.isEnabled = false
        _ = try await session.send(PVE.createFirewallRule(.datacenter, first))
        var applyGroup = FirewallRuleDraft()
        applyGroup.type = "group"
        applyGroup.group = "pflive-grp"
        applyGroup.isEnabled = false
        applyGroup.comment = "pflive group"
        _ = try await session.send(PVE.createFirewallRule(.datacenter, applyGroup))
        var rules = try await session.send(PVE.firewallRules(.datacenter))
        #expect(rules.prefix(2).map(\.comment) == ["pflive group", "pflive web"] && rules.count == existing + 2)

        // moveto puts the rule in front of the one at that position.
        _ = try await session.send(PVE.moveFirewallRule(.datacenter, position: 0, to: 2, digest: rules[0].digest))
        rules = try await session.send(PVE.firewallRules(.datacenter))
        #expect(rules.prefix(2).map(\.comment) == ["pflive web", "pflive group"])
        let web = rules[0]
        var edit = FirewallRuleDraft(web)
        edit.macro = "HTTPS"
        edit.logLevel = "info"
        _ = try await session.send(PVE.updateFirewallRule(.datacenter, position: web.position, { var update = edit.changes(from: FirewallRuleDraft(web)); update.digest = web.digest; return update }()))
        rules = try await session.send(PVE.firewallRules(.datacenter))
        #expect(rules[0].macro == "HTTPS" && rules[0].proto == nil && rules[0].destinationPort == nil && rules[0].logLevel == "info")
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.deleteFirewallRule(.datacenter, position: 0, digest: web.digest)) }
        var invalid = FirewallRuleDraft()
        invalid.source = "pflive-missing"
        do {
            _ = try await session.send(PVE.createFirewallRule(.datacenter, invalid))
            Issue.record("a rule with an unknown alias was accepted")
        } catch ProxmoxError.api(_, _, let fields) {
            #expect(fields["source"]?.contains("no such alias") == true)
        }

        // Renaming the group updates the rule that applies it.
        let group = try #require(try await session.send(PVE.firewallGroups()).first { $0.name == "pflive-grp" })
        _ = try await session.send(PVE.saveFirewallGroup(name: "pflive-grp2", comment: group.comment ?? "", renaming: group.name))
        rules = try await session.send(PVE.firewallRules(.datacenter))
        #expect(rules[1].isGroup && rules[1].action == "pflive-grp2")

        // Node and guest: a rule and options, put back afterwards.
        var hostRule = FirewallRuleDraft()
        hostRule.type = "out"
        hostRule.action = "DROP"
        hostRule.destination = "pflive-net"
        hostRule.isEnabled = false
        hostRule.comment = "pflive host"
        _ = try await session.send(PVE.createFirewallRule(.node(node), hostRule))
        let hostRules = try await session.send(PVE.firewallRules(.node(node)))
        #expect(hostRules.first?.comment == "pflive host" && hostRules.first?.type == "out")
        let nodeOptions = try await session.send(PVE.firewallOptions(.node(node)))
        var nodeDraft = FirewallOptionsDraft(nodeOptions, scope: .node(node))
        let nodeOriginal = nodeDraft
        nodeDraft.values["log_level_in"] = "info"
        nodeDraft.setMembers("nf_conntrack_helpers", ["ftp"])
        var nodeUpdate = nodeDraft.changes(from: nodeOriginal)
        nodeUpdate.digest = nodeOptions.digest
        _ = try await session.send(PVE.updateFirewallOptions(.node(node), nodeUpdate))
        let changedNode = try await session.send(PVE.firewallOptions(.node(node)))
        #expect(changedNode.values["log_level_in"] == "info" && changedNode.values["nf_conntrack_helpers"] == "ftp")
        _ = try await session.send(PVE.updateFirewallOptions(.node(node), nodeOriginal.changes(from: FirewallOptionsDraft(changedNode, scope: .node(node)))))
        #expect(try await session.send(PVE.firewallOptions(.node(node))).values == nodeOptions.values)
        let log = try await session.send(PVE.firewallLog(.node(node), start: 0, limit: 1))
        #expect(log.lines.count <= 1)

        _ = try await session.send(PVE.createFirewallAlias(guest, name: "pflive-guest", cidr: "2001:db8::1", comment: ""))
        var guestRule = FirewallRuleDraft()
        guestRule.proto = "icmpv6"
        guestRule.icmpType = "echo-request"
        guestRule.destination = "pflive-guest"
        guestRule.interface = "net0"
        guestRule.isEnabled = false
        _ = try await session.send(PVE.createFirewallRule(guest, guestRule))
        let guestRules = try await session.send(PVE.firewallRules(guest))
        #expect(guestRules.first?.ipVersion == 6 && guestRules.first?.icmpType == "echo-request" && guestRules.first?.interface == "net0")
        let guestOptions = try await session.send(PVE.firewallOptions(guest))
        var guestDraft = FirewallOptionsDraft(guestOptions, scope: guest)
        let guestOriginal = guestDraft
        guestDraft.setFlag("ipfilter", true)
        guestDraft.values["policy_out"] = "DROP"
        _ = try await session.send(PVE.updateFirewallOptions(guest, guestDraft.changes(from: guestOriginal)))
        let changedGuest = try await session.send(PVE.firewallOptions(guest))
        #expect(changedGuest.values["ipfilter"] == "1" && changedGuest.values["policy_out"] == "DROP")
        _ = try await session.send(PVE.updateFirewallOptions(guest, guestOriginal.changes(from: FirewallOptionsDraft(changedGuest, scope: guest))))
        #expect(try await session.send(PVE.firewallOptions(guest)).values == guestOptions.values)

        // Clean up, newest first.
        _ = try await session.send(PVE.deleteFirewallRule(guest, position: 0, digest: nil))
        _ = try await session.send(PVE.deleteFirewallAlias(guest, name: "pflive-guest"))
        _ = try await session.send(PVE.deleteFirewallRule(.node(node), position: 0, digest: nil))
        _ = try await session.send(PVE.deleteFirewallRule(.datacenter, position: 1, digest: nil))
        _ = try await session.send(PVE.deleteFirewallRule(.datacenter, position: 0, digest: nil))
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.deleteFirewallGroup("pflive-grp2")) }
        _ = try await session.send(PVE.deleteFirewallRule(.group("pflive-grp2"), position: 0, digest: nil))
        _ = try await session.send(PVE.deleteFirewallGroup("pflive-grp2"))
        _ = try await session.send(PVE.deleteFirewallIPSet(.datacenter, name: "pflive-set"))
        _ = try await session.send(PVE.deleteFirewallAlias(.datacenter, name: "pflive-net"))
        #expect(try await session.send(PVE.firewallRules(.datacenter)).count == existing)
        #expect(try await !session.send(PVE.firewallGroups()).contains { $0.name.hasPrefix("pflive") })
        #expect(try await !session.send(PVE.firewallIPSets(.datacenter)).contains { $0.name == "pflive-set" })
        #expect(try await session.send(PVE.firewallRules(guest)).allSatisfy { $0.comment?.hasPrefix("pflive") != true })
    }

    @Test func repositories() async throws {
        let (session, node) = try await rootSession()
        let repositories = try await session.send(PVE.aptRepositories(node: node))
        #expect(repositories.hasEnabledProxmoxRepository)
        #expect(repositories.standardRepositories.contains { $0.handle == "no-subscription" && $0.isEnabled == true })
        #expect(repositories.repositories.contains { $0.origin == "Debian" })
        let ceph = try #require(repositories.repositories.first { $0.path.hasSuffix("ceph.sources") && $0.isEnabled })
        _ = try await session.send(PVE.setRepository(node: node, ceph, enabled: false, digest: repositories.digest))
        let disabled = try await session.send(PVE.aptRepositories(node: node))
        #expect(disabled.repositories.first { $0.id == ceph.id }?.isEnabled == false)
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.send(PVE.setRepository(node: node, ceph, enabled: true, digest: repositories.digest))
        }
        _ = try await session.send(PVE.setRepository(node: node, ceph, enabled: true, digest: disabled.digest))
        #expect(try await session.send(PVE.aptRepositories(node: node)).repositories.first { $0.id == ceph.id }?.isEnabled == true)
        #expect(try await !session.send(PVE.subscription(node: node)).status.isEmpty)
    }

    /// Uploads a throwaway self-signed certificate, keeps the connection by pinning the fingerprint the server
    /// reports, and goes back to the default certificate.
    @Test(.timeLimit(.minutes(2))) func customCertificate() async throws {
        let transport = URLSessionTransport()
        let session = ProxmoxSession(address: server.address, transport: transport)
        do {
            _ = try await session.sendUnauthenticated(ProxmoxAccess.realms())
        } catch ProxmoxError.untrustedCertificate(let certificate) {
            transport.pin(certificate.sha256Fingerprint)
        }
        _ = try await session.login(username: try #require(server["USER"]), password: try #require(server["PASSWORD"]), realm: server["REALM"])
        let node = try #require(try await session.fetchClusterSnapshot().nodes.first?.name)
        let before = try await session.send(PVE.certificates(node: node))
        try #require(!before.contains { $0.isCustom }, "the test server already has a custom certificate")
        let original = try #require(before.first { $0.fileName == "pve-ssl.pem" }?.fingerprint)

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let openssl = Process()
        openssl.executableURL = URL(filePath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=proxfleet-live-test",
                             "-keyout", directory.appending(path: "key.pem").path, "-out", directory.appending(path: "cert.pem").path]
        openssl.standardError = FileHandle.nullDevice
        try openssl.run()
        openssl.waitUntilExit()
        var draft = CustomCertificateDraft()
        draft.certificates = try String(contentsOf: directory.appending(path: "cert.pem"), encoding: .utf8)
        draft.key = try String(contentsOf: directory.appending(path: "key.pem"), encoding: .utf8)

        func certificatesAfterRestart() async throws -> [NodeCertificate] {
            for _ in 0..<15 {
                try await Task.sleep(for: .seconds(1))
                if let list = try? await session.send(PVE.certificates(node: node)) { return list }
            }
            return try await session.send(PVE.certificates(node: node))
        }

        let uploaded = try await session.send(PVE.uploadCertificate(node: node, draft))
        #expect(uploaded.isCustom && uploaded.commonName == "proxfleet-live-test")
        transport.pin(try #require(uploaded.fingerprint))
        #expect(try await certificatesAfterRestart().contains { $0.isCustom && $0.fingerprint == uploaded.fingerprint })

        transport.pin(original)
        _ = try await session.send(PVE.deleteCustomCertificate(node: node))
        #expect(try await !certificatesAfterRestart().contains { $0.isCustom })

        // pveproxy restarts gracefully: old workers keep serving the previous certificate for a while. The app
        // trusts both meanwhile; later tests need the original back on every connection.
        var stable = 0
        for _ in 0..<40 where stable < 5 {
            do {
                _ = try await ProxmoxSession(address: server.address, transport: URLSessionTransport()).sendUnauthenticated(ProxmoxAccess.realms())
            } catch ProxmoxError.untrustedCertificate(let certificate) {
                stable = certificate.sha256Fingerprint == original.uppercased() ? stable + 1 : 0
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(stable == 5)
    }

    @Test(.enabled(if: LiveServer.current?["LIMITED_USER"] != nil))
    func readOnlyUserLacksPowerManagement() async throws {
        let session = try await trustedSession()
        _ = try await session.login(username: try #require(server["LIMITED_USER"]), password: try #require(server["LIMITED_PASSWORD"]), realm: server["LIMITED_REALM"])
        let privileges = try await session.privileges(on: "/vms/100")
        #expect(privileges.contains("VM.Audit"))
        #expect(!privileges.contains("VM.PowerMgmt"))
    }

    @Test(.enabled(if: LiveServer.current?["TFA_TOTP_SECRET"] != nil))
    func totpSecondFactor() async throws {
        let session = try await trustedSession()
        let outcome = try await session.login(username: try #require(server["TFA_USER"]), password: try #require(server["TFA_PASSWORD"]), realm: server["TFA_REALM"])
        guard case .needsSecondFactor(let challenge) = outcome else {
            Issue.record("expected a second factor challenge")
            return
        }
        #expect(challenge.supportedMethods.contains(.totp))

        await #expect(throws: ProxmoxError.self) {
            _ = try await session.completeLogin(challenge, method: .totp, code: "000000")
        }
        let code = try TOTP.code(secret: try #require(server["TFA_TOTP_SECRET"]))
        let ticket = try await session.completeLogin(challenge, method: .totp, code: code)
        #expect(ticket.username.hasPrefix(server["TFA_USER"]! + "@"))
        _ = try await session.fetchClusterSnapshot()
    }
}

enum TOTP {
    static func code(secret: String, at date: Date = Date()) throws -> String {
        let key = SymmetricKey(data: try base32Decode(secret))
        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        let offset = Int(digest[19] & 0x0F)
        let value = (UInt32(digest[offset] & 0x7F) << 24) | (UInt32(digest[offset + 1]) << 16) | (UInt32(digest[offset + 2]) << 8) | UInt32(digest[offset + 3])
        return String(format: "%06u", value % 1_000_000)
    }

    private static func base32Decode(_ text: String) throws -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var buffer: UInt32 = 0
        var bytes: [UInt8] = []
        for character in text.uppercased() where character != "=" {
            guard let index = alphabet.firstIndex(of: character) else { throw ProxmoxError.invalidResponse("bad base32") }
            buffer = (buffer << 5) | UInt32(index)
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return Data(bytes)
    }
}
