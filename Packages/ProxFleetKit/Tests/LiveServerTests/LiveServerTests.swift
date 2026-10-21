import CryptoKit
import Foundation
import ProxmoxCore
import ProxmoxURLSession
import ProxmoxConsole
import PVEKit
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
        vm.diskStorage = storage
        vm.efiStorage = storage
        vm.tpmStorage = storage
        vm.diskSizeGiB = 1
        #expect(vm.problems.isEmpty)
        let created = try await finish(try await session.send(PVE.createVM(vm)))
        #expect(created.succeeded, "\(created.exitStatus ?? "")")
        let vmReference = GuestReference(node: node, vmid: vm.vmid, kind: .virtualMachine)
        let vmConfig = try await session.send(PVE.guestConfig(vmReference))
        #expect(vmConfig.name == "creation-test")
        #expect(vmConfig.bios == "ovmf")
        #expect(vmConfig["efidisk0"] != nil && vmConfig["tpmstate0"] != nil && vmConfig["sata0"] != nil)
        #expect(vmConfig.bootOrder.first == "sata0")
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
        #expect(container.problems.isEmpty)
        let createdContainer = try await finish(try await session.send(PVE.createContainer(container)))
        #expect(createdContainer.succeeded, "\(createdContainer.exitStatus ?? "")")
        let containerReference = GuestReference(node: node, vmid: container.vmid, kind: .container)
        let containerConfig = try await session.send(PVE.guestConfig(containerReference))
        #expect(containerConfig.name == "creation-test")
        #expect(containerConfig.isUnprivileged)
        #expect(containerConfig["features"] == "nesting=1")
        #expect(try await session.send(PVE.guestStatus(containerReference)).powerState == .running)
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
