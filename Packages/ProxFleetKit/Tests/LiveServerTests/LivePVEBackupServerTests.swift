import Foundation
import PBSKit
import ProxmoxCore
import ProxmoxURLSession
import PVEKit
import Testing

/// Both test servers: the Proxmox VE cluster from `PROXFLEET_TEST_SERVER_ENV`, with the storage `pbs-test` and the
/// backups of guests 200 and 102 that `scripts/seed-backup-server.py` adds, and the backup server behind it from
/// `PROXFLEET_PBS_TEST_SERVER_ENV`. Without both, every test in this file is skipped.
private struct LiveServerPair {
    var pve: [String: String]
    var pbs: [String: String]

    static let current: LiveServerPair? = {
        guard let pve = values(of: "PROXFLEET_TEST_SERVER_ENV"), let pbs = values(of: "PROXFLEET_PBS_TEST_SERVER_ENV") else { return nil }
        return LiveServerPair(pve: pve, pbs: pbs)
    }()

    private static func values(of variable: String) -> [String: String]? {
        guard let path = ProcessInfo.processInfo.environment[variable], let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[1].isEmpty { values[parts[0]] = parts[1] }
        }
        return values
    }
}

@Suite(.enabled(if: LiveServerPair.current != nil, "Set PROXFLEET_TEST_SERVER_ENV and PROXFLEET_PBS_TEST_SERVER_ENV to run against both servers"),
       .serialized, .timeLimit(.minutes(8)))
struct LivePVEBackupServerTests {
    private let servers = LiveServerPair.current!
    private let storage = "pbs-test"

