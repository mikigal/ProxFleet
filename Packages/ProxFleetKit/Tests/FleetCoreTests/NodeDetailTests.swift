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

    @Test func stoppedTaskFailsWithoutAnAlert() async throws {
        let connection = try await connection()
        let upid = try #require(try await connection.send(PVE.refreshPackageIndex(node: "pve1")))
        let task = try connection.tasks.track(upid)
        #expect(await connection.canStopTask(startedBy: task.upid.user, node: "pve1"))
        try await connection.stopTask(node: "pve1", upid: upid)
        #expect(await connection.tasks.result(of: task.id) == .failed("interrupted by signal"))
        #expect(connection.tasks.unreportedFailure == nil)
        let log = try await connection.send(PVE.taskLog(node: "pve1", upid: upid))
        #expect(log.map(\.text) == ["TASK ERROR: interrupted by signal"])
    }

    @Test func auditorCannotStopOthersTasks() async throws {
        let root = try await connection()
        let upid = try #require(try await root.send(PVE.refreshPackageIndex(node: "pve1")))
        let auditor = try await connection(username: "auditor")
        #expect(await !auditor.canStopTask(startedBy: "root@pve", node: "pve1"))
        await #expect(throws: ProxmoxError.self) { try await auditor.stopTask(node: "pve1", upid: upid) }
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

    @Test func systemSettings() async throws {
        let detail = NodeDetail(node: "pve1", connection: try await connection())
        #expect(await detail.loadSystemSettings() == nil)
        #expect(detail.dns?.searchDomain == "home.arpa")
        #expect(detail.hosts?.text.contains("10.0.10.11 pve1.home.arpa pve1") == true)
        #expect(detail.time?.timeZone == "Europe/Berlin")

        try await detail.saveDNS(NodeDNS(searchDomain: "lab.example", servers: ["", "9.9.9.9", ""]))
        #expect(detail.dns == NodeDNS(searchDomain: "lab.example", servers: ["9.9.9.9"]))
        await #expect(throws: ConfigUpdateError.invalid(message: "Parameter verification failed.", fields: ["dns1": "value does not look like a valid IP address"])) {
            try await detail.saveDNS(NodeDNS(searchDomain: "lab", servers: ["nope"]))
        }

        let text = (detail.hosts?.text ?? "") + "10.0.10.50 nas\n"
        try await detail.saveHosts(text)
        #expect(detail.hosts?.text == text)

        try await detail.setTimeZone("Europe/Warsaw")
        #expect(detail.time?.timeZone == "Europe/Warsaw")
        await #expect(throws: ConfigUpdateError.self) { try await detail.setTimeZone("Mars/Olympus") }
    }

    @Test func hostsConflictWhenChangedElsewhere() async throws {
        let connection = try await connection()
        let first = NodeDetail(node: "pve1", connection: connection)
        let second = NodeDetail(node: "pve1", connection: connection)
        await first.loadSystemSettings()
        await second.loadSystemSettings()
        try await first.saveHosts("127.0.0.1 localhost\n")
        await #expect(throws: ConfigUpdateError.conflict) { try await second.saveHosts("127.0.0.1 other\n") }
    }

    @Test func networkChangesWaitForApply() async throws {
        let connection = try await connection()
        let detail = NodeDetail(node: "pve1", connection: connection)
        #expect(await detail.loadNetwork() == nil)
        let network = try #require(detail.network)
        #expect(network.pendingChanges == nil)
        #expect(network.sortedInterfaces.map(\.name) == ["nic0", "nic1", "vmbr0", "vmbr1"])

        var bridge = NetworkInterfaceDraft(creating: .bridge, existing: network.interfaces)
        #expect(bridge.name == "vmbr2")
        bridge.cidr = "192.168.50.1/24"
        bridge.comments = "Isolated"
        try await detail.createInterface(bridge)
        let pending = try #require(detail.network?.pendingChanges)
        #expect(pending.contains("+auto vmbr2") && pending.contains("+\taddress 192.168.50.1/24"))
        #expect(detail.network?.interfaces.first { $0.name == "vmbr2" }?.isActive == false)

        // Proxmox refuses a second default gateway and ports used elsewhere.
        var other = NetworkInterfaceDraft(creating: .bridge, existing: detail.network?.interfaces ?? [])
        other.gateway = "192.168.60.254"
        other.cidr = "192.168.60.1/24"
        other.bridgePorts = ["nic0"]
        await #expect(throws: ConfigUpdateError.self) { try await detail.createInterface(other) }

        let vmbr1 = try #require(detail.network?.interfaces.first { $0.name == "vmbr1" })
        var edit = NetworkInterfaceDraft(vmbr1)
        edit.mtu = "9000"
        edit.vlanAware = false
        try await detail.updateInterface("vmbr1", type: "bridge", edit.changes(from: NetworkInterfaceDraft(vmbr1)))
        let edited = try #require(detail.network?.interfaces.first { $0.name == "vmbr1" })
        #expect(edited.mtu == 9000 && !edited.bridgeVLANAware && edited.bridgeVIDs == nil)

        try await detail.revertNetwork()
        #expect(detail.network?.pendingChanges == nil)
        #expect(detail.network?.interfaces.count == 4)

        try await detail.createInterface(bridge)
        try await detail.applyNetwork()
        #expect(detail.network?.pendingChanges == nil)
        #expect(detail.network?.interfaces.first { $0.name == "vmbr2" }?.isActive == true)
        #expect(try await connection.send(PVE.bridges(node: "pve1")).map(\.name).contains("vmbr2"))

        try await detail.deleteInterface("vmbr2")
        #expect(detail.network?.pendingChanges?.contains("-auto vmbr2") == true)
    }

    @Test func auditorCannotChangeSettings() async throws {
        let detail = NodeDetail(node: "pve1", connection: try await connection(username: "auditor"))
        await detail.loadSystemSettings()
        await #expect(throws: ConfigUpdateError.self) { try await detail.setTimeZone("UTC") }
        await detail.loadNetwork()
        await #expect(throws: ConfigUpdateError.self) { try await detail.revertNetwork() }
    }

    @Test func disksAndStorage() async throws {
        let connection = try await connection()
        let detail = NodeDetail(node: "pve1", connection: connection)
        #expect(await detail.loadDisks() == nil)
        let disks = try #require(detail.disks)
        #expect(NodeDisk.grouped(disks).map(\.disk.name) == ["nvme0n1", "sda", "sdb", "sdc", "sdd"])
        #expect(detail.zfsPools?.map(\.name) == ["tank"])
        #expect(detail.volumeGroups?.map(\.name) == ["pve"] && detail.thinPools?.map(\.name) == ["data"])
        let tank = try await detail.zfsStatus(of: "tank").devices.flatMap { $0.flattened() }
        #expect(tank.map(\.device.displayName) == ["tank", "mirror-0", "ata-sda-part1", "ata-sdb-part1"])
        #expect(try await detail.smart(of: "/dev/sdd").attributes.contains { $0.id == 9 })
        #expect(try await detail.smart(of: "/dev/nvme0n1").text?.contains("Percentage Used") == true)

        var draft = DiskStorageDraft(kind: .zfs)
        draft.name = "fast"
        draft.raidLevel = "mirror"
        draft.devices = ["/dev/sdc", "/dev/sdd"]
        // zpool refuses a mirror of disks with different sizes; the form catches it before sending.
        draft.deviceSizes = Dictionary(uniqueKeysWithValues: disks.map { ($0.path, $0.size) })
        #expect(draft.problems["devices"] == "mirror needs disks of the same size.")
        await #expect(throws: ConfigUpdateError.self) { try await detail.createDiskStorage(draft) }
        draft.raidLevel = "single"
        try await detail.createDiskStorage(draft)
        #expect(detail.zfsPools?.map(\.name) == ["tank", "fast"])
        #expect(detail.disks?.first { $0.path == "/dev/sdc" }?.usage == "partitions")
        #expect(detail.disks?.first { $0.path == "/dev/sdc1" }?.usage == "ZFS")
        #expect(connection.tasks.tasks.first?.title == "fast – Create ZFS Pool")

        await #expect(throws: ConfigUpdateError.self) { try await detail.wipe("/dev/sdc") }
        try await detail.deleteDiskStorage(.zfs, name: "fast", cleanupConfig: true, wipeDisks: true)
        #expect(detail.disks?.first { $0.path == "/dev/sdc" }?.isUnused == true)
        try await detail.initializeGPT("/dev/sdc")
        #expect(detail.disks?.first { $0.path == "/dev/sdc" }?.hasGPT == true)
        try await detail.wipe("/dev/sdc")
        #expect(detail.disks?.first { $0.path == "/dev/sdc" }?.hasGPT == false)
    }

    @Test func repositoriesAndCertificates() async throws {
        let connection = try await connection()
        let detail = NodeDetail(node: "pve2", connection: connection)
        #expect(await detail.loadRepositories() == nil)
        let repositories = try #require(detail.repositories)
        #expect(repositories.hasEnabledProxmoxRepository && !repositories.hasEnabledEnterpriseRepository)
        #expect(detail.subscription?.isActive == false)
        let enterprise = try #require(repositories.repositories.first { $0.isEnterprise })
        try await detail.setRepository(enterprise, enabled: true)
        #expect(detail.repositories?.hasEnabledEnterpriseRepository == true)
        try await detail.addStandardRepository("test")
        #expect(detail.repositories?.repositories.contains { $0.components == ["pve-test"] && $0.isEnabled } == true)
        #expect(detail.repositories?.standardRepositories.first { $0.handle == "test" }?.isEnabled == true)

        #expect(await detail.loadCertificates() == nil)
        #expect(detail.certificates?.map(\.fileName) == ["pve-root-ca.pem", "pve-ssl.pem"])
        var draft = CustomCertificateDraft()
        draft.certificates = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
        try await detail.uploadCertificate(draft)
        #expect(detail.certificates?.last?.isCustom == true)
        try await detail.deleteCustomCertificate()
        #expect(detail.certificates?.contains { $0.isCustom } == false)
    }
}
