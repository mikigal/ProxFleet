import DemoServer
@testable import FleetCore
import Foundation
import PBSKit
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct BackupServerNodeTests {
    private func demoServer() async throws -> NodeDetail {
        let fleet = Fleet(environment: FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in
            DemoBackupServerTransport()
        })
        let profile = fleet.addSaved(ServerProfile(name: "pbs", product: .backupServer, addresses: [ServerAddress(host: "pbs.lan", port: 8007)],
                                                   username: "root", realm: "pam"), password: "secret")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        let node = NodeDetail(node: PBS.node, connection: connection)
        await node.load()
        return node
    }

    @Test func statusHistoryAndPrivilegesOnSystem() async throws {
        let node = try await demoServer()
        #expect(node.isBackupServer)
        #expect(node.privilegePath == "/system")
        #expect(node.status != nil)
        #expect(!node.history.isEmpty)
        #expect(node.isOnline)
        // Granted as Sys.PowerManagement, asked as Proxmox VE's Sys.PowerMgmt.
        #expect(node.can("Sys.PowerMgmt"))
        #expect(node.privilegeName("Sys.PowerMgmt") == "Sys.PowerManagement")
        #expect(node.privilegeName("Sys.Modify") == "Sys.Modify")
    }

    @Test func servicesUpdatesJournalAndReport() async throws {
        let node = try await demoServer()
        #expect(await node.loadServices() == nil)
        #expect(node.services?.map(\.name).contains("proxmox-backup-proxy") == true)
        let postfix = try #require(node.services?.first { $0.name == "postfix" })
        try await node.perform(.stop, on: postfix)
        #expect(node.services?.first { $0.name == "postfix" }?.isRunning == false)
        try await node.perform(.start, on: postfix)
        #expect(node.services?.first { $0.name == "postfix" }?.isRunning == true)

        #expect(await node.loadUpdates() == nil)
        #expect(node.updates?.first?.package == "proxmox-backup-server")
        try await node.refreshPackageIndex()
        #expect(await node.loadJournal(lastEntries: 20) == nil)
        #expect(node.journal?.count == 20)
        #expect(node.journal?.contains { $0.hasPrefix("s=") } == false)
        #expect(try await node.connection.send(PVE.systemReport(node: node.node)).contains("Datastores"))
        try await node.power(.reboot)
    }

    @Test func repositoriesAndCertificates() async throws {
        let node = try await demoServer()
        #expect(await node.loadRepositories() == nil)
        let repositories = try #require(node.repositories)
        let noSubscription = try #require(repositories.files.flatMap(\.repositories).first { $0.components.contains("pbs-no-subscription") })
        try await node.setRepository(noSubscription, enabled: false)
        #expect(node.repositories?.files.flatMap(\.repositories).first { $0.components.contains("pbs-no-subscription") }?.isEnabled == false)
        try await node.addStandardRepository("test")
        #expect(node.repositories?.files.flatMap(\.repositories).contains { $0.components.contains("pbs-test") } == true)

        #expect(await node.loadCertificates() == nil)
        #expect(node.certificates?.map(\.fileName) == ["proxy.pem"])
        var draft = CustomCertificateDraft()
        draft.certificates = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
        try await node.uploadCertificate(draft)
        #expect(node.certificates?.first?.subject.contains("pbs.example.net") == true)
    }

    @Test func dnsTimeAndOptions() async throws {
        let node = try await demoServer()
        #expect(await node.loadSystemSettings() == nil)
        // A backup server has no hosts file to edit.
        #expect(node.hosts == nil)
        var dns = try #require(node.dns)
        #expect(dns.servers.first == "10.0.10.1")
        dns.servers = ["10.0.10.53", "", ""]
        try await node.saveDNS(dns)
        #expect(node.dns?.servers.first == "10.0.10.53")
        try await node.setTimeZone("Europe/Warsaw")
        #expect(node.time?.timeZone == "Europe/Warsaw")

        #expect(await node.loadOptions() == nil)
        let options = try #require(node.backupServerOptions)
        let original = BackupServerNodeOptionsDraft(options)
        var draft = original
        draft.httpProxy = "http://proxy.lan:3128"
        draft.taskLogMaxDays = nil
        try await node.saveBackupServerOptions(draft.changes(from: original))
        let saved = node.backupServerOptions?.values ?? [:]
        #expect(saved["http-proxy"] == "http://proxy.lan:3128")
        #expect(saved["task-log-max-days"] == nil)
        // The server refuses what the form would catch first.
        var invalid = BackupServerNodeOptionsDraft(try #require(node.backupServerOptions))
        let current = invalid
        invalid.httpProxy = "proxy lan"
        await #expect(throws: ConfigUpdateError.self) { try await node.saveBackupServerOptions(invalid.changes(from: current)) }
    }

    @Test func networkChangesArePendingUntilApplied() async throws {
        let node = try await demoServer()
        #expect(await node.loadNetwork() == nil)
        let network = try #require(node.network)
        #expect(network.interfaces.first { $0.name == "vmbr0" }?.bridgePorts == ["eno1"])
        #expect(network.pendingChanges == nil)

        var bridge = NetworkInterfaceDraft(creating: .bridge, existing: network.interfaces)
        bridge.bridgePorts = ["eno2"]
        bridge.vlanAware = true
        bridge.bridgeVIDs = "2-100"
        bridge.comments = "Backup network"
        try await node.createInterface(bridge)
        let created = try #require(node.network?.interfaces.first { $0.name == bridge.name })
        #expect(created.bridgePorts == ["eno2"])
        #expect(node.network?.pendingChanges?.contains(bridge.name) == true)

        var edited = NetworkInterfaceDraft(created)
        edited.comments = ""
        edited.bridgePorts = []
        try await node.updateInterface(created.name, type: created.type, edited.changes(from: NetworkInterfaceDraft(created)))
        #expect(node.network?.interfaces.first { $0.name == bridge.name }?.bridgePorts.isEmpty == true)
        #expect(node.network?.interfaces.first { $0.name == bridge.name }?.comments == nil)

        try await node.applyNetwork()
        #expect(node.network?.pendingChanges == nil)
        try await node.deleteInterface(bridge.name)
        try await node.revertNetwork()
        #expect(node.network?.interfaces.contains { $0.name == bridge.name } == true)
    }

    @Test func disksDirectoriesAndPools() async throws {
        let node = try await demoServer()
        #expect(await node.loadDisks() == nil)
        let disks = try #require(node.disks)
        #expect(NodeDisk.grouped(disks).map(\.disk.name) == ["nvme0n1", "sda", "sdb", "sdc", "sdd"])
        #expect(disks.first { $0.name == "sdd" }?.isUnused == true)
        #expect(node.zfsPools?.map(\.name) == ["main"])
        #expect(node.volumeGroups?.isEmpty == true)
        #expect(try await node.smart(of: "/dev/sda").health == "PASSED")
        #expect(try await node.zfsStatus(of: "main").state == "ONLINE")
        // Disks in a pool stay as they are.
        await #expect(throws: ConfigUpdateError.self) { try await node.wipe("/dev/sda") }

        var draft = DiskStorageDraft(kind: .directory)
        draft.name = "usb-copy"
        draft.devices = ["/dev/sdd"]
        let stores = node.connection.backupServer?.datastores.map(\.store) ?? []
        #expect(draft.backupServerProblems(existingDatastores: stores).isEmpty)
        try await node.createDiskStorage(draft)
        #expect(node.directories?.map(\.name) == ["usb-copy"])
        #expect(node.disks?.first { $0.name == "sdd" }?.usage == "partitions")
        #expect(node.connection.backupServer?.datastores.contains { $0.store == "usb-copy" } == true)
        // The datastore needs its mount.
        await #expect(throws: ConfigUpdateError.self) {
            try await node.deleteDiskStorage(.directory, name: "usb-copy", cleanupConfig: false, wipeDisks: false)
        }
    }
}