    /// Signs in with a session that trusts the certificate with the fingerprint from the env file.
    private func signIn(_ values: [String: String], product: ProxmoxProduct, defaultPort: Int) async throws -> ProxmoxSession {
        let address = try #require(ServerAddress(parsing: values["ADDRESS"] ?? "", defaultPort: defaultPort))
        let transport = URLSessionTransport()
        if let fingerprint = values["FINGERPRINT"] { transport.pin(fingerprint.uppercased()) }
        let session = ProxmoxSession(address: address, product: product, transport: transport)
        let outcome = try await session.login(username: try #require(values["USER"]), password: try #require(values["PASSWORD"]), realm: values["REALM"])
        guard case .authenticated = outcome else { throw ProxmoxError.invalidResponse("expected a full ticket") }
        return session
    }

    private func pveSession() async throws -> ProxmoxSession {
        try await signIn(servers.pve, product: .virtualEnvironment, defaultPort: 8006)
    }

    /// The seeded guest and the node it runs on.
    private func guest(_ vmid: Int, _ session: ProxmoxSession) async throws -> GuestReference {
        let guest = try #require(try await session.fetchClusterSnapshot().guests.first { $0.vmid == vmid }, "guest \(vmid) from the seed script")
        return GuestReference(node: guest.node, vmid: vmid, kind: guest.kind)
    }

    private func newestBackup(of guest: GuestReference, _ session: ProxmoxSession) async throws -> BackupVolume {
        let backups = try await session.send(PVE.backups(node: guest.node, storage: storage, vmid: guest.vmid))
        return try #require(backups.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }, "a backup of \(guest.vmid) on \(storage)")
    }

    private func finish(_ session: ProxmoxSession, node: String, _ upid: String, timeout: TimeInterval = 240) async throws -> TaskStatus {
        for _ in 0..<Int(timeout * 2) {
            let status = try await session.send(PVE.taskStatus(node: node, upid: upid))
            if !status.isRunning { return status }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ProxmoxError.invalidResponse("task \(upid) did not finish")
    }

    private func list(_ session: ProxmoxSession, node: String, _ backup: BackupVolume, _ filePath: String) async throws -> [CatalogEntry] {
        // Inside a VM disk the node boots a restore VM first and answers 503 until it is up.
        for _ in 0..<12 {
            do {
                return try await session.send(PVE.fileRestoreList(node: node, storage: storage, volume: backup.volumeID, filePath: filePath))
            } catch ProxmoxError.api(503, _, _) {
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw ProxmoxError.invalidResponse("the restore VM did not start")
    }

    private func download(_ session: ProxmoxSession, node: String, _ backup: BackupVolume, _ entry: CatalogEntry, tar: Bool = false) async throws -> Data {
        let url = try await session.download(PVE.fileRestoreDownload(node: node, storage: storage, volume: backup.volumeID, filePath: entry.filePath, tar: tar))
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    // MARK: - File restore

    @Test func filesOfAContainerBackup() async throws {
        let session = try await pveSession()
        let container = try await guest(200, session)
        let backup = try await newestBackup(of: container, session)
        #expect(backup.format == "pbs-ct" && backup.isOnBackupServer)

        let root = try await list(session, node: container.node, backup, "/")
        let archive = try #require(root.first { $0.name.hasSuffix(".pxar.didx") }, "an archive in \(root.map(\.name))")
        #expect(archive.isDirectory)
        let top = try await list(session, node: container.node, backup, archive.filePath)
        let etc = try #require(top.first { $0.name == "etc" })
        #expect(etc.isDirectory && etc.decodedPath?.hasSuffix("/etc") == true)
        let files = try await list(session, node: container.node, backup, etc.filePath)
        let hostname = try #require(files.first { $0.name == "hostname" })
        #expect(hostname.kind == .file)

        // The file holds the container's host name, as its configuration has it.
        let config = try await session.send(PVE.guestConfig(container))
        let text = String(decoding: try await download(session, node: container.node, backup, hostname), as: UTF8.self)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == config["hostname"])
        #expect(Int64(text.utf8.count) == hostname.size)

        let zip = try await download(session, node: container.node, backup, etc)
        #expect(zip.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        let tar = try await download(session, node: container.node, backup, etc, tar: true)
        #expect(tar.prefix(4) == Data([0x28, 0xB5, 0x2F, 0xFD]), "zstd magic")
        await #expect(throws: ProxmoxError.self) {
            _ = try await list(session, node: container.node, backup, Data("root.pxar.didx/pflive-missing".utf8).base64EncodedString())
        }
    }

    @Test func disksOfAVMBackup() async throws {
        let session = try await pveSession()
        let vm = try await guest(102, session)
        let backup = try await newestBackup(of: vm, session)
        #expect(backup.format == "pbs-vm")
        let disk = try #require(try await list(session, node: vm.node, backup, "/").first { $0.name.hasSuffix(".img.fidx") })
        #expect(disk.kind == .virtual && disk.isDirectory)
        // The seeded VM has an empty disk: the restore VM finds no partitions or file systems on it.
        let partitions = try await list(session, node: vm.node, backup, disk.filePath)
        #expect(partitions.allSatisfy { $0.isDirectory })
    }

    @Test func backupsElsewhereCannotBeBrowsed() async throws {
        let session = try await pveSession()
        let container = try await guest(200, session)
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.send(PVE.fileRestoreList(node: container.node, storage: "local", volume: "local:backup/vzdump-lxc-200-2026_01_01-00_00_00.tar.zst", filePath: "/"))
        }
    }

    // MARK: - Backups

    /// A container backup that finds changes by metadata stores a split archive; the backup is removed afterwards.
    @Test func containerBackupWithMetadataChangeDetection() async throws {
        let session = try await pveSession()
        let container = try await guest(200, session)
        let before = Set(try await session.send(PVE.backups(node: container.node, storage: storage, vmid: 200)).map(\.volumeID))
        var draft = BackupDraft(guest: container)
        draft.storage = storage
        draft.notes = "pflive change detection"
        draft.pbsChangeDetection = "metadata"
        let status = try await finish(session, node: container.node, try await session.send(PVE.backupNow(draft)))
        #expect(status.succeeded)
        let backup = try #require(try await session.send(PVE.backups(node: container.node, storage: storage, vmid: 200)).first { !before.contains($0.volumeID) })
        #expect(backup.notes == "pflive change detection")

        // The backup server has the metadata and payload halves.
        let backupServer = try await signIn(servers.pbs, product: .backupServer, defaultPort: 8007)
        let reference = BackupGroupReference(namespace: BackupNamespace("pve"), type: .ct, backupID: "200").snapshot(at: Int(try #require(backup.date).timeIntervalSince1970))
        let names = try await backupServer.send(PBS.snapshotFiles("store1", reference)).map(\.name)
        #expect(names.contains("root.mpxar.didx") && names.contains("root.ppxar.didx"), "files: \(names)")
        // File restore reads the split archive through its metadata half.
        let root = try await list(session, node: container.node, backup, "/")
        #expect(root.contains { $0.name.hasPrefix("root.") && $0.isDirectory }, "entries: \(root.map(\.name))")

        if let upid = try await session.send(PVE.deleteBackup(node: container.node, volume: backup.volumeID)) {
            #expect(try await finish(session, node: container.node, upid).succeeded)
        }
    }

    /// A VM restored from the backup server starts at once while its disk is copied in the background.
    @Test func liveRestoreAsANewVM() async throws {
        let session = try await pveSession()
        let vm = try await guest(102, session)
        let backup = try await newestBackup(of: vm, session)
        for leftover in try await session.fetchClusterSnapshot().guests where leftover.name == "pflive-live-restore" {
            let reference = GuestReference(node: leftover.node, vmid: leftover.vmid, kind: leftover.kind)
            if leftover.state == .running { _ = try await finish(session, node: leftover.node, try await session.send(PVE.powerAction(.stop, on: reference))) }
            _ = try await finish(session, node: leftover.node, try await session.send(PVE.destroy(reference, purge: true, destroyUnreferencedDisks: true)))
        }

        var restore = RestoreDraft(backup: backup, source: vm)
        restore.overwrites = false
        restore.vmid = try await session.send(PVE.nextVMID()).value
        restore.storage = "local-lvm"
        restore.liveRestore = true
        restore.uniqueMACAddresses = true
        restore.name = "pflive-live-restore"
        restore.memoryMiB = 512
        #expect(restore.problems.isEmpty)
        #expect(restore.parameters["live-restore"] == .bool(true) && restore.parameters["start"] == nil)
        let restored = restore.target
        let status = try await finish(session, node: vm.node, try await session.send(PVE.restore(restore)))
        #expect(status.succeeded, "\(status)")

        let state = try await session.send(PVE.guestStatus(restored))
        #expect(state.status == "running")
        let config = try await session.send(PVE.guestConfig(restored))
        #expect(config.name == "pflive-live-restore" && config["memory"] == "512")
        #expect(config["scsi0"]?.hasPrefix("local-lvm:vm-\(restored.vmid)-disk-0") == true)
        #expect(config["net0"]?.contains("BC:24:11:38:66:3A") == false)

        _ = try await finish(session, node: vm.node, try await session.send(PVE.powerAction(.stop, on: restored)))
        #expect(try await finish(session, node: vm.node, try await session.send(PVE.destroy(restored, purge: true, destroyUnreferencedDisks: true))).succeeded)
    }

    // MARK: - Storage

    /// Adds a second storage for the backup server like the Add Storage form does: scan, fingerprint, a namespace
    /// and a generated encryption key; then changes the namespace and removes the key before deleting it.
    @Test func backupServerStorageWithNamespaceAndEncryption() async throws {
        let session = try await pveSession()
        let node = try await guest(200, session).node
        let address = try #require(ServerAddress(parsing: servers.pbs["ADDRESS"] ?? "", defaultPort: 8007))
        let user = try #require(servers.pbs["PVE_BACKUP_USER"])
        let password = try #require(servers.pbs["PVE_BACKUP_PASSWORD"])
        let fingerprint = try #require(servers.pbs["FINGERPRINT"])
        let id = "pflive-pbs"
        _ = try? await session.send(PVE.deleteStorage(id))

        let stores = try await session.send(PVE.scanPBS(node: node, server: address.host, username: user, password: password, fingerprint: fingerprint, port: address.port))
        #expect(stores.map(\.name).contains("store1"))
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.send(PVE.scanPBS(node: node, server: address.host, username: user, password: "not-the-password", fingerprint: fingerprint, port: address.port))
        }

        var draft = StorageConfigDraft(type: .pbs)
        draft.storage = id
        draft.server = address.host
        draft.port = address.port == 8007 ? "" : String(address.port)
        draft.datastore = "store1"
        draft.username = user
        draft.password = password
        draft.fingerprint = fingerprint
        draft.namespace = "pve/nested"
        draft.encryptionMode = .autogenerate
        #expect(draft.problems(isNew: true).isEmpty)
        let created = try await session.send(PVE.createStorage(draft))
        do {
            // The generated key is shown once, as the JSON of a key file.
            #expect(created?.encryptionKey?.contains("\"kdf\"") == true)
            let stored = try #require(StorageConfigDraft(try await session.send(PVE.storageConfig(id))))
            #expect(stored.namespace == "pve/nested" && stored.hasEncryptionKey && stored.datastore == "store1")
            let status = try await session.send(PVE.storageStatus(node: node, storage: id))
            #expect(status.isActive && status.total > 0)
            #expect(try await session.send(PVE.backups(node: node, storage: id)).isEmpty)

            // In the seed's namespace, the storage sees the seeded backups; without a key, it is not encrypted anymore.
            var edited = stored
            edited.namespace = "pve"
            edited.encryptionMode = .none
            let update = edited.changes(from: stored)
            #expect(update.parameters["namespace"] == "pve")
            _ = try await session.send(PVE.updateStorage(id, update))
            let changed = try #require(StorageConfigDraft(try await session.send(PVE.storageConfig(id))))
            #expect(changed.namespace == "pve" && !changed.hasEncryptionKey)
            let backups = try await session.send(PVE.backups(node: node, storage: id))
            #expect(Set(backups.compactMap(\.vmid)).isSuperset(of: [102, 200]))
        } catch {
            _ = try? await session.send(PVE.deleteStorage(id))
            throw error
        }
        _ = try await session.send(PVE.deleteStorage(id))
        #expect(try await session.send(PVE.storageConfigs()).contains { $0.storage == id } == false)
    }
}
