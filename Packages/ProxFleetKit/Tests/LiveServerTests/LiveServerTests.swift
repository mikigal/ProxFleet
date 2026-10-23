import CryptoKit
import Foundation
import ProxmoxCore
import ProxmoxURLSession
@testable import ProxmoxConsole
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

// The suite's limit caps every test, as Swift Testing applies the shorter limit; migration and replication need minutes.
@Suite(.enabled(if: LiveServer.current != nil, "Set PROXFLEET_TEST_SERVER_ENV to run against a real server"), .serialized, .timeLimit(.minutes(6)))
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

    /// The node at the address from the env file, which has the seeded guests and the spare disks, also in a cluster.
    private func connectedNode(_ session: ProxmoxSession) async throws -> String {
        try #require(try await session.fetchClusterSnapshot().nodes.first(where: \.isLocal)?.name)
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
        let node = try await connectedNode(session)

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
        let node = try await connectedNode(session)
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
        let node = try await connectedNode(session)
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

    /// VM 101 has no OS, so its UEFI firmware reports on the serial port that nothing boots; a key opens its Boot Manager.
    @Test func vmSerialConsole() async throws {
        let (session, node) = try await rootSession()
        let vm = GuestReference(node: node, vmid: 101, kind: .virtualMachine)
        try #require(try await session.send(PVE.guestConfig(vm)).values["serial0"] == nil, "VM 101 already has a serial port")
        var add = GuestConfigUpdate()
        add.set("serial0", "socket")
        _ = try await session.send(PVE.updateConfig(vm, add))
        #expect(try await finishTask(session, node: node, try await session.send(PVE.powerAction(.start, on: vm)))?.succeeded == true)

        var failure: (any Error)?
        do {
            let terminal = try await TerminalConnection.open(.serial(vm, port: "serial0"), session: session)
            defer { terminal.close() }
            // The firmware goes quiet while it waits for a key, so the output is read on the side.
            let text = Mutex("")
            let reader = Task {
                for try await chunk in terminal.output { text.withLock { $0 += String(decoding: chunk, as: UTF8.self) } }
            }
            defer { reader.cancel() }
            func wait(for marker: String, seconds: Double) async throws -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if text.withLock({ $0.contains(marker) }) { return true }
                    try await Task.sleep(for: .milliseconds(200))
                }
                return false
            }
            #expect(try await wait(for: "Press any key", seconds: 40), "serial output: \(text.withLock { $0.suffix(600) })")
            try await terminal.send("\r")
            #expect(try await wait(for: "Please select boot device", seconds: 10), "serial output: \(text.withLock { $0.suffix(600) })")
            #expect(text.withLock { $0.contains("starting serial terminal on interface serial0") })
        } catch {
            failure = error
        }
        #expect(try await finishTask(session, node: node, try await session.send(PVE.powerAction(.stop, on: vm)))?.succeeded == true)
        var remove = GuestConfigUpdate()
        remove.set("serial0", nil)
        _ = try await session.send(PVE.updateConfig(vm, remove))
        if let failure { throw failure }
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

    /// The same screen of VM 100 as Raw and as Tight, to see what the compression saves.
    @Test func vmConsoleCompression() async throws {
        let (session, node) = try await rootSession()
        let vm = GuestReference(node: node, vmid: 100, kind: .virtualMachine)
        try #require(try await session.send(PVE.guestStatus(vm)).powerState == .running)

        func firstScreen(_ encodings: [VNCClient.Encoding], quality: VNCClient.Quality) async throws -> (bytes: Int, pixels: [UInt8], client: VNCClient) {
            let client = try await VNCClient.open(vm, session: session, quality: quality, encodings: encodings)
            // The first update may only announce features; wait for pixels, then for the rest of the screen.
            for try await event in client.events {
                if case .updated = event, await client.rectangleCounts.keys.contains(where: { $0 >= 0 }) { break }
            }
            try await Task.sleep(for: .seconds(2))
            return (await client.receivedBytes, await client.framebuffer.pixels, client)
        }
        let raw = try await firstScreen([.raw], quality: .best)
        await raw.client.close()
        let tight = try await firstScreen([.tight, .hextile, .copyRect, .raw], quality: .best)
        print("VNC first screen: raw \(raw.bytes) bytes, tight \(tight.bytes) bytes; encodings \(await tight.client.rectangleCounts), tight types \(await tight.client.tightCompressionCounts), scancodes \(await tight.client.supportsScancodes)")
        #expect(await tight.client.rectangleCounts[VNCClient.Encoding.tight.rawValue] ?? 0 > 0)
        #expect(tight.bytes < raw.bytes / 4)
        // Lossless, apart from the blinking text cursor, which may differ between the two snapshots.
        var differing: [Int] = []
        for index in stride(from: 0, to: min(tight.pixels.count, raw.pixels.count), by: 4)
        where tight.pixels[index..<index + 3] != raw.pixels[index..<index + 3] {
            differing.append(index / 4)
        }
        let width = await tight.client.framebuffer.width
        let xs = differing.map { $0 % width }, ys = differing.map { $0 / width }
        print("VNC differing pixels: \(differing.count), x \(xs.min() ?? 0)...\(xs.max() ?? 0), y \(ys.min() ?? 0)...\(ys.max() ?? 0)")
        #expect(differing.count < 200, "Tight without JPEG is lossless")
        await tight.client.close()

        let lossy = try await firstScreen([.tight, .hextile, .copyRect, .raw], quality: .dataSaver)
        print("VNC first screen with JPEG allowed: \(lossy.bytes) bytes; tight types \(await lossy.client.tightCompressionCounts)")
        await lossy.client.close()
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

    /// Add Hard Disk with every option of the web interface's dialog on a chosen device number, then the disk is
    /// detached and its volume destroyed.
    @Test func addDiskWithAllOptions() async throws {
        let (session, node) = try await rootSession()
        let vm = GuestReference(node: node, vmid: 101, kind: .virtualMachine)
        func finish(_ upid: String?) async throws {
            #expect(try await finishTask(session, node: node, upid)?.succeeded != false)
        }
        try #require(try await session.send(PVE.guestConfig(vm))["sata3"] == nil, "sata3 of VM 101 is in use")

        var disk = NewVMDisk(bus: .sata, storage: "local-lvm")
        disk.sizeGiB = 1
        disk.options.cache = "writeback"
        disk.options.asyncIO = "native"
        disk.options.ssdEmulation = true
        disk.options.includeInBackup = false
        disk.options.replicate = false
        disk.options.limits = ["mbps_rd": "100", "iops_wr": "200", "iops_wr_max": "500"]
        var update = GuestConfigUpdate()
        update.set("sata3", disk.value)
        try await finish(try await session.send(PVE.updateConfig(vm, update)))

        var config = try await session.send(PVE.guestConfig(vm))
        let added = try #require(config.disks.first { $0.key == "sata3" })
        #expect(added.volume.hasPrefix("local-lvm:vm-101-disk-") && added.size == "1G")
        let options = DiskOptionsDraft(added)
        #expect(options.cache == "writeback" && options.asyncIO == "native" && options.ssdEmulation && options.discard)
        #expect(!options.includeInBackup && !options.replicate)
        #expect(options.limits == ["mbps_rd": "100", "iops_wr": "200", "iops_wr_max": "500"])

        var detach = GuestConfigUpdate()
        detach.set("sata3", nil)
        try await finish(try await session.send(PVE.updateConfig(vm, detach)))
        config = try await session.send(PVE.guestConfig(vm))
        let unused = try #require(config.disks.first { $0.isUnused && $0.volume == added.volume })
        var destroy = GuestConfigUpdate()
        destroy.set(unused.key, nil)
        try await finish(try await session.send(PVE.updateConfig(vm, destroy)))
        #expect(try await session.send(PVE.guestConfig(vm)).disks.allSatisfy { $0.volume != added.volume })
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
        restore.name = "restored-agent"
        restore.cores = 1
        restore.memoryMiB = 256
        restore.unprivileged = true
        #expect(restore.problems.isEmpty)
        #expect(try await finish(try await session.send(PVE.restore(restore)))?.succeeded == true)
        let restored = GuestReference(node: node, vmid: restore.vmid, kind: .container)
        let restoredConfig = try await session.send(PVE.guestConfig(restored))
        #expect(restoredConfig.name == "restored-agent" && restoredConfig["cores"] == "1" && restoredConfig["memory"] == "256" && restoredConfig.isUnprivileged)
        var overwrite = RestoreDraft(backup: backup, source: restored)
        overwrite.storage = rootStorage
        #expect(try await finish(try await session.send(PVE.restore(overwrite)))?.succeeded == true)

        #expect(try await finish(try await session.send(PVE.destroy(restored, purge: true, destroyUnreferencedDisks: true)))?.succeeded == true)
        #expect(try await finish(try await session.send(PVE.deleteBackup(node: node, volume: backup.volumeID)))?.succeeded == true)
        #expect(try await session.send(PVE.backups(node: node, storage: storage, vmid: 202)).allSatisfy { $0.volumeID != backup.volumeID })
    }

    /// Guest options found missing against the web interface: an emulated ARM VM with an imported disk and a physical
    /// CD/DVD drive, an EFI disk in qcow2, TPM 1.2, PCI ID overrides, container device passthrough, a qcow2 full clone
    /// and restore overrides. Uses a temporary directory storage for qcow2 images.
    @Test(.timeLimit(.minutes(5))) func guestHardwareOptions() async throws {
        let (session, node) = try await rootSession()
        func finish(_ upid: String?) async throws -> TaskStatus? { try await finishTask(session, node: node, upid) }
        func destroy(_ guest: GuestReference) async throws {
            #expect(try await finish(try await session.send(PVE.destroy(guest, purge: true, destroyUnreferencedDisks: true)))?.succeeded == true)
        }
        try #require(try await !session.send(PVE.storageConfigs()).contains { $0.storage == "pflive-images" }, "left over from an earlier run")

        // A small cloud image to import, kept for later runs.
        let image = "local:import/proxfleet-cirros.qcow2"
        if try await !session.send(PVE.storageContent(node: node, storage: "local", content: "import")).contains(where: { $0.volumeID == image }) {
            var download = StorageFileDraft(content: .import)
            download.url = "https://download.cirros-cloud.net/0.6.3/cirros-0.6.3-x86_64-disk.img"
            download.fileName = "proxfleet-cirros.qcow2"
            #expect(try await finish(try await session.send(PVE.downloadURL(node: node, storage: "local", download)))?.succeeded == true)
        }
        var directory = StorageConfigDraft(type: .dir)
        directory.storage = "pflive-images"
        directory.path = "/var/lib/vz/pflive-images"
        directory.content = ["images"]
        directory.nodes = [node]
        _ = try await session.send(PVE.createStorage(directory))
        let files = try #require(try await session.send(PVE.storages(node: node, content: "images")).first { $0.storage == "pflive-images" })
        #expect(files.preferredDiskFormat == "qcow2")

        var arm = VMCreationDraft(node: node, vmid: try await session.send(PVE.nextVMID()).value)
        arm.name = "arm-test"
        arm.setHostArchitecture(try #require(try await session.send(PVE.nodeStatus(node)).architecture))
        #expect(!arm.isARM)
        arm.setArchitecture("aarch64")
        arm.efiStorage = files.storage
        arm.efiFormat = files.preferredDiskFormat
        arm.disks[0].storage = "local-lvm"
        arm.disks[0].isImport = true
        arm.disks[0].importSource = image
        arm.isoVolume = GuestConfig.physicalCDROM
        arm.memoryMiB = 512
        arm.networks = []
        #expect(arm.problems.isEmpty)
        let created = try await finish(try await session.send(PVE.createVM(arm)))
        #expect(created?.succeeded == true, "\(created?.exitStatus ?? "")")
        let armVM = GuestReference(node: node, vmid: arm.vmid, kind: .virtualMachine)
        var config = try await session.send(PVE.guestConfig(armVM))
        #expect(config["arch"] == "aarch64" && config.bios == "ovmf" && config["machine"] == nil)
        #expect(config["efidisk0"]?.hasPrefix("pflive-images:\(arm.vmid)/vm-\(arm.vmid)-disk-0.qcow2") == true)
        #expect(config["scsi0"]?.contains("size=112M") == true && config["scsi0"]?.contains("import-from") == false)
        #expect(config["scsi2"] == "cdrom,media=cdrom")
        #expect(config.bootOrder == ["scsi0", "scsi2"])

        // The test server has no CD/DVD drive, so the emulated VM starts with an empty one.
        var eject = GuestConfigUpdate()
        eject.set("scsi2", GuestConfig.cdromValue(isoVolume: nil))
        _ = try await finish(try await session.send(PVE.updateConfig(armVM, eject)))
        #expect(try await finish(try await session.send(PVE.powerAction(.start, on: armVM)))?.succeeded == true)
        #expect(try await session.send(PVE.guestStatus(armVM)).powerState == .running)
        _ = try await finish(try await session.send(PVE.powerAction(.stop, on: armVM)))

        var clone = CloneDraft(source: armVM, isTemplate: false, vmid: try await session.send(PVE.nextVMID()).value)
        clone.storage = files.storage
        clone.format = "qcow2"
        #expect(try await finish(try await session.send(PVE.clone(clone)))?.succeeded == true)
        let cloned = GuestReference(node: node, vmid: clone.vmid, kind: .virtualMachine)
        let clonedDisk = try await session.send(PVE.guestConfig(cloned))["scsi0"] ?? ""
        #expect(clonedDisk.hasPrefix("pflive-images:\(clone.vmid)/vm-\(clone.vmid)-disk-") && clonedDisk.contains(".qcow2"))
        try await destroy(cloned)

        // A backup restored as a new VM with other settings.
        var backup = BackupDraft(guest: armVM)
        backup.storage = "local"
        backup.mode = .stop
        let before = Set(try await session.send(PVE.backups(node: node, storage: "local", vmid: arm.vmid)).map(\.volumeID))
        #expect(try await finish(try await session.send(PVE.backupNow(backup)))?.succeeded == true)
        let archive = try #require(try await session.send(PVE.backups(node: node, storage: "local", vmid: arm.vmid)).first { !before.contains($0.volumeID) })
        var restore = RestoreDraft(backup: archive, source: armVM)
        restore.overwrites = false
        restore.vmid = try await session.send(PVE.nextVMID()).value
        restore.storage = "local-lvm"
        restore.name = "arm-restored"
        restore.cores = 2
        restore.sockets = 2
        restore.memoryMiB = 768
        restore.bandwidthLimit = 50
        #expect(restore.problems.isEmpty)
        let restoring = try await finish(try await session.send(PVE.restore(restore)))
        #expect(restoring?.succeeded == true, "\(restoring?.exitStatus ?? "")")
        let restored = GuestReference(node: node, vmid: restore.vmid, kind: .virtualMachine)
        let restoredConfig = try await session.send(PVE.guestConfig(restored))
        #expect(restoredConfig.name == "arm-restored" && restoredConfig["cores"] == "2" && restoredConfig["sockets"] == "2" && restoredConfig["memory"] == "768")
        try await destroy(restored)
        #expect(try await finish(try await session.send(PVE.deleteBackup(node: node, volume: archive.volumeID)))?.succeeded == true)
        try await destroy(armVM)

        // TPM 1.2 and a PCI device that shows other IDs, on a VM that never starts.
        var x86 = VMCreationDraft(node: node, vmid: try await session.send(PVE.nextVMID()).value)
        x86.name = "pci-test"
        x86.machine = "q35"
        x86.addTPM = true
        x86.tpmStorage = "local-lvm"
        x86.tpmVersion = "v1.2"
        x86.disks = []
        x86.networks = []
        #expect(try await finish(try await session.send(PVE.createVM(x86)))?.succeeded == true)
        let pciVM = GuestReference(node: node, vmid: x86.vmid, kind: .virtualMachine)
        let device = try #require(try await session.send(PVE.pciDevices(node: node)).first { $0.deviceName != nil })
        var pci = PCIDeviceDraft()
        pci.host = device.id
        pci.pcie = true
        pci.vendorID = "0x8086"
        pci.deviceID = "0x10D3"
        pci.subVendorID = "0x1af4"
        pci.subDeviceID = "0x1100"
        #expect(pci.isComplete)
        var addPCI = GuestConfigUpdate()
        addPCI.set("hostpci0", pci.stringValue)
        _ = try await finish(try await session.send(PVE.updateConfig(pciVM, addPCI)))
        config = try await session.send(PVE.guestConfig(pciVM))
        #expect(config["tpmstate0"]?.contains("version=v1.2") == true)
        let stored = PCIDeviceDraft(try #require(config["hostpci0"]))
        #expect(stored.vendorID == "0x8086" && stored.deviceID == "0x10d3" && stored.subVendorID == "0x1af4" && stored.subDeviceID == "0x1100")
        #expect(try await session.send(PVE.mediatedDeviceTypes(node: node, device: device.id)).isEmpty)
        try await destroy(pciVM)
        _ = try await session.send(PVE.deleteStorage("pflive-images"))

        // Device passthrough into container 201; while it runs, the change waits for its restart.
        let container = GuestReference(node: node, vmid: 201, kind: .container)
        try #require(try await session.send(PVE.guestConfig(container)).containerDevices.isEmpty, "CT 201 already has devices")
        var passthrough = ContainerDeviceDraft()
        passthrough.path = "/dev/net/tun"
        passthrough.gid = 100
        passthrough.mode = "0660"
        passthrough.isReadOnly = true
        #expect(passthrough.problems.isEmpty)
        var addDevice = GuestConfigUpdate()
        addDevice.set("dev0", passthrough.stringValue)
        _ = try await finish(try await session.send(PVE.updateConfig(container, addDevice)))
        let devices = try await session.send(PVE.pendingConfig(container)).filter { $0.key == "dev0" }
        #expect(devices.first.flatMap { $0.pending ?? $0.value }.map(ContainerDeviceDraft.init) == passthrough)
        var removeDevice = GuestConfigUpdate()
        removeDevice.set("dev0", nil)
        _ = try await finish(try await session.send(PVE.updateConfig(container, removeDevice)))
        if try await session.send(PVE.pendingConfig(container)).contains(where: { $0.key == "dev0" && $0.isPendingDeletion }) {
            // A running container gets a device right away, but drops it only when it restarts.
            #expect(try await finish(try await session.send(PVE.powerAction(.reboot, on: container)))?.succeeded == true)
        }
        #expect(try await session.send(PVE.guestConfig(container)).containerDevices.isEmpty)
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

    /// A backup of VM 101 is stopped while it runs: the task fails with the interruption and leaves no backup behind.
    @Test func stoppingATask() async throws {
        let (session, node) = try await rootSession()
        var draft = BackupDraft(guest: GuestReference(node: node, vmid: 101, kind: .virtualMachine))
        draft.storage = "local"
        draft.compression = .none
        draft.notes = "ProxFleet stop test"
        let upid = try await session.send(PVE.backupNow(draft))
        try await Task.sleep(for: .seconds(2))
        try #require(try await session.send(PVE.taskStatus(node: node, upid: upid)).isRunning, "the backup finished before it could be stopped")
        _ = try await session.send(PVE.stopTask(node: node, upid: upid))
        let status = try #require(try await finishTask(session, node: node, upid))
        #expect(!status.succeeded)
        #expect(status.exitStatus == "interrupted by signal")
        #expect(try await !session.send(PVE.backups(node: node, storage: "local", vmid: 101)).contains { $0.notes == "ProxFleet stop test" })
    }

    /// Bulk start and shutdown of container 202, and a bulk hibernation of VM 102, which a start then resumes.
    @Test(.timeLimit(.minutes(3))) func bulkActions() async throws {
        let (session, node) = try await rootSession()
        let container = GuestReference(node: node, vmid: 202, kind: .container)
        let vm = GuestReference(node: node, vmid: 102, kind: .virtualMachine)
        // `/cluster/resources` lags behind by up to ten seconds, so states come from each guest.
        func state(_ guest: GuestReference) async throws -> PowerState {
            try await session.send(PVE.guestStatus(guest)).powerState
        }
        func run(_ request: APIRequest<String>) async throws -> TaskStatus? {
            let upid = try await session.send(request)
            for _ in 0..<240 {
                let status = try await session.send(PVE.taskStatus(node: node, upid: upid))
                if !status.isRunning { return status }
                try await Task.sleep(for: .milliseconds(500))
            }
            return nil
        }
        let initial = (try await state(container), try await state(vm))
        try #require(initial.0 == .stopped && initial.1 == .running, "guests 202 and 102 are not in their seed state")
        let snapshot = try await session.fetchClusterSnapshot()
        #expect(NodeBulkAction.start.eligibleGuests(on: node, in: snapshot).map(\.vmid) == [101, 202])
        #expect(!NodeBulkAction.hibernate.eligibleGuests(on: node, in: snapshot).contains { $0.kind == .container })

        let start = try #require(try await run(PVE.bulkAction(node: node, NodeBulkActionDraft(action: .start, vmids: [202]))))
        #expect(start.succeeded && start.type == "startall")
        #expect(try await state(container) == .running)

        var shutdown = NodeBulkActionDraft(action: .shutdown, vmids: [202])
        shutdown.timeout = 60
        shutdown.maxWorkers = 2
        #expect(try await run(PVE.bulkAction(node: node, shutdown))?.succeeded == true)
        #expect(try await state(container) == .stopped)

        let hibernate = try #require(try await run(PVE.bulkAction(node: node, NodeBulkActionDraft(action: .hibernate, vmids: [102]))))
        #expect(hibernate.succeeded && hibernate.type == "suspendall")
        let status = try await session.send(PVE.guestStatus(vm))
        #expect(status.powerState == .stopped && status.lock == "suspended")
        #expect(try await finishTask(session, node: node, try await session.send(PVE.powerAction(.start, on: vm)))?.succeeded == true)
        #expect(try await state(vm) == .running)
    }

    /// Notes and wake-on-LAN options are written, read back and removed; a stale digest is refused. A standalone node
    /// cannot wake itself.
    @Test func nodeNotesAndOptions() async throws {
        let (session, node) = try await rootSession()
        let before = try await session.send(PVE.nodeOptions(node))
        try #require(before.values.isEmpty, "the node already has notes or options")

        var draft = NodeOptionsDraft(before)
        draft.macAddress = "aa:bb:cc:dd:ee:01"
        draft.broadcastAddress = "10.10.100.255"
        draft.startDelay = "5"
        draft.location.latitude = "50.0647"
        draft.location.longitude = "19.945"
        draft.location.name = "Krakow"
        var update = draft.changes(from: NodeOptionsDraft(before))
        update.set("description", "ProxFleet **live** test")
        _ = try await session.send(PVE.updateNodeOptions(node, update))
        let saved = try await session.send(PVE.nodeOptions(node))
        #expect(saved.notes == "ProxFleet **live** test")
        #expect(saved.values["wakeonlan"] == "AA:BB:CC:DD:EE:01,broadcast-address=10.10.100.255")
        #expect(NodeOptionsDraft(saved).serialized() == draft.serialized())
        #expect(NodeOptionsDraft(saved).location.name == "Krakow")

        var stale = GuestConfigUpdate(digest: String(repeating: "0", count: 40))
        stale.set("startall-onboot-delay", "6")
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.updateNodeOptions(node, stale)) }
        var invalid = GuestConfigUpdate()
        invalid.set("wakeonlan", "nonsense")
        do {
            _ = try await session.send(PVE.updateNodeOptions(node, invalid))
            Issue.record("expected a validation error")
        } catch ProxmoxError.api(_, _, let fields) {
            #expect(fields["wakeonlan"] != nil)
        }
        do {
            _ = try await session.send(PVE.wakeOnLAN(node))
            Issue.record("expected the node to refuse waking itself")
        } catch ProxmoxError.api(_, let message, _) {
            #expect(message?.contains("cannot wake my self") == true)
        }

        var cleanup = GuestConfigUpdate(digest: saved.digest)
        for key in saved.values.keys { cleanup.set(key, nil) }
        _ = try await session.send(PVE.updateNodeOptions(node, cleanup))
        #expect(try await session.send(PVE.nodeOptions(node)).values.isEmpty)
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

    /// An OVS bridge without uplinks and an internal port with an address in a VLAN, applied to the node. Needs
    /// openvswitch-switch on the node.
    @Test(.timeLimit(.minutes(2))) func openVSwitch() async throws {
        let (session, node) = try await rootSession()
        let ovs = try await runOnNode(session, node: node, "dpkg-query -W -f='${Status}' openvswitch-switch")
        try #require(ovs.output.contains("install ok installed"), "install openvswitch-switch on the node")
        let before = try await session.send(PVE.network(node: node))
        try #require(before.pendingChanges == nil, "the test server has unapplied network changes")

        var bridge = NetworkInterfaceDraft(creating: .ovsBridge, existing: before.interfaces)
        bridge.name = "vmbr96"
        bridge.comments = "ProxFleet live test"
        _ = try await session.send(PVE.createInterface(node: node, bridge))
        var port = NetworkInterfaceDraft(creating: .ovsIntPort, existing: try await session.send(PVE.network(node: node)).interfaces)
        port.name = "pfovs96"
        port.cidr = "10.96.0.1/24"
        port.ovsTag = "96"
        #expect(port.ovsBridge == "vmbr96" && port.problems.isEmpty)
        _ = try await session.send(PVE.createInterface(node: node, port))
        let pending = try await session.send(PVE.network(node: node))
        #expect(pending.interfaces.first { $0.name == "vmbr96" }?.ovsPorts == ["pfovs96"])
        let created = try #require(pending.interfaces.first { $0.name == "pfovs96" })
        #expect(created.ovsBridge == "vmbr96" && created.ovsTag == 96 && created.cidr == "10.96.0.1/24")

        var edit = NetworkInterfaceDraft(created)
        edit.ovsOptions = "vlan_mode=access"
        _ = try await session.send(PVE.updateInterface(node: node, name: "pfovs96", type: "OVSIntPort", edit.changes(from: NetworkInterfaceDraft(created))))
        let edited = try #require(try await session.send(PVE.network(node: node)).interfaces.first { $0.name == "pfovs96" })
        #expect(edited.ovsOptions == "vlan_mode=access" && edited.ovsTag == 96)

        #expect(try await finishTask(session, node: node, try await session.send(PVE.applyNetwork(node: node)))?.succeeded == true)
        let applied = try await session.send(PVE.network(node: node))
        #expect(applied.pendingChanges == nil)
        #expect(applied.interfaces.first { $0.name == "pfovs96" }?.isActive == true)
        let switchState = try await runOnNode(session, node: node, "ovs-vsctl list-ports vmbr96; ip -color=never -br addr show pfovs96")
        #expect(switchState.output.contains("pfovs96") && switchState.output.contains("10.96.0.1/24"), "\(switchState.output)")

        _ = try await session.send(PVE.deleteInterface(node: node, name: "pfovs96"))
        #expect(try await session.send(PVE.network(node: node)).interfaces.first { $0.name == "vmbr96" }?.ovsPorts == [])
        _ = try await session.send(PVE.deleteInterface(node: node, name: "vmbr96"))
        #expect(try await finishTask(session, node: node, try await session.send(PVE.applyNetwork(node: node)))?.succeeded == true)
        let after = try await session.send(PVE.network(node: node))
        #expect(after.pendingChanges == nil && !after.interfaces.contains { $0.name == "vmbr96" || $0.name == "pfovs96" })
        #expect(try await runOnNode(session, node: node, "ovs-vsctl br-exists vmbr96").status == 2)
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

    private func finishTask(_ session: ProxmoxSession, node: String, _ upid: String?, timeout: TimeInterval = 30) async throws -> TaskStatus? {
        guard let upid else { return nil }
        for _ in 0..<Int(timeout * 2) {
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

    /// Storage features found missing against the web interface: usage history, decompressing downloads, OCI images,
    /// pruning, importing an OVA as a VM, and the RBD, ZFS over iSCSI and iSCSI storage types.
    @Test(.timeLimit(.minutes(5))) func storageContentAndTypes() async throws {
        let (session, node) = try await rootSession()
        func finish(_ upid: String?) async throws -> TaskStatus? { try await finishTask(session, node: node, upid) }
        try #require(try await !session.send(PVE.storageConfigs()).contains { $0.storage.hasPrefix("pflive") }, "left over from an earlier run")

        let history = try await session.send(PVE.storageRRD(node: node, storage: "local", timeframe: .hour))
        #expect(history.contains { ($0.storageTotal ?? 0) > 0 && ($0.storageUsed ?? 0) > 0 })

        // A gzip file saved decompressed under the ISO name.
        var iso = StorageFileDraft(content: .iso)
        iso.url = "https://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz"
        iso.applyQueriedName("proxfleet-live-hello.iso.gz")
        #expect(iso.fileName == "proxfleet-live-hello.iso" && iso.decompression == "gz")
        #expect(try await finish(try await session.send(PVE.downloadURL(node: node, storage: "local", iso)))?.succeeded == true)
        let decompressed = try #require(try await session.send(PVE.storageVolumes(node: node, storage: "local", content: .iso)).first { $0.fileName == "proxfleet-live-hello.iso" })
        // The archive is about 1 MiB compressed and several times that unpacked.
        #expect((decompressed.size ?? 0) > 3_000_000)
        #expect(try await finish(try await session.send(PVE.deleteVolume(node: node, storage: "local", volume: decompressed.volumeID)))?.succeeded == true)

        var oci = OCIPullDraft()
        oci.reference = "docker.io/library/alpine"
        let tags = try await session.send(PVE.ociTags(node: node, reference: oci.reference))
        #expect(tags.contains("latest"))
        oci.fileName = "proxfleet-live-alpine"
        #expect(oci.problems.isEmpty)
        #expect(try await finish(try await session.send(PVE.pullOCIImage(node: node, storage: "local", oci)))?.succeeded == true)
        let template = try #require(try await session.send(PVE.storageVolumes(node: node, storage: "local", content: .vztmpl)).first { $0.fileName.hasPrefix("proxfleet-live-alpine") })
        #expect(try await finish(try await session.send(PVE.deleteVolume(node: node, storage: "local", volume: template.volumeID)))?.succeeded == true)

        // Two backups of container 202; keeping the last one prunes the older.
        let container = GuestReference(node: node, vmid: 202, kind: .container)
        try #require(try await session.send(PVE.backups(node: node, storage: "local", vmid: 202)).isEmpty, "CT 202 has backups on local")
        var backup = BackupDraft(guest: container)
        backup.storage = "local"
        for _ in 0..<2 {
            #expect(try await finish(try await session.send(PVE.backupNow(backup)))?.succeeded == true)
            // Backups of the same second would share a name.
            try await Task.sleep(for: .seconds(1))
        }
        var keepLast = PruneOptions()
        keepLast.counts = ["keep-last": "1"]
        let preview = try await session.send(PVE.prunePreview(node: node, storage: "local", kind: .container, vmid: 202, options: keepLast))
        #expect(PruneCandidate.withKeepReasons(preview, options: keepLast).map(\.keepReason) == ["keep-last: 1", nil])
        #expect(try await finish(try await session.send(PVE.pruneBackups(node: node, storage: "local", kind: .container, vmid: 202, options: keepLast)))?.succeeded == true)
        let remaining = try await session.send(PVE.backups(node: node, storage: "local", vmid: 202))
        #expect(remaining.count == 1)
        for volume in remaining {
            _ = try await finish(try await session.send(PVE.deleteBackup(node: node, volume: volume.volumeID)))
        }

        // An OVA built from the CirrOS image, kept for later runs; its disks are extracted to a directory storage.
        let ova = "local:import/proxfleet-cirros.ova"
        if try await !session.send(PVE.storageVolumes(node: node, storage: "local", content: .import)).contains(where: { $0.volumeID == ova }) {
            let file = try await Self.makeCirrosOVA()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            var upload = StorageFileDraft(content: .import)
            upload.fileName = "proxfleet-cirros.ova"
            let upid = try await session.upload(PVE.uploadFile(node: node, storage: "local", upload), fileField: "filename", fileName: upload.fileName, source: file) { _, _ in }
            #expect(try await finish(upid)?.succeeded == true)
        }
        var directory = StorageConfigDraft(type: .dir)
        directory.storage = "pflive-work"
        directory.path = "/var/lib/vz/pflive-work"
        directory.content = ["images"]
        directory.preallocation = "off"
        _ = try await session.send(PVE.createStorage(directory))
        #expect(try await session.send(PVE.storageConfig("pflive-work")).values["preallocation"] == "off")
        var draft = GuestImportDraft(metadata: try await session.send(PVE.importMetadata(node: node, volume: ova)), node: node, volume: ova)
        #expect(draft.needsExtracting && draft.name == "proxfleet-cirros" && draft.disks.count == 1)
        draft.vmid = try await session.send(PVE.nextVMID()).value
        draft.defaultStorage = "local-lvm"
        draft.defaultBridge = "vmbr0"
        draft.workingStorage = "pflive-work"
        draft.uniqueMACAddresses = true
        let imported = try await finish(try await session.send(PVE.importGuest(draft)))
        #expect(imported?.succeeded == true, "\(imported?.exitStatus ?? "")")
        let vm = GuestReference(node: node, vmid: draft.vmid, kind: .virtualMachine)
        let config = try await session.send(PVE.guestConfig(vm))
        #expect(config.name == "proxfleet-cirros" && config["scsi0"]?.contains("size=112M") == true && config["net0"]?.hasPrefix("vmxnet3=") == true)
        #expect(try await finish(try await session.send(PVE.destroy(vm, purge: true, destroyUnreferencedDisks: true)))?.succeeded == true)
        _ = try await session.send(PVE.deleteStorage("pflive-work"))

        // Storage types whose servers do not exist: RBD and ZFS over iSCSI are stored as they are, iSCSI checks its portal.
        var rbd = StorageConfigDraft(type: .rbd)
        rbd.storage = "pflive-rbd"
        rbd.pool = "vms"
        rbd.usesClusterCeph = false
        rbd.monitors = "127.0.0.1"
        rbd.keyring = "[client.admin]\n\tkey = AQBpmGNnAAAAABAAZ6gpFzBsHtaE1q1Y4ZZ9vw=="
        rbd.usesKRBD = true
        rbd.isEnabled = false
        #expect(rbd.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createStorage(rbd))
        let storedRBD = try #require(StorageConfigDraft(try await session.send(PVE.storageConfig("pflive-rbd"))))
        #expect(!storedRBD.usesClusterCeph && storedRBD.usesKRBD && storedRBD.pool == "vms" && storedRBD.monitors == "127.0.0.1")
        var editedRBD = storedRBD
        editedRBD.monitors = "127.0.0.2 127.0.0.3"
        editedRBD.usesKRBD = false
        _ = try await session.send(PVE.updateStorage("pflive-rbd", editedRBD.changes(from: storedRBD)))
        let rbdAgain = try #require(StorageConfigDraft(try await session.send(PVE.storageConfig("pflive-rbd"))))
        #expect(rbdAgain.monitors == "127.0.0.2 127.0.0.3" && !rbdAgain.usesKRBD)
        _ = try await session.send(PVE.deleteStorage("pflive-rbd"))

        var zfs = StorageConfigDraft(type: .zfs)
        zfs.storage = "pflive-zfs"
        zfs.portal = "127.0.0.1"
        zfs.pool = "tank/pve"
        zfs.target = "iqn.2003-01.org.example:pve"
        zfs.iscsiProvider = .lio
        zfs.lioTargetPortalGroup = "tpg1"
        zfs.isEnabled = false
        _ = try await session.send(PVE.createStorage(zfs))
        let storedZFS = try #require(StorageConfigDraft(try await session.send(PVE.storageConfig("pflive-zfs"))))
        #expect(storedZFS.iscsiProvider == .lio && storedZFS.lioTargetPortalGroup == "tpg1" && storedZFS.blockSize == "4k" && storedZFS.content == ["images"])
        _ = try await session.send(PVE.deleteStorage("pflive-zfs"))

        var iscsi = StorageConfigDraft(type: .iscsi)
        iscsi.storage = "pflive-iscsi"
        iscsi.portal = "127.0.0.1"
        iscsi.target = "iqn.2003-01.org.example:san"
        do {
            _ = try await session.send(PVE.createStorage(iscsi))
            Issue.record("an iSCSI storage without a portal should be refused")
            _ = try? await session.send(PVE.deleteStorage("pflive-iscsi"))
        } catch ProxmoxError.api(_, let message, _) {
            #expect(message?.contains("not online") == true)
        }
        #expect(try await !session.send(PVE.storageConfigs()).contains { $0.storage.hasPrefix("pflive") })
    }

    /// An OVA with an OVF descriptor and the CirrOS disk, written as a ustar archive.
    private static func makeCirrosOVA() async throws -> URL {
        let (disk, _) = try await URLSession.shared.data(from: URL(string: "https://download.cirros-cloud.net/0.6.3/cirros-0.6.3-x86_64-disk.img")!)
        let ovf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" \
        xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" \
        xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
          <References><File ovf:href="cirros-disk1.qcow2" ovf:id="file1"/></References>
          <DiskSection><Info>Disks</Info><Disk ovf:capacity="117440512" ovf:diskId="vmdisk1" ovf:fileRef="file1" \
        ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/></DiskSection>
          <NetworkSection><Info>Networks</Info><Network ovf:name="VM Network"><Description>VM Network</Description></Network></NetworkSection>
          <VirtualSystem ovf:id="proxfleet-cirros"><Info>A virtual machine</Info><Name>proxfleet-cirros</Name>
            <OperatingSystemSection ovf:id="101"><Info>Guest OS</Info></OperatingSystemSection>
            <VirtualHardwareSection><Info>Virtual hardware</Info>
              <Item><rasd:ElementName>1 virtual CPU</rasd:ElementName><rasd:InstanceID>1</rasd:InstanceID><rasd:ResourceType>3</rasd:ResourceType><rasd:VirtualQuantity>1</rasd:VirtualQuantity></Item>
              <Item><rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits><rasd:ElementName>Memory</rasd:ElementName><rasd:InstanceID>2</rasd:InstanceID><rasd:ResourceType>4</rasd:ResourceType><rasd:VirtualQuantity>256</rasd:VirtualQuantity></Item>
              <Item><rasd:Address>0</rasd:Address><rasd:ElementName>SCSI Controller</rasd:ElementName><rasd:InstanceID>3</rasd:InstanceID><rasd:ResourceSubType>lsilogic</rasd:ResourceSubType><rasd:ResourceType>6</rasd:ResourceType></Item>
              <Item><rasd:AddressOnParent>0</rasd:AddressOnParent><rasd:ElementName>Hard Disk 1</rasd:ElementName><rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource><rasd:InstanceID>4</rasd:InstanceID><rasd:Parent>3</rasd:Parent><rasd:ResourceType>17</rasd:ResourceType></Item>
              <Item><rasd:AutomaticAllocation>true</rasd:AutomaticAllocation><rasd:Connection>VM Network</rasd:Connection><rasd:ElementName>Network adapter 1</rasd:ElementName><rasd:InstanceID>5</rasd:InstanceID><rasd:ResourceSubType>VmxNet3</rasd:ResourceSubType><rasd:ResourceType>10</rasd:ResourceType></Item>
            </VirtualHardwareSection>
          </VirtualSystem>
        </Envelope>
        """
        var archive = Data()
        for (name, contents) in [("cirros.ovf", Data(ovf.utf8)), ("cirros-disk1.qcow2", disk)] {
            var header = Data(count: 512)
            func put(_ text: String, at offset: Int) { header.replaceSubrange(offset..<offset + text.utf8.count, with: Data(text.utf8)) }
            put(name, at: 0)
            put("0000644\0", at: 100)
            put("0000000\0", at: 108)
            put("0000000\0", at: 116)
            put(String(format: "%011o\0", contents.count), at: 124)
            put(String(format: "%011o\0", Int(Date().timeIntervalSince1970)), at: 136)
            put("        ", at: 148)
            put("0", at: 156)
            put("ustar\0", at: 257)
            put("00", at: 263)
            let checksum = header.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o\0 ", checksum), at: 148)
            archive.append(header)
            archive.append(contents)
            archive.append(Data(count: (512 - contents.count % 512) % 512))
        }
        archive.append(Data(count: 1024))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "proxfleet-cirros.ova")
        try archive.write(to: file)
        return file
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
        // A job for all guests runs on every online node of a cluster; only this node's run is started.
        #expect(runs.map(\.node) == snapshot.nodes.filter(\.isOnline).map(\.name))
        let upid = try await session.send(try #require(runs.first { $0.node == node }).request)
        #expect(try await finishTask(session, node: node, upid)?.succeeded == true)
        let backups = try await session.send(PVE.backups(node: node, storage: "local", vmid: 202))
        let made = try #require(backups.first { $0.notes == "backup-agent live" })
        #expect(try await finishTask(session, node: node, try await session.send(PVE.deleteBackup(node: node, volume: made.volumeID)))?.succeeded == true)

        _ = try await session.send(PVE.deleteBackupJob(job.id))
        #expect(try await !session.send(PVE.backupJobs()).contains { $0.id == job.id })
    }

    /// A job with every advanced option of the web interface runs a fleecing backup of a VM; Backup Now prunes and
    /// mails with sendmail.
    @Test(.timeLimit(.minutes(3))) func backupJobAdvancedOptions() async throws {
        let (session, node) = try await rootSession()
        try #require(try await !session.send(PVE.backupJobs()).contains { $0.id == "pflive-job" }, "left over from an earlier run")
        var draft = BackupJobDraft()
        draft.jobID = "pflive-job"
        draft.storage = "local"
        draft.selectionMode = .guests
        draft.guests = [102]
        draft.isEnabled = false
        draft.bandwidthLimit = "512000"
        draft.zstdThreads = "0"
        draft.ioWorkers = "4"
        draft.fleecing = true
        draft.fleecingStorage = "local-lvm"
        draft.pbsChangeDetection = "metadata"
        draft.usesLegacySendmail = true
        draft.mailto = "root@pam"
        draft.mailNotification = "failure"
        draft.notesTemplate = "{{guestname}} pflive"
        #expect(draft.problems.isEmpty)
        _ = try await session.send(PVE.createBackupJob(draft))
        let job = try #require(try await session.send(PVE.backupJobs()).first { $0.id == "pflive-job" })
        let saved = BackupJobDraft(job)
        #expect(saved.ioWorkers == "4" && saved.fleecing && saved.fleecingStorage == "local-lvm" && saved.zstdThreads == "0")
        #expect(saved.bandwidthLimit == "512000" && saved.pbsChangeDetection == "metadata")
        #expect(saved.usesLegacySendmail && saved.mailto == "root@pam" && saved.mailNotification == "failure")
        #expect(saved.changes(from: saved).isEmpty)

        let volumes = try await session.send(PVE.backupJobVolumes("pflive-job"))
        let guest = try #require(volumes.guests.first)
        #expect(volumes.guests.count == 1 && guest.id == 102 && guest.type == "qemu")
        #expect(guest.volumes.contains { $0.key == "scsi0" && $0.isIncluded })

        let runs = job.runNowRequests(in: try await session.fetchClusterSnapshot())
        #expect(runs.first?.request.parameters["fleecing"] == "enabled=1,storage=local-lvm")
        let upid = try #require(try await session.send(runs[0].request))
        #expect(try await finishTask(session, node: node, upid)?.succeeded == true)
        let log = try await session.send(PVE.taskLog(node: node, upid: upid, start: 0, limit: 500)).map(\.text).joined(separator: "\n")
        #expect(log.contains("fleecing"), "\(log.suffix(1500))")
        let backup = try #require(try await session.send(PVE.backups(node: node, storage: "local", vmid: 102)).first { $0.notes == "db-server pflive" })
        #expect(try await finishTask(session, node: node, try await session.send(PVE.deleteBackup(node: node, volume: backup.volumeID)))?.succeeded == true)

        var edited = saved
        edited.fleecing = false
        edited.ioWorkers = ""
        edited.usesLegacySendmail = false
        _ = try await session.send(PVE.updateBackupJob(job.id, edited.changes(from: saved)))
        let changed = try #require(try await session.send(PVE.backupJobs()).first { $0.id == "pflive-job" })
        #expect(changed.fleecing.items.isEmpty && changed.performance.items.isEmpty && changed.notificationMode == "notification-system" && changed.mailto == nil)
        _ = try await session.send(PVE.deleteBackupJob(job.id))

        // Prune removes older backups by the storage's retention, here briefly the last one only.
        try #require(try await session.send(PVE.backups(node: node, storage: "local", vmid: 202)).isEmpty, "CT 202 has backups on local")
        var retention = GuestConfigUpdate()
        retention.set("prune-backups", "keep-last=1")
        _ = try await session.send(PVE.updateStorage("local", retention))
        var now = BackupDraft(guest: GuestReference(node: node, vmid: 202, kind: .container))
        now.storage = "local"
        now.mode = .stop
        now.notes = "pflive backup now"
        var failure: (any Error)?
        do {
            for prunes in [false, true] {
                // Archive names have seconds, so the second backup needs a new one.
                try await Task.sleep(for: .seconds(1.1))
                now.prunes = prunes
                now.usesLegacySendmail = prunes
                now.mailto = "root@pam"
                let task = try await session.send(PVE.backupNow(now))
                #expect(try await finishTask(session, node: node, task)?.succeeded == true)
                if prunes {
                    let log = try await session.send(PVE.taskLog(node: node, upid: task, start: 0, limit: 500)).map(\.text).joined(separator: "\n")
                    #expect(log.contains("prune older backups") && log.contains("notified via target `<root@pam>`"), "\(log.suffix(1200))")
                }
            }
        } catch {
            failure = error
        }
        var restore = GuestConfigUpdate()
        restore.set("prune-backups", nil)
        _ = try await session.send(PVE.updateStorage("local", restore))
        if let failure { throw failure }
        let made = try await session.send(PVE.backups(node: node, storage: "local", vmid: 202))
        #expect(made.count == 1)
        for backup in made {
            #expect(try await finishTask(session, node: node, try await session.send(PVE.deleteBackup(node: node, volume: backup.volumeID)))?.succeeded == true)
        }
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
        let node = try await connectedNode(session)
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

    /// Second factors of a temporary user, and a temporary LDAP realm that points nowhere.
    @Test func twoFactorAndRealms() async throws {
        let (session, node) = try await rootSession()
        let me = try #require(server["USER"]).contains("@") ? server["USER"]! : "\(server["USER"]!)@\(server["REALM"] ?? "pam")"
        let password = me == "root@pam" ? nil : server["PASSWORD"]
        let userid = "pflive2fa@pve"
        try #require(try await !session.send(PVE.users()).contains { $0.userid == userid }, "left over from an earlier run")
        try #require(try await !session.send(ProxmoxAccess.realms()).contains { $0.realm == "pflive" }, "left over from an earlier run")

        var user = UserDraft()
        user.name = "pflive2fa"
        user.password = "Live-test-\(UUID().uuidString.prefix(8))"
        _ = try await session.send(PVE.createUser(user))

        let secret = TOTPSecret.random(issuer: "ProxFleet live test", account: userid)
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.send(PVE.addTOTP(userid: userid, secret: secret, code: "000000", description: "Wrong", password: password))
        }
        _ = try await session.send(PVE.addTOTP(userid: userid, secret: secret, code: try TOTP.code(secret: secret.secret), description: "Phone", password: password))
        let keys = try await session.send(PVE.addRecoveryKeys(userid: userid, password: password)).recoveryKeys
        #expect(keys.count >= 4)
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.send(PVE.addRecoveryKeys(userid: userid, password: password))
        }
        var factors = try #require(try await session.send(PVE.twoFactors()).first { $0.userid == userid })
        #expect(factors.entries.map(\.type).sorted() == ["recovery", "totp"])
        #expect(factors.hasRecoveryKeys && !factors.isLocked())
        let totp = try #require(factors.entries.first { $0.type == "totp" })
        #expect(totp.description == "Phone" && totp.isEnabled)

        _ = try await session.send(PVE.updateTwoFactor(userid: userid, id: totp.id, description: "Old phone", isEnabled: false, password: password))
        factors = try #require(try await session.send(PVE.twoFactors()).first { $0.userid == userid })
        #expect(factors.entries.first { $0.id == totp.id }.map { ($0.description, $0.isEnabled) } ?? ("", true) == ("Old phone", false))
        _ = try await session.send(PVE.unlockTwoFactor(userid: userid))
        for entry in factors.entries {
            _ = try await session.send(PVE.deleteTwoFactor(userid: userid, id: entry.id, password: password))
        }
        #expect(try await session.send(PVE.twoFactors()).first { $0.userid == userid }?.entries.isEmpty ?? true)
        _ = try await session.send(PVE.deleteUser(userid))

        var realm = RealmDraft(type: .ldap)
        realm.realm = "pflive"
        realm.comment = "ProxFleet live test"
        realm.server1 = "ldap.invalid"
        realm.baseDN = "dc=example,dc=com"
        realm.userAttribute = "uid"
        realm.bindDN = "cn=reader,dc=example,dc=com"
        realm.password = "bind-secret"
        realm.emailAttribute = "mail"
        realm.twoFactor.kind = .oath
        realm.syncDefaults.scope = "users"
        realm.syncDefaults.removeVanished = [.acl, .entry]
        #expect(realm.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createRealm(realm))
        let config = try await session.send(PVE.realmConfig("pflive"))
        let saved = try #require(RealmDraft(realm: "pflive", config))
        #expect(saved.type == .ldap && saved.server1 == "ldap.invalid" && saved.emailAttribute == "mail" && saved.twoFactor.kind == .oath)
        #expect(saved.syncDefaults.scope == "users" && saved.syncDefaults.removeVanished == [.acl, .entry])
        #expect(saved.changes(from: saved).isEmpty)

        var edit = saved
        edit.comment = ""
        edit.mode = "ldaps"
        edit.twoFactor.kind = .none
        edit.sslVersion = "tlsv1_3"
        edit.caPath = "/etc/ssl/certs"
        edit.certificate = "/etc/pve/pflive.pem"
        edit.certificateKey = "/etc/pve/pflive.key"
        edit.groupDN = "ou=groups,dc=example,dc=com"
        var update = edit.changes(from: saved)
        update.digest = config.digest
        _ = try await session.send(PVE.updateRealm("pflive", update))
        let edited = try #require(RealmDraft(realm: "pflive", try await session.send(PVE.realmConfig("pflive"))))
        #expect(edited.comment.isEmpty && edited.mode == "ldaps" && edited.twoFactor.kind == .none)
        #expect(edited.sslVersion == "tlsv1_3" && edited.certificate == "/etc/pve/pflive.pem" && edited.groupDN == "ou=groups,dc=example,dc=com")
        #expect(edited.changes(from: edited).isEmpty)

        // A scheduled sync, changed and removed; Run Now syncs with the job's options.
        var job = RealmSyncJobDraft(realm: "pflive", defaults: edited.syncDefaults)
        job.id = "pflive-sync"
        job.schedule = "sun 03:00"
        job.comment = "ProxFleet live test"
        #expect(job.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createRealmSyncJob(id: "pflive-sync", job))
        let savedJob = try #require(try await session.send(PVE.realmSyncJobs()).first { $0.id == "pflive-sync" })
        #expect(savedJob.realm == "pflive" && savedJob.options.scope == "users" && savedJob.options.removeVanished == [.acl, .entry] && savedJob.nextRun != nil)
        #expect(RealmSyncJobDraft(savedJob) == job)
        var editedJob = RealmSyncJobDraft(savedJob)
        editedJob.isEnabled = false
        editedJob.comment = ""
        editedJob.options.removeVanished = []
        _ = try await session.send(PVE.updateRealmSyncJob(editedJob, editedJob.changes(from: RealmSyncJobDraft(savedJob))))
        let changedJob = try #require(try await session.send(PVE.realmSyncJobs()).first { $0.id == "pflive-sync" })
        #expect(!changedJob.isEnabled && changedJob.comment == nil && changedJob.options.removeVanished.isEmpty)
        _ = try await session.send(PVE.deleteRealmSyncJob("pflive-sync"))
        #expect(try await !session.send(PVE.realmSyncJobs()).contains { $0.id == "pflive-sync" })

        // The server is not reachable, so the sync starts and then fails.
        let upid = try await session.send(PVE.syncRealm("pflive", scope: "users", enableNew: true, removeVanished: [], dryRun: true))
        var status = try await session.send(PVE.taskStatus(node: node, upid: upid))
        for _ in 0..<40 where status.isRunning {
            try await Task.sleep(for: .milliseconds(500))
            status = try await session.send(PVE.taskStatus(node: node, upid: upid))
        }
        #expect(!status.isRunning && !status.succeeded)
        _ = try await session.send(PVE.deleteRealm("pflive"))
        #expect(try await !session.send(ProxmoxAccess.realms()).contains { $0.realm == "pflive" })
    }

    /// Graphite, InfluxDB over UDP and over HTTPS (disabled, as nothing listens), and OpenTelemetry against a
    /// small HTTP server on the node that accepts every POST, since Proxmox checks OTLP endpoints before saving.
    @Test(.timeLimit(.minutes(2))) func metricServers() async throws {
        let (session, node) = try await rootSession()
        try #require(try await !session.send(PVE.metricServers()).contains { $0.id.hasPrefix("pflive") }, "left over from an earlier run")

        var graphite = MetricServerDraft(type: .graphite)
        graphite.id = "pflive-graphite"
        graphite.server = "192.0.2.10"
        graphite.path = "proxfleet"
        graphite.graphiteProtocol = "tcp"
        graphite.timeout = "2"
        // Over TCP, Proxmox connects before saving unless the server is disabled.
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.createMetricServer(graphite)) }
        graphite.isEnabled = false
        _ = try await session.send(PVE.createMetricServer(graphite))
        var influxUDP = MetricServerDraft(type: .influxdb)
        influxUDP.id = "pflive-influxudp"
        influxUDP.server = "192.0.2.10"
        influxUDP.mtu = "1400"
        _ = try await session.send(PVE.createMetricServer(influxUDP))
        var influx = MetricServerDraft(type: .influxdb)
        influx.id = "pflive-influx"
        influx.server = "192.0.2.10"
        influx.port = "8086"
        influx.influxProtocol = "https"
        influx.organization = "lab"
        influx.bucket = "pve"
        influx.token = "secret-token"
        influx.verifiesCertificate = false
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.createMetricServer(influx)) }
        influx.isEnabled = false
        _ = try await session.send(PVE.createMetricServer(influx))

        let list = try await session.send(PVE.metricServers())
        #expect(Set(list.filter { $0.id.hasPrefix("pflive") }.map(\.id)) == ["pflive-graphite", "pflive-influxudp", "pflive-influx"])
        var savedGraphite = try #require(MetricServerDraft(try await session.send(PVE.metricServer("pflive-graphite"))))
        savedGraphite.id = "pflive-graphite"
        #expect(savedGraphite == graphite)
        var savedInflux = try #require(MetricServerDraft(try await session.send(PVE.metricServer("pflive-influx"))))
        savedInflux.id = "pflive-influx"
        var expected = influx
        expected.token = ""
        #expect(savedInflux == expected)
        var editedInflux = savedInflux
        editedInflux.bucket = ""
        editedInflux.port = "8087"
        _ = try await session.send(PVE.updateMetricServer(editedInflux, editedInflux.changes(from: savedInflux)))
        let changed = try await session.send(PVE.metricServer("pflive-influx"))
        #expect(changed.values["bucket"] == nil && changed.port == "8087" && changed.values["organization"] == "lab")

        // A throwaway OTLP endpoint on the node itself.
        let collector = try await runOnNode(session, node: node, """
            setsid nohup python3 -c 'import http.server as h
            class R(h.BaseHTTPRequestHandler):
                def do_POST(s):
                    s.rfile.read(int(s.headers.get("Content-Length") or 0)); s.send_response(200); s.end_headers()
            h.HTTPServer(("127.0.0.1", 14318), R).serve_forever()' >/dev/null 2>&1 < /dev/null & sleep 1; echo started
            """)
        #expect(collector.output.contains("started"))
        var otel = MetricServerDraft(type: .opentelemetry)
        otel.id = "pflive-otel"
        otel.server = "127.0.0.1"
        otel.port = "14318"
        otel.otelProtocol = "http"
        otel.otelHeaders = #"{"X-Test": "proxfleet"}"#
        otel.otelResourceAttributes = #"{"cluster": "lab"}"#
        otel.otelCompression = "none"
        otel.otelTimeout = "3"
        #expect(otel.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createMetricServer(otel))
        var savedOtel = try #require(MetricServerDraft(try await session.send(PVE.metricServer("pflive-otel"))))
        savedOtel.id = "pflive-otel"
        #expect(savedOtel == otel)
        _ = try await runOnNode(session, node: node, "pkill -f 'HTTPServer((\"127.0.0.1\", 14318)' ; true")

        for id in ["pflive-graphite", "pflive-influxudp", "pflive-influx", "pflive-otel"] {
            _ = try await session.send(PVE.deleteMetricServer(id))
        }
        #expect(try await !session.send(PVE.metricServers()).contains { $0.id.hasPrefix("pflive") })
    }

    /// Temporary notification endpoints and a matcher, and datacenter options changed and put back.
    @Test func notificationsAndDatacenterOptions() async throws {
        let (session, _) = try await rootSession()
        try #require(try await !session.send(PVE.notificationTargets()).contains { $0.name.hasPrefix("pflive") }, "left over from an earlier run")

        var mail = NotificationEndpointDraft(type: .sendmail)
        mail.name = "pflive-mail"
        mail.mailto = ["ops@example.com", "dev@example.com"]
        mail.comment = "ProxFleet live test"
        var smtp = NotificationEndpointDraft(type: .smtp)
        smtp.name = "pflive-smtp"
        smtp.server = "smtp.invalid"
        smtp.fromAddress = "pve@example.com"
        smtp.mailto = ["ops@example.com"]
        smtp.username = "pve"
        smtp.secret = "smtp-secret"
        var gotify = NotificationEndpointDraft(type: .gotify)
        gotify.name = "pflive-gotify"
        gotify.server = "https://gotify.invalid"
        gotify.secret = "token"
        var webhook = NotificationEndpointDraft(type: .webhook)
        webhook.name = "pflive-hook"
        webhook.url = "https://hooks.invalid/{{ secrets.path }}"
        webhook.body = #"{"text": "{{ title }}"}"#
        webhook.headers = [WebhookPair(name: "Content-Type", value: "application/json")]
        webhook.secrets = [WebhookPair(name: "path", value: "abc123")]
        for draft in [mail, smtp, gotify, webhook] {
            #expect(draft.problems(isNew: true).isEmpty, "\(draft.type)")
            _ = try await session.send(PVE.createNotificationEndpoint(draft))
        }
        let targets = try await session.send(PVE.notificationTargets())
        #expect(Set(targets.filter { $0.name.hasPrefix("pflive") }.map(\.type)) == ["sendmail", "smtp", "gotify", "webhook"])

        let mailConfig = try await session.send(PVE.notificationEndpoint(.sendmail, name: "pflive-mail"))
        let savedMail = NotificationEndpointDraft(type: .sendmail, name: "pflive-mail", mailConfig)
        #expect(savedMail.mailto == ["ops@example.com", "dev@example.com"] && savedMail.mailtoUsers == ["root@pam"])
        #expect(savedMail.changes(from: savedMail).isEmpty)
        var editedMail = savedMail
        editedMail.mailto = ["ops@example.com"]
        editedMail.mailtoUsers = ["root@pam"]
        editedMail.comment = ""
        _ = try await session.send(PVE.updateNotificationEndpoint(.sendmail, name: "pflive-mail", editedMail.changes(from: savedMail), digest: mailConfig.digest))
        let reread = NotificationEndpointDraft(type: .sendmail, name: "pflive-mail", try await session.send(PVE.notificationEndpoint(.sendmail, name: "pflive-mail")))
        #expect(reread.mailto == ["ops@example.com"] && reread.mailtoUsers == ["root@pam"] && reread.comment.isEmpty)

        let hookConfig = try await session.send(PVE.notificationEndpoint(.webhook, name: "pflive-hook"))
        var savedHook = NotificationEndpointDraft(type: .webhook, name: "pflive-hook", hookConfig)
        #expect(savedHook.body == webhook.body && savedHook.headers.first?.value == "application/json")
        #expect(savedHook.secrets.map(\.name) == ["path"] && savedHook.secrets.first?.isStored == true)
        // Changing a header keeps the stored secret, which is sent by name only.
        let original = savedHook
        savedHook.headers.append(WebhookPair(name: "X-Source", value: "pve"))
        _ = try await session.send(PVE.updateNotificationEndpoint(.webhook, name: "pflive-hook", savedHook.changes(from: original), digest: hookConfig.digest))
        let hookAfter = NotificationEndpointDraft(type: .webhook, name: "pflive-hook", try await session.send(PVE.notificationEndpoint(.webhook, name: "pflive-hook")))
        #expect(hookAfter.headers.count == 2 && hookAfter.secrets.map(\.name) == ["path"])

        var matcher = NotificationMatcherDraft()
        matcher.name = "pflive-matcher"
        matcher.targets = ["pflive-mail", "pflive-hook"]
        matcher.severities = [.warning, .error]
        matcher.fields = [MatcherFieldRule(field: "type", value: "vzdump"), MatcherFieldRule(isRegex: true, field: "hostname", value: "^pve")]
        matcher.calendars = ["mon..fri 8-17"]
        matcher.matchesAll = false
        #expect(matcher.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createNotificationMatcher(matcher))
        let savedMatcher = try #require(try await session.send(PVE.notificationMatchers()).first { $0.name == "pflive-matcher" })
        let matcherDraft = NotificationMatcherDraft(savedMatcher)
        #expect(matcherDraft.targets == ["pflive-mail", "pflive-hook"] && matcherDraft.severities == [.warning, .error])
        #expect(matcherDraft.fields == matcher.fields && matcherDraft.calendars == ["mon..fri 8-17"] && !matcherDraft.matchesAll)
        #expect(matcherDraft.changes(from: matcherDraft).isEmpty)
        var editedMatcher = matcherDraft
        editedMatcher.calendars = []
        editedMatcher.targets = ["pflive-mail"]
        _ = try await session.send(PVE.updateNotificationMatcher("pflive-matcher", editedMatcher.changes(from: matcherDraft), digest: nil))
        let matcherAfter = NotificationMatcherDraft(try #require(try await session.send(PVE.notificationMatchers()).first { $0.name == "pflive-matcher" }))
        #expect(matcherAfter.calendars.isEmpty && matcherAfter.targets == ["pflive-mail"])
        #expect(try await session.send(PVE.matcherFieldValues()).contains { $0.field == "type" && $0.value == "vzdump" })

        // Sending through an unreachable server fails, but the request itself is valid.
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.testNotificationTarget("pflive-gotify")) }

        _ = try await session.send(PVE.deleteNotificationMatcher("pflive-matcher"))
        for draft in [mail, smtp, gotify, webhook] {
            _ = try await session.send(PVE.deleteNotificationEndpoint(draft.type, name: draft.name))
        }
        #expect(try await !session.send(PVE.notificationTargets()).contains { $0.name.hasPrefix("pflive") })

        let optionsConfig = try await session.send(PVE.datacenterOptions())
        let options = DatacenterOptionsDraft(optionsConfig)
        #expect(options.changes(from: options).isEmpty)
        var edited = options
        edited.tagShape = "dense"
        edited.tagOrdering = "config"
        edited.bandwidthLimits["restore"] = "102400"
        edited.nextIDLower = "1000"
        edited.migrationType = "insecure"
        edited.haShutdownPolicy = "migrate"
        edited.emailFrom = "pve@example.com"
        #expect(edited.problems.isEmpty)
        _ = try await session.send(PVE.updateDatacenterOptions(edited.changes(from: options)))
        let saved = DatacenterOptionsDraft(try await session.send(PVE.datacenterOptions()))
        print("Datacenter options after edit: \(try await session.send(PVE.datacenterOptions()).values)")
        #expect(saved.tagShape == "dense" && saved.tagOrdering == "config" && saved.bandwidthLimits["restore"] == "102400")
        #expect(saved.nextIDLower == "1000" && saved.migrationType == "insecure" && saved.haShutdownPolicy == "migrate" && saved.emailFrom == "pve@example.com")
        #expect(saved.changes(from: saved).isEmpty)
        _ = try await session.send(PVE.updateDatacenterOptions(options.changes(from: saved)))
        #expect(DatacenterOptionsDraft(try await session.send(PVE.datacenterOptions())) == options)
    }

    /// A pool with a nested pool, guests moved between pools, a storage and a permission on the pool.
    @Test func pools() async throws {
        let (session, _) = try await rootSession()
        try #require(try await !session.send(PVE.pools()).contains { $0.id.hasPrefix("pflive") }, "left over from an earlier run")
        _ = try await session.send(PVE.createPool("pflive", comment: "ProxFleet live test"))
        _ = try await session.send(PVE.createPool("pflive/inner", comment: nil))
        _ = try await session.send(PVE.createPool("pflive-other", comment: nil))
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.createPool("pfmissing/inner", comment: nil)) }

        _ = try await session.send(PVE.addPoolMembers("pflive-other", guests: [202], storages: [], allowMove: false))
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.send(PVE.addPoolMembers("pflive", guests: [202], storages: [], allowMove: false))
        }
        _ = try await session.send(PVE.addPoolMembers("pflive", guests: [102, 202], storages: ["local"], allowMove: true))
        let detail = try #require(try await session.send(PVE.pool("pflive")).first)
        #expect(detail.comment == "ProxFleet live test" && detail.guests.compactMap(\.vmid) == [102, 202] && detail.storages == ["local"])
        #expect(detail.guests.map(\.kind) == [.qemu, .lxc])
        #expect(try await session.send(PVE.pool("pflive-other")).first?.members.isEmpty == true)
        #expect(try await session.fetchClusterSnapshot().guests.first { $0.vmid == 202 }?.pool == "pflive")

        // The server ignores permissions for root@pam, so a throwaway group gets one.
        _ = try await session.send(PVE.createGroup("pflive-pool", comment: nil))
        let permission = ACLEntry(path: "/pool/pflive", subject: .group, subjectID: "pflive-pool", role: "PVEAuditor")
        _ = try await session.send(PVE.addPermission(permission))
        #expect(try await session.send(PVE.acl()).contains { $0.path == "/pool/pflive" && $0.role == "PVEAuditor" })
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.deletePool("pflive")) }
        _ = try await session.send(PVE.removePoolMembers("pflive", guests: [102, 202], storages: ["local"]))
        _ = try await session.send(PVE.updatePoolComment("pflive", comment: ""))
        let emptied = try #require(try await session.send(PVE.pool("pflive")).first)
        #expect(emptied.members.isEmpty && emptied.comment == nil)
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.deletePool("pflive")) }
        for id in ["pflive/inner", "pflive", "pflive-other"] {
            _ = try await session.send(PVE.deletePool(id))
        }
        #expect(try await !session.send(PVE.pools()).contains { $0.id.hasPrefix("pflive") })
        // Deleting a pool removes the permissions on it.
        #expect(try await !session.send(PVE.acl()).contains { $0.path == "/pool/pflive" })
        _ = try await session.send(PVE.deleteGroup("pflive-pool"))
    }

    /// Runs a command in the node's shell and returns its output, which ends before the exit status.
    private func runOnNode(_ session: ProxmoxSession, node: String, _ command: String, timeout: TimeInterval = 30) async throws -> (output: String, status: Int?) {
        let terminal = try await TerminalConnection.open(.node(node), session: session)
        defer { terminal.close() }
        try await terminal.resize(columns: 200, rows: 50)
        let marker = "PFDONE\(Int.random(in: 100_000...999_999))"
        // The marker is split in the command line, so only the command's own echo matches it.
        try await terminal.send("{ \(command) ; } 2>&1; echo \"\(marker.prefix(3))\"\"\(marker.dropFirst(3))-$?\"\n")
        var text = ""
        let deadline = Date().addingTimeInterval(timeout)
        for try await chunk in terminal.output {
            text += String(decoding: chunk, as: UTF8.self)
            if text.range(of: "\(marker)-\\d+", options: .regularExpression) != nil || Date() > deadline { break }
        }
        guard let range = text.range(of: "\(marker)-\\d+", options: .regularExpression) else { return (text, nil) }
        return (String(text[..<range.lowerBound]), Int(text[range].split(separator: "-").last ?? ""))
    }

    /// A VLAN zone that is rolled back, then a simple zone with DHCP, a VNet, a subnet with ranges and a VNet
    /// firewall, applied to the node; a VM's network device gets an address from the IPAM. Needs dnsmasq on the node.
    @Test(.timeLimit(.minutes(3))) func sdn() async throws {
        let (session, node) = try await rootSession()
        try #require(try await !session.send(PVE.sdnZones()).contains { $0.id.hasPrefix("pf") }, "left over from an earlier run")
        try #require(try await session.send(PVE.sdnZones()).allSatisfy { $0.state == nil }, "the server has pending SDN changes")
        let dnsmasq = try await runOnNode(session, node: node, "dpkg-query -W -f='${Status}' dnsmasq")
        try #require(dnsmasq.output.contains("install ok installed"), "install dnsmasq on the node for DHCP zones")

        // Rolled back before anything is applied.
        var vlanZone = SDNZoneDraft()
        vlanZone.id = "pfvlan"
        vlanZone.type = .vlan
        vlanZone.bridge = "vmbr0"
        #expect(vlanZone.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createSDNZone(vlanZone))
        var vlanNet = SDNVNetDraft()
        vlanNet.id = "pfvlnet"
        vlanNet.zone = "pfvlan"
        #expect(vlanNet.problems(isNew: true, zoneType: .vlan)["tag"] != nil)
        vlanNet.tag = "30"
        _ = try await session.send(PVE.createSDNVNet(vlanNet, zoneType: .vlan))
        let pendingVLAN = try #require(try await session.send(PVE.sdnZones()).first { $0.id == "pfvlan" })
        #expect(pendingVLAN.state == .new && pendingVLAN["bridge"] == "vmbr0" && pendingVLAN.running["bridge"] == nil)
        #expect(try await session.send(PVE.sdnVNets()).first { $0.id == "pfvlnet" }?["tag"] == "30")
        _ = try await session.send(PVE.rollbackSDN())
        #expect(try await !session.send(PVE.sdnZones()).contains { $0.id == "pfvlan" })
        #expect(try await !session.send(PVE.sdnVNets()).contains { $0.id == "pfvlnet" })

        var zone = SDNZoneDraft()
        zone.id = "pflive"
        zone.mtu = "1450"
        zone.automaticDHCP = true
        #expect(zone.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createSDNZone(zone))
        var vnet = SDNVNetDraft()
        vnet.id = "pfnet"
        vnet.zone = "pflive"
        vnet.alias = "ProxFleet live test"
        vnet.tag = "12"
        #expect(vnet.problems(isNew: true, zoneType: .simple).isEmpty)
        // The tag does not apply to simple zones and is not sent.
        _ = try await session.send(PVE.createSDNVNet(vnet, zoneType: .simple))
        var subnet = SDNSubnetDraft()
        subnet.cidr = "10.77.0.0/24"
        subnet.gateway = "10.77.0.1"
        subnet.snat = true
        subnet.ranges = [SDNDHCPRange(start: "10.77.0.100", end: "10.77.0.199")]
        #expect(subnet.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createSDNSubnet(vnet: "pfnet", subnet))

        let savedZone = try #require(try await session.send(PVE.sdnZones()).first { $0.id == "pflive" })
        #expect(savedZone.state == .new && SDNZoneDraft(savedZone).automaticDHCP && SDNZoneDraft(savedZone).ipam == "pve")
        let savedNet = try #require(try await session.send(PVE.sdnVNets()).first { $0.id == "pfnet" })
        #expect(SDNVNetDraft(savedNet).alias == "ProxFleet live test" && savedNet["tag"] == nil)
        let savedSubnet = try #require(try await session.send(PVE.sdnSubnets(vnet: "pfnet")).first)
        #expect(savedSubnet["cidr"] == "10.77.0.0/24" && savedSubnet.ranges == subnet.ranges && savedSubnet.state == .new)
        #expect(SDNSubnetDraft(savedSubnet).changes(from: SDNSubnetDraft(savedSubnet)).isEmpty)

        let apply = try await session.send(PVE.applySDN())
        #expect(try await finishTask(session, node: node, apply)?.succeeded == true)
        #expect(try await session.send(PVE.sdnZoneStatus(node: node)).first { $0.zone == "pflive" }?.status == "available")
        let applied = try #require(try await session.send(PVE.sdnSubnets(vnet: "pfnet")).first)
        #expect(applied.state == nil && applied.runningRanges == subnet.ranges)
        // dnsmasq may still be starting right after the task.
        let bridge = try await runOnNode(session, node: node, """
            for i in 1 2 3 4 5; do systemctl is-active --quiet dnsmasq@pflive && break; sleep 1; done; \
            ip -br link show pfnet && systemctl is-active dnsmasq@pflive
            """)
        #expect(bridge.status == 0 && bridge.output.contains("pfnet"), "\(bridge.output)")

        // Pending changes keep the applied values until the next Apply.
        var editedSubnet = SDNSubnetDraft(applied)
        let originalSubnet = editedSubnet
        editedSubnet.ranges = [SDNDHCPRange(start: "10.77.0.50", end: "10.77.0.59"), SDNDHCPRange(start: "10.77.0.100", end: "10.77.0.199")]
        editedSubnet.snat = false
        editedSubnet.dnsZonePrefix = "lab"
        _ = try await session.send(PVE.updateSDNSubnet(vnet: "pfnet", id: applied.id, editedSubnet.changes(from: originalSubnet)))
        var editedNet = SDNVNetDraft(try #require(try await session.send(PVE.sdnVNets()).first { $0.id == "pfnet" }))
        let originalNet = editedNet
        editedNet.alias = ""
        editedNet.isolatesPorts = true
        _ = try await session.send(PVE.updateSDNVNet("pfnet", editedNet.changes(from: originalNet, zoneType: .simple)))
        let changed = try #require(try await session.send(PVE.sdnSubnets(vnet: "pfnet")).first)
        #expect(changed.state == .changed && changed.ranges.count == 2 && changed.runningRanges == subnet.ranges)
        #expect(changed["snat"] == nil && changed.running["snat"] == "1" && changed["dnszoneprefix"] == "lab")
        let changedNet = try #require(try await session.send(PVE.sdnVNets()).first { $0.id == "pfnet" })
        #expect(changedNet.state == .changed && changedNet["alias"] == nil && changedNet["isolate-ports"] == "1")
        #expect(try await finishTask(session, node: node, try await session.send(PVE.applySDN()))?.succeeded == true)
        #expect(try await session.send(PVE.sdnSubnets(vnet: "pfnet")).first?.runningRanges.count == 2)

        // The VNet's firewall, with forward rules only.
        let scope = FirewallScope.vnet("pfnet", zone: "pflive")
        let options = try await session.send(PVE.firewallOptions(scope))
        var optionsDraft = FirewallOptionsDraft(options, scope: scope)
        let originalOptions = optionsDraft
        optionsDraft.setFlag("enable", true)
        optionsDraft.values["policy_forward"] = "DROP"
        _ = try await session.send(PVE.updateFirewallOptions(scope, optionsDraft.changes(from: originalOptions)))
        var rule = FirewallRuleDraft()
        rule.type = "forward"
        rule.macro = "SSH"
        rule.comment = "pflive vnet"
        _ = try await session.send(PVE.createFirewallRule(scope, rule))
        let rules = try await session.send(PVE.firewallRules(scope))
        #expect(rules.first?.type == "forward" && rules.first?.comment == "pflive vnet")
        let savedOptions = try await session.send(PVE.firewallOptions(scope))
        #expect(savedOptions.isEnabled(in: scope) && savedOptions.values["policy_forward"] == "DROP")
        _ = try await session.send(PVE.deleteFirewallRule(scope, position: 0, digest: nil))
        _ = try await session.send(PVE.updateFirewallOptions(scope, originalOptions.changes(from: FirewallOptionsDraft(savedOptions, scope: scope))))

        // A network device on the VNet gets an address from the DHCP range when the VM starts.
        let vm = GuestReference(node: node, vmid: 101, kind: .virtualMachine)
        var attach = GuestConfigUpdate()
        attach.set("net1", "model=virtio,bridge=pfnet")
        _ = try await session.send(PVE.updateConfig(vm, attach))
        #expect(try await finishTask(session, node: node, try await session.send(PVE.powerAction(.start, on: vm)))?.succeeded == true)
        let entries = try await session.send(PVE.ipamEntries("pve"))
        let lease = entries.first { $0.vmid == 101 && $0.vnet == "pfnet" }
        #expect(lease?.ip.hasPrefix("10.77.0.") == true && lease?.mac != nil, "\(entries)")
        #expect(entries.contains { $0.isGateway && $0.ip == "10.77.0.1" })
        // Addresses reserved by hand take effect right away, without Apply.
        _ = try await session.send(PVE.createIPMapping(vnet: "pfnet", zone: "pflive", ip: "10.77.0.150", mac: "BC:24:11:AA:BB:CC"))
        #expect(try await session.send(PVE.ipamEntries("pve")).contains { $0.ip == "10.77.0.150" && $0.mac?.uppercased() == "BC:24:11:AA:BB:CC" })
        _ = try await session.send(PVE.updateIPMapping(vnet: "pfnet", zone: "pflive", ip: "10.77.0.151", mac: "BC:24:11:AA:BB:CC", vmid: nil))
        #expect(try await session.send(PVE.ipamEntries("pve")).contains { $0.ip == "10.77.0.151" && $0.mac?.uppercased() == "BC:24:11:AA:BB:CC" })
        _ = try await session.send(PVE.deleteIPMapping(vnet: "pfnet", zone: "pflive", ip: "10.77.0.151", mac: "BC:24:11:AA:BB:CC"))
        #expect(try await !session.send(PVE.ipamEntries("pve")).contains { $0.mac?.uppercased() == "BC:24:11:AA:BB:CC" })
        #expect(try await finishTask(session, node: node, try await session.send(PVE.powerAction(.stop, on: vm)))?.succeeded == true)
        var detach = GuestConfigUpdate()
        detach.set("net1", nil)
        _ = try await session.send(PVE.updateConfig(vm, detach))

        _ = try await session.send(PVE.deleteSDNSubnet(vnet: "pfnet", id: applied.id))
        _ = try await session.send(PVE.deleteSDNVNet("pfnet"))
        _ = try await session.send(PVE.deleteSDNZone("pflive"))
        #expect(try await finishTask(session, node: node, try await session.send(PVE.applySDN()))?.succeeded == true)
        #expect(try await !session.send(PVE.sdnZones()).contains { $0.id == "pflive" })
        #expect(try await session.send(PVE.sdnZoneStatus(node: node)).allSatisfy { $0.zone != "pflive" })
    }

    /// A prefix list and a route map used by an EVPN controller, an EVPN zone with a VNet, a BGP controller and an
    /// OpenFabric fabric on a port-less bridge, applied to the node and checked in FRR's running configuration.
    /// Needs frr on the node.
    @Test(.timeLimit(.minutes(3))) func sdnRouting() async throws {
        let (session, node) = try await rootSession()
        try #require(try await session.send(PVE.sdnZones()).allSatisfy { $0.state == nil }, "the server has pending SDN changes")
        try #require(try await session.send(PVE.sdnControllers()).isEmpty, "the test server has SDN controllers")
        let frr = try await runOnNode(session, node: node, "dpkg-query -W -f='${Status}' frr")
        try #require(frr.output.contains("install ok installed"), "install frr on the node")
        let network = try await session.send(PVE.network(node: node))
        try #require(network.pendingChanges == nil, "the test server has unapplied network changes")
        let address = try #require(network.interfaces.first { $0.gateway != nil }?.cidr?.split(separator: "/").first.map(String.init))

        // A bridge without ports carries the fabric, so the node's own uplink is never touched.
        var bridge = NetworkInterfaceDraft(creating: .bridge, existing: network.interfaces)
        bridge.name = "vmbr94"
        _ = try await session.send(PVE.createInterface(node: node, bridge))
        #expect(try await finishTask(session, node: node, try await session.send(PVE.applyNetwork(node: node)))?.succeeded == true)

        _ = try await session.send(PVE.createSDNPrefixList("pflst"))
        var entry = SDNPrefixListEntryDraft()
        entry.prefix = "10.0.0.0/8"
        entry.le = "24"
        _ = try await session.send(PVE.createSDNPrefixListEntry(list: "pflst", entry))
        let entries = try await session.send(PVE.sdnPrefixListEntries("pflst"))
        #expect(entries.count == 1 && entries.first?.le == 24 && entries.first?.sequence == 5)
        var route = SDNRouteMapEntryDraft(routeMap: "pfrmap", order: "10")
        route.match = [SDNRouteMapClause(key: "ip-address-prefix-list", value: "pflst")]
        route.set = [SDNRouteMapClause(key: "local-preference", value: "200")]
        route.exitAction = .next
        #expect(route.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createSDNRouteMapEntry(route))
        let savedRoute = try #require(try await session.send(PVE.sdnRouteMapEntries()).map(SDNRouteMapEntry.init).first { $0.routeMap == "pfrmap" })
        #expect(savedRoute.state == .new && SDNRouteMapEntryDraft(savedRoute) == route)

        var evpn = SDNControllerDraft()
        evpn.id = "pfevpn"
        evpn.peers = address
        evpn.routeMapIn = "pfrmap"
        _ = try await session.send(PVE.createSDNController(evpn))
        var bgp = SDNControllerDraft(type: .bgp)
        bgp.node = node
        bgp.asn = "65001"
        bgp.peers = "192.0.2.1"
        bgp.ebgp = true
        #expect(bgp.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createSDNController(bgp))
        var isis = SDNControllerDraft(type: .isis)
        isis.node = node
        isis.isisDomain = "pflive"
        isis.isisNet = "49.0001.1720.1600.1001.00"
        isis.isisInterfaces = "vmbr94"
        #expect(isis.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createSDNController(isis))
        let controllers = try await session.send(PVE.sdnControllers())
        #expect(Set(controllers.map(\.id)) == ["pfevpn", "bgp\(node)", "isis\(node)"])
        #expect(SDNControllerDraft(try #require(controllers.first { $0.id == "pfevpn" })) == evpn)
        // IS-IS is only checked as configuration; it is removed before Apply.
        _ = try await session.send(PVE.deleteSDNController("isis\(node)"))

        var zone = SDNZoneDraft()
        zone.id = "pfevz"
        zone.type = .evpn
        zone.controller = "pfevpn"
        zone.vrfVXLAN = "10000"
        zone.exitNodes = [node]
        zone.advertisesSubnets = true
        #expect(zone.problems(isNew: true).isEmpty)
        _ = try await session.send(PVE.createSDNZone(zone))
        var vnet = SDNVNetDraft()
        vnet.id = "pfevnet"
        vnet.zone = "pfevz"
        vnet.tag = "11000"
        _ = try await session.send(PVE.createSDNVNet(vnet, zoneType: .evpn))
        let savedZone = SDNZoneDraft(try #require(try await session.send(PVE.sdnZones()).first { $0.id == "pfevz" }))
        #expect(savedZone.controller == "pfevpn" && savedZone.exitNodes == [node] && savedZone.advertisesSubnets && !savedZone.mac.isEmpty)

        var fabric = SDNFabricDraft(protocol: .openfabric)
        fabric.id = "pffab"
        fabric.ipPrefix = "10.250.0.0/24"
        fabric.routeFilter = "pflst"
        _ = try await session.send(PVE.createSDNFabric(fabric))
        var fabricNode = SDNFabricNodeDraft(protocol: .openfabric)
        fabricNode.node = node
        fabricNode.ip = "10.250.0.1"
        fabricNode.interfaces = [SDNFabricInterface(name: "vmbr94")]
        _ = try await session.send(PVE.addSDNFabricNode(fabric: "pffab", fabricNode))
        let fabrics = try await session.send(PVE.sdnFabrics())
        #expect(SDNFabricDraft(try #require(fabrics.fabrics.first { $0.id == "pffab" })) == fabric)
        let savedNode = try #require(fabrics.nodes.first { $0.fabricID == "pffab" })
        #expect(SDNFabricNodeDraft(savedNode) == fabricNode && savedNode.state == .new)
        var editedFabric = fabric
        editedFabric.helloInterval = "5"
        _ = try await session.send(PVE.updateSDNFabric("pffab", protocol: .openfabric, editedFabric.changes(from: fabric)))

        #expect(try await finishTask(session, node: node, try await session.send(PVE.applySDN()))?.succeeded == true)
        #expect(try await session.send(PVE.sdnZoneStatus(node: node)).first { $0.zone == "pfevz" }?.status == "available")
        let config = try await runOnNode(session, node: node, "vtysh -c 'show running-config' | grep -E '^(router|route-map|ip prefix-list)'")
        // The node's BGP controller sets the node's AS number for EVPN too.
        for line in ["router bgp 65001", "router bgp 65001 vrf vrf_pfevz", "route-map pfrmap permit 10", "ip prefix-list pflst seq 5 permit 10.0.0.0/8 le 24", "router openfabric pffab"] {
            #expect(config.output.contains(line), "\(line) missing in \(config.output)")
        }
        #expect(try await session.send(PVE.sdnFabrics()).fabrics.first { $0.id == "pffab" }?["hello_interval"] == "5")

        // Removed in dependency order and applied.
        _ = try await session.send(PVE.removeSDNFabricNode(fabric: "pffab", node: node))
        _ = try await session.send(PVE.deleteSDNFabric("pffab"))
        _ = try await session.send(PVE.deleteSDNVNet("pfevnet"))
        _ = try await session.send(PVE.deleteSDNZone("pfevz"))
        _ = try await session.send(PVE.deleteSDNController("pfevpn"))
        _ = try await session.send(PVE.deleteSDNController("bgp\(node)"))
        _ = try await session.send(PVE.deleteSDNRouteMapEntry(routeMap: "pfrmap", order: 10))
        _ = try await session.send(PVE.deleteSDNPrefixList("pflst"))
        #expect(try await finishTask(session, node: node, try await session.send(PVE.applySDN()))?.succeeded == true)
        #expect(try await session.send(PVE.sdnControllers()).isEmpty)
        #expect(try await session.send(PVE.sdnFabrics()).fabrics.isEmpty)
        #expect(try await session.send(PVE.sdnRouteMapEntries()).isEmpty)
        #expect(try await session.send(PVE.sdnPrefixLists()).isEmpty)
        _ = try await session.send(PVE.deleteInterface(node: node, name: "vmbr94"))
        #expect(try await finishTask(session, node: node, try await session.send(PVE.applyNetwork(node: node)))?.succeeded == true)
    }

    /// PCI, USB and directory mappings built from the node's devices, checked, changed, used by a VM and removed.
    @Test func resourceMappings() async throws {
        let (session, node) = try await rootSession()
        for kind in ResourceMappingKind.allCases {
            try #require(try await !session.send(PVE.resourceMappingDetails(kind, checkNode: nil)).contains { $0.id.hasPrefix("pflive") }, "left over from an earlier run")
        }
        let pciDevices = try await session.send(PVE.pciDevices(node: node))
        let audio = try #require(pciDevices.first { $0.id.hasSuffix(".0") && $0.vendorDeviceID != nil && $0.subsystemID != nil })
        let usbController = try #require(pciDevices.first { $0.id.hasSuffix(".1") })
        let usbDevice = try #require(try await session.send(PVE.usbDevices(node: node)).first { !$0.isHub && $0.portID != nil })

        var pci = ResourceMappingDraft(kind: .pci)
        pci.id = "pflive-pci"
        pci.description = "ProxFleet live test"
        pci.mdev = true
        pci.entries = [ResourceMappingDraft.pciEntry(audio, node: node), ResourceMappingDraft.pciEntry(usbController, node: node, allFunctions: true)]
        #expect(pci.problems(isNew: true).isEmpty)
        // Without an IOMMU, devices are in group -1, which is left out as in the web interface.
        #expect(pci.entries[0]["iommugroup"] == nil || audio.iommuGroup != -1)
        _ = try await session.send(PVE.createResourceMapping(pci))
        var usb = ResourceMappingDraft(kind: .usb)
        usb.id = "pflive-usb"
        usb.entries = [ResourceMappingDraft.usbEntry(usbDevice, node: node, byPort: true)]
        _ = try await session.send(PVE.createResourceMapping(usb))
        var dir = ResourceMappingDraft(kind: .dir)
        dir.id = "pflive-dir"
        dir.entries = [ResourceMappingDraft.directoryEntry("relative/path", node: node)]
        #expect(dir.problems(isNew: true)["map"] != nil)
        dir.entries = [ResourceMappingDraft.directoryEntry("/var/lib/vz/template", node: node)]
        _ = try await session.send(PVE.createResourceMapping(dir))
        dir.id = "pflive-missing"
        dir.entries = [ResourceMappingDraft.directoryEntry("/proxfleet/does/not/exist", node: node)]
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PVE.createResourceMapping(dir)) }

        let savedPCI = try #require(try await session.send(PVE.resourceMappingDetails(.pci, checkNode: node)).first { $0.id == "pflive-pci" })
        #expect(savedPCI.mdev && savedPCI.description == "ProxFleet live test" && savedPCI.nodes == [node])
        #expect(savedPCI.entries.map { $0["path"] } == [audio.id, String(usbController.id.dropLast(2))])
        #expect(!savedPCI.checks.contains { $0.message.contains("iommugroup") }, "\(savedPCI.checks)")
        let savedUSB = try #require(try await session.send(PVE.resourceMappingDetails(.usb, checkNode: node)).first { $0.id == "pflive-usb" })
        #expect(savedUSB.entries.first?["path"] == usbDevice.portID && savedUSB.entries.first?["id"] == usbDevice.deviceID && savedUSB.checks.isEmpty)
        let savedDir = try #require(try await session.send(PVE.resourceMappingDetails(.dir, checkNode: node)).first { $0.id == "pflive-dir" })
        #expect(savedDir.entries.first?["path"] == "/var/lib/vz/template")

        var edited = ResourceMappingDraft(kind: .pci, savedPCI)
        let original = edited
        #expect(edited.changes(from: original).isEmpty)
        edited.description = ""
        edited.mdev = false
        edited.setEntries([ResourceMappingDraft.pciEntry(audio, node: node)], on: node)
        let changes = edited.changes(from: original)
        #expect(changes["delete"] == "description,mdev" && changes.values("map").count == 1)
        _ = try await session.send(PVE.updateResourceMapping(.pci, id: "pflive-pci", changes, digest: savedPCI.digest))
        let changedPCI = try #require(try await session.send(PVE.resourceMappingDetails(.pci, checkNode: nil)).first { $0.id == "pflive-pci" })
        #expect(changedPCI.description == nil && !changedPCI.mdev && changedPCI.entries.count == 1)
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.send(PVE.updateResourceMapping(.pci, id: "pflive-pci", ["description": "stale"], digest: savedPCI.digest))
        }

        // A VM shares the mapped directory with virtiofs.
        let vm = GuestReference(node: node, vmid: 101, kind: .virtualMachine)
        var share = GuestConfigUpdate()
        share.set("virtiofs0", "dirid=pflive-dir")
        _ = try await session.send(PVE.updateConfig(vm, share))
        #expect(try await session.send(PVE.guestConfig(vm)).values["virtiofs0"] == "dirid=pflive-dir")
        var unshare = GuestConfigUpdate()
        unshare.set("virtiofs0", nil)
        _ = try await session.send(PVE.updateConfig(vm, unshare))

        for (kind, id) in [(ResourceMappingKind.pci, "pflive-pci"), (.usb, "pflive-usb"), (.dir, "pflive-dir")] {
            _ = try await session.send(PVE.deleteResourceMapping(kind, id: id))
            #expect(try await !session.send(PVE.resourceMappingDetails(kind, checkNode: nil)).contains { $0.id == id })
        }
    }

    /// Tag colors, WebAuthn, U2F, replication, fencing, location and the HA resource scheduler, saved and restored.
    @Test func datacenterOptionsExtras() async throws {
        let (session, _) = try await rootSession()
        let options = DatacenterOptionsDraft(try await session.send(PVE.datacenterOptions()))
        var edited = options
        edited.tagColors = [TagColor(tag: "prod", background: "C62828"), TagColor(tag: "web", background: "2E7D32", text: "FFFFFF")]
        edited.fillWebauthn(host: "pve.example.com", port: 8006)
        edited.webauthnAllowsSubdomains = false
        edited.u2fAppID = "https://pve.example.com"
        edited.u2fOrigin = "https://pve.example.com:8006"
        edited.replicationType = "insecure"
        edited.replicationNetwork = "10.10.0.0/24"
        edited.fencing = "both"
        edited.location = Location()
        edited.location.latitude = "52.2297"
        edited.location.longitude = "21.0122"
        edited.location.name = "Warsaw rack"
        edited.haScheduler = "dynamic"
        edited.haRebalanceOnStart = true
        edited.haAutoRebalance = true
        edited.haRebalanceThreshold = "40"
        edited.haRebalanceMethod = "topsis"
        #expect(edited.problems.isEmpty, "\(edited.problems)")
        _ = try await session.send(PVE.updateDatacenterOptions(edited.changes(from: options)))
        let config = try await session.send(PVE.datacenterOptions())
        let saved = DatacenterOptionsDraft(config)
        #expect(saved.tagColors == edited.tagColors, "\(config.values["tag-style"] ?? "")")
        #expect(saved.webauthnOrigin == "https://pve.example.com:8006" && saved.webauthnID == "pve.example.com" && !saved.webauthnAllowsSubdomains)
        #expect(saved.u2fAppID == "https://pve.example.com" && saved.replicationType == "insecure" && saved.replicationNetwork == "10.10.0.0/24")
        #expect(saved.fencing == "both" && saved.location == edited.location)
        #expect(saved.haScheduler == "dynamic" && saved.haRebalanceOnStart && saved.haAutoRebalance && saved.haRebalanceThreshold == "40" && saved.haRebalanceMethod == "topsis")
        #expect(saved.changes(from: saved).isEmpty)
        _ = try await session.send(PVE.updateDatacenterOptions(options.changes(from: saved)))
        #expect(DatacenterOptionsDraft(try await session.send(PVE.datacenterOptions())) == options)
    }

    /// The datacenter's bulk actions start and shut down CT 202 and hibernate and resume VM 102; the cluster log lists
    /// their tasks; the system report and a changelog load.
    @Test(.timeLimit(.minutes(3))) func datacenterBulkActionsLogAndReport() async throws {
        let (session, node) = try await rootSession()
        let container = GuestReference(node: node, vmid: 202, kind: .container)
        let vm = GuestReference(node: node, vmid: 102, kind: .virtualMachine)
        try #require(try await session.send(PVE.guestStatus(container)).powerState == .stopped, "CT 202 should be stopped")
        try #require(try await session.send(PVE.guestStatus(vm)).powerState == .running, "VM 102 should be running")

        let start = try await session.send(PVE.clusterBulkAction(NodeBulkActionDraft(action: .start, vmids: [202])))
        #expect(try await finishTask(session, node: node, start)?.succeeded == true)
        #expect(try await session.send(PVE.guestStatus(container)).powerState == .running)
        var shutdown = NodeBulkActionDraft(action: .shutdown, vmids: [202])
        shutdown.timeout = 30
        let stop = try await session.send(PVE.clusterBulkAction(shutdown))
        #expect(try await finishTask(session, node: node, stop)?.succeeded == true)
        #expect(try await session.send(PVE.guestStatus(container)).powerState == .stopped)

        let hibernate = try await session.send(PVE.clusterBulkAction(NodeBulkActionDraft(action: .hibernate, vmids: [102])))
        #expect(try await finishTask(session, node: node, hibernate)?.succeeded == true)
        let hibernated = try await session.send(PVE.guestConfig(vm))
        #expect(hibernated.values["vmstate"] != nil && hibernated.values["lock"] == "suspended")
        let resume = try await session.send(PVE.clusterBulkAction(NodeBulkActionDraft(action: .start, vmids: [102])))
        #expect(try await finishTask(session, node: node, resume)?.succeeded == true)
        #expect(try await session.send(PVE.guestStatus(vm)).powerState == .running)

        let log = try await session.send(PVE.clusterLog(max: 100))
        // In a cluster the log also has entries of the other nodes.
        #expect(log.contains { $0.upid == start && $0.message.hasPrefix("starting task") && $0.node == node })
        let report = try await session.send(PVE.systemReport(node: node))
        #expect(report.contains("==== general system info ====") && report.contains(node))
        let version = try #require(try await session.send(PVE.packageVersions(node: node)).first { $0.package == "pve-manager" }?.version)
        let changelog = try await session.send(PVE.packageChangelog(node: node, package: "pve-manager", version: version))
        #expect(changelog.hasPrefix("pve-manager (\(version))"))
    }

    /// Needs a cluster with two more nodes that have local-lvm. VM 100's local ISO blocks it; CT 202 moves offline
    /// and comes back with the node's Migrate All; VM 102 moves live with its local disk and CT 201 in restart mode,
    /// and both come back with the datacenter's bulk migration.
    @Test(.timeLimit(.minutes(6))) func migration() async throws {
        let (session, node) = try await rootSession()
        let snapshot = try await session.fetchClusterSnapshot()
        let others = snapshot.nodes.filter { $0.isOnline && $0.name != node }.map(\.name).sorted()
        try #require(others.count >= 2, "migration needs a cluster with two more online nodes")
        let guests = Dictionary(uniqueKeysWithValues: snapshot.guests.map { ($0.vmid, $0) })
        try #require([100, 102, 201, 202].allSatisfy { guests[$0]?.node == node }, "VMs 100 and 102 and CTs 201 and 202 should be on \(node)")
        try #require(guests[102]?.state == .running && guests[201]?.state == .running && guests[202]?.state == .stopped, "VM 102 and CT 201 should run, CT 202 be stopped")
        func location(_ vmid: Int) async throws -> String? { try await session.fetchClusterSnapshot().guests.first { $0.vmid == vmid }?.node }
        func draft(_ guest: GuestReference, to target: String) async throws -> MigrationDraft {
            var draft = MigrationDraft(guest: guest, target: target)
            draft.preconditions = try await session.send(PVE.migrationPreconditions(guest, target: target))
            if guest.kind == .virtualMachine {
                draft.targetSupportsConntrackState = try await session.send(PVE.qemuMigrationCapabilities(node: target)).supportsConntrackState
            }
            return draft
        }

        let iso = try await draft(GuestReference(node: node, vmid: 100, kind: .virtualMachine), to: others[0])
        #expect(!iso.canMigrate && iso.notes.contains { $0.severity == .error && $0.text.contains("local CD/DVD") })

        // Offline, then back with Migrate All of the other node.
        let stopped = try await draft(GuestReference(node: node, vmid: 202, kind: .container), to: others[1])
        #expect(stopped.mode == .offline && stopped.canMigrate && stopped.parameters.formEncoded == "target=\(others[1])")
        let offline = try await session.send(PVE.migrate(stopped))
        #expect(UPID(offline)?.type == "vzmigrate")
        #expect(try await finishTask(session, node: node, offline, timeout: 120)?.succeeded == true)
        #expect(try await location(202) == others[1])
        var all = NodeBulkActionDraft(action: .migrate, vmids: [202])
        all.target = node
        let migrateAll = try await session.send(PVE.bulkAction(node: others[1], all))
        #expect(UPID(migrateAll)?.type == "migrateall")
        #expect(try await finishTask(session, node: others[1], migrateAll, timeout: 120)?.succeeded == true)
        #expect(try await location(202) == node)

        // Live with the local disk and the conntrack state, and a container in restart mode.
        let running = try await draft(GuestReference(node: node, vmid: 102, kind: .virtualMachine), to: others[0])
        #expect(running.mode == .online && running.showsTargetStorage && running.canMigrate)
        #expect(running.parameters["with-local-disks"] == .bool(true) && running.parameters["with-conntrack-state"] == .bool(true))
        let live = try await session.send(PVE.migrate(running))
        #expect(UPID(live)?.type == "qmigrate")
        let restart = try await session.send(PVE.migrate(try await draft(GuestReference(node: node, vmid: 201, kind: .container), to: others[0])))
        let liveStatus = try await finishTask(session, node: node, live, timeout: 240)
        #expect(liveStatus?.succeeded == true, "\(liveStatus?.exitStatus ?? "timed out")")
        #expect(try await finishTask(session, node: node, restart, timeout: 120)?.succeeded == true)
        #expect(try await location(102) == others[0])
        #expect(try await location(201) == others[0])
        #expect(try await session.send(PVE.guestStatus(GuestReference(node: others[0], vmid: 201, kind: .container))).powerState == .running)

        var back = NodeBulkActionDraft(action: .migrate, vmids: [102, 201])
        back.target = node
        back.maxWorkers = 2
        let bulk = try await session.send(PVE.clusterBulkAction(back))
        #expect(UPID(bulk)?.type == "bulk-migrate")
        let bulkStatus = try await finishTask(session, node: try #require(UPID(bulk)?.node), bulk, timeout: 240)
        #expect(bulkStatus?.succeeded == true, "\(bulkStatus?.exitStatus ?? "timed out")")
        #expect(try await location(102) == node)
        #expect(try await location(201) == node)
        #expect(try await session.send(PVE.guestStatus(GuestReference(node: node, vmid: 102, kind: .virtualMachine))).powerState == .running)
    }

    /// Needs a cluster whose nodes share a ZFS storage named `tank`. A VM with its disk there gets a job to another
    /// node, runs it now (Proxmox starts it within a minute), is edited, and the job removes itself and the copy.
    @Test(.timeLimit(.minutes(5))) func replication() async throws {
        let (session, node) = try await rootSession()
        let snapshot = try await session.fetchClusterSnapshot()
        let target = try #require(snapshot.nodes.filter { $0.isOnline && $0.name != node }.map(\.name).sorted().first, "replication needs a cluster")
        try #require(snapshot.storages.contains { $0.name == "tank" }, "replication needs a ZFS storage named tank on every node")
        try #require(!snapshot.guests.contains { $0.vmid == 230 }, "left over from an earlier run")
        let vm = GuestReference(node: node, vmid: 230, kind: .virtualMachine)
        let create = try await session.send(APIRequest<String>(.post, "/nodes/\(node)/qemu", parameters: ["vmid": 230, "name": "pflive-replication", "memory": 128, "scsi0": "tank:1"]))
        #expect(try await finishTask(session, node: node, create)?.succeeded == true)
        defer {
            Task {
                _ = try? await session.send(PVE.deleteReplicationJob("230-0"))
                _ = try? await session.send(PVE.destroy(vm, purge: true, destroyUnreferencedDisks: true))
            }
        }

        // Disks on local-lvm cannot be replicated.
        do {
            _ = try await session.send(PVE.createReplicationJob(ReplicationJobDraft(guest: 100, target: target), id: "100-0"))
            Issue.record("expected a refusal")
        } catch ProxmoxError.api(_, let message, _) {
            #expect(message?.contains("missing replicate feature") == true)
        }

        var draft = ReplicationJobDraft(guest: 230, target: target)
        draft.comment = "ProxFleet live test"
        draft.schedule = "*/30"
        let id = ReplicationJobDraft.nextID(for: 230, existing: try await session.send(PVE.replicationJobs()))
        #expect(id == "230-0")
        _ = try await session.send(PVE.createReplicationJob(draft, id: id))
        let created = try #require(try await session.send(PVE.replicationStatus(node: node, guest: 230)).first)
        #expect(created.target == target && created.schedule == "*/30" && created.comment == "ProxFleet live test" && created.lastSync == nil && created.isPending())

        _ = try await session.send(PVE.runReplicationNow(node: node, id: id))
        var synced: ReplicationJob?
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let job = try #require(try await session.send(PVE.replicationStatus(node: node, guest: 230)).first)
            if job.lastSync != nil, !job.isRunning { synced = job; break }
        }
        let job = try #require(synced, "the job did not run within two minutes")
        #expect(job.error == nil && job.failCount == 0 && job.duration != nil)
        let log = try await session.send(PVE.replicationLog(node: node, id: id)).map(\.text)
        #expect(log.contains { $0.contains("full sync 'tank:vm-230-disk-0'") } && log.last?.hasSuffix("end replication job") == true)

        var edit = ReplicationJobDraft(job)
        edit.rate = "25"
        edit.comment = ""
        edit.isEnabled = false
        _ = try await session.send(PVE.updateReplicationJob(id, edit.changes(from: ReplicationJobDraft(job))))
        let edited = try await session.send(PVE.replicationJob(id))
        #expect(edited.rate == 25 && edited.comment == nil && !edited.isEnabled && edited.digest != nil)

        // Removal waits for the next run, which also deletes the copy on the target.
        _ = try await session.send(PVE.deleteReplicationJob(id))
        #expect(try await session.send(PVE.replicationJob(id)).removal == "full")
        _ = try await session.send(PVE.runReplicationNow(node: node, id: id))
        var removed = false
        for _ in 0..<60 where !removed {
            try await Task.sleep(for: .seconds(2))
            removed = try await !session.send(PVE.replicationJobs()).contains { $0.id == id }
        }
        #expect(removed)
        let destroy = try await session.send(PVE.destroy(vm, purge: true, destroyUnreferencedDisks: true))
        #expect(try await finishTask(session, node: node, destroy)?.succeeded == true)
    }

    /// Needs a three-node cluster with the ZFS storage `tank`. A VM with its disk there joins HA, which starts it; a
    /// strict node affinity rule blocks one node; HA relocates it to another node; HA is disarmed and armed again.
    @Test func highAvailability() async throws {
        let (session, node) = try await rootSession()
        let snapshot = try await session.fetchClusterSnapshot()
        let others = snapshot.nodes.filter { $0.isOnline && $0.name != node }.map(\.name).sorted()
        try #require(others.count >= 2, "HA needs a cluster with two more online nodes")
        try #require(snapshot.storages.contains { $0.name == "tank" }, "HA needs a ZFS storage named tank on every node")
        try #require(!snapshot.guests.contains { $0.vmid == 232 }, "left over from an earlier run")
        try #require(try await session.send(PVE.haResources()).isEmpty, "the cluster already has HA resources")
        let create = try await session.send(APIRequest<String>(.post, "/nodes/\(node)/qemu", parameters: ["vmid": 232, "name": "pflive-ha", "memory": 128, "scsi0": "tank:1"]))
        #expect(try await finishTask(session, node: node, create)?.succeeded == true)
        func service() async throws -> HAStatusEntry? { try await session.send(PVE.haStatus()).first { $0.sid == "vm:232" } }
        func wait(_ what: String, seconds: Int = 90, until condition: () async throws -> Bool) async throws {
            for _ in 0..<seconds / 2 {
                if try await condition() { return }
                try await Task.sleep(for: .seconds(2))
            }
            Issue.record("timed out waiting for \(what)")
        }

        var draft = HAResourceDraft(guest: 232, kind: .virtualMachine)
        draft.comment = "ProxFleet live test"
        draft.maxRestart = "2"
        _ = try await session.send(PVE.createHAResource(draft))
        let resource = try #require(try await session.send(PVE.haResources()).first { $0.sid == "vm:232" })
        #expect(resource.maxRestart == 2 && resource.comment == "ProxFleet live test" && resource.state == "started")
        // The CRM starts the guest within a few seconds.
        try await wait("HA to start the VM") { try await service()?.state == "started" }
        try await wait("the VM to run") { try await session.send(PVE.guestStatus(GuestReference(node: node, vmid: 232, kind: .virtualMachine))).powerState == .running }
        let status = try await session.send(PVE.haStatus())
        #expect(status.contains { $0.kind == .master } && status.first { $0.kind == .fencing }?.armedState == "armed")
        #expect(status.first { $0.id == "lrm:\(node)" }?.status.contains("active") == true)

        var rule = HARuleDraft(kind: .nodeAffinity)
        rule.resources = ["vm:232"]
        // Without priorities: with them, HA only moves the VM to the available nodes with the highest one.
        rule.nodes = [node: nil, others[0]: nil]
        rule.isStrict = true
        rule.comment = "ProxFleet live test"
        let ruleID = HARuleDraft.newID()
        _ = try await session.send(PVE.createHARule(rule, id: ruleID))
        let saved = try #require(try await session.send(PVE.haRules()).first { $0.id == ruleID })
        #expect(saved.isStrict && saved.nodes.map(\.name) == [node, others[0]].sorted() && saved.errors.isEmpty)
        let blocked = try await session.send(PVE.moveHAResource("vm:232", to: others[1], relocate: true))
        #expect(blocked.blockingResources.first?.cause == "node-affinity")

        // Relocation stops the VM, copies its disk and starts it there.
        let moved = try await session.send(PVE.moveHAResource("vm:232", to: others[0], relocate: true))
        #expect(moved.blockingResources.isEmpty)
        try await wait("HA to relocate the VM", seconds: 180) {
            let entry = try await service()
            return entry?.node == others[0] && entry?.state == "started"
        }

        var edit = HARuleDraft(saved)
        edit.isEnabled = false
        _ = try await session.send(PVE.updateHARule(ruleID, kind: .nodeAffinity, edit.changes(from: HARuleDraft(saved))))
        #expect(try await session.send(PVE.haRules()).first { $0.id == ruleID }?.isEnabled == false)

        _ = try await session.send(PVE.disarmHA(resourceMode: "freeze"))
        try await wait("HA to disarm") { try await session.send(PVE.haStatus()).first { $0.kind == .fencing }?.armedState == "disarmed" }
        _ = try await session.send(PVE.armHA())
        try await wait("HA to arm") { try await session.send(PVE.haStatus()).first { $0.kind == .fencing }?.armedState == "armed" }

        // Removing the resource with purge also deletes the rule it was the only resource of.
        var stop = HAResourceDraft(try #require(try await session.send(PVE.haResources()).first { $0.sid == "vm:232" }))
        let running = stop
        stop.state = "stopped"
        _ = try await session.send(PVE.updateHAResource("vm:232", stop.changes(from: running)))
        try await wait("HA to stop the VM") { try await service()?.state == "stopped" }
        _ = try await session.send(PVE.deleteHAResource("vm:232"))
        #expect(try await session.send(PVE.haRules()).contains { $0.id == ruleID } == false)
        let location = try #require(try await session.fetchClusterSnapshot().guests.first { $0.vmid == 232 }?.node)
        let vm = GuestReference(node: location, vmid: 232, kind: .virtualMachine)
        let destroy = try await session.send(PVE.destroy(vm, purge: true, destroyUnreferencedDisks: true))
        #expect(try await finishTask(session, node: location, destroy)?.succeeded == true)
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
