import DemoServer
@testable import FleetCore
import Foundation
import PBSKit
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct GuestBackupFilesTests {
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

    private func backupServerBackup(of vmid: Int, kind: GuestKind, _ connection: ServerConnection) async throws -> BackupVolume {
        let detail = GuestDetail(reference: GuestReference(node: "pve1", vmid: vmid, kind: kind), connection: connection)
        await detail.loadBackups()
        return try #require(detail.backups?.first { $0.isOnBackupServer })
    }

    @Test func containerFilesAndDownloads() async throws {
        let connection = try await connection()
        let files = GuestBackupFiles(connection: connection, node: "pve1", backup: try await backupServerBackup(of: 200, kind: .container, connection))
        let root = try await files.entries(at: files.rootPath)
        #expect(root.map(\.name) == ["root.pxar.didx"])
        let archive = try await files.entries(at: root[0].filePath)
        #expect(archive.map(\.name) == ["etc", "root", "var"])
        let etc = try await files.entries(at: archive[0].filePath)
        let hostname = try #require(etc.first { $0.name == "hostname" })
        #expect(hostname.kind == .file && hostname.size == 7)

        let file = try await files.download(hostname) { _, _ in }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(file.lastPathComponent == "ct-200-hostname")
        #expect(try String(contentsOf: file, encoding: .utf8) == "pihole\n")
        let folder = try await files.download(archive[0]) { _, _ in }
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        #expect(folder.lastPathComponent == "ct-200-etc.zip")
        #expect(try Data(contentsOf: folder).prefix(2) == Data("PK".utf8))
    }

    @Test func vmDisksWaitForTheRestoreVM() async throws {
        let connection = try await connection()
        var files = GuestBackupFiles(connection: connection, node: "pve1", backup: try await backupServerBackup(of: 100, kind: .virtualMachine, connection))
        files.retryDelay = .milliseconds(200)
        let disk = try #require(try await files.entries(at: files.rootPath).first)
        #expect(disk.name == "drive-scsi0.img.fidx" && disk.kind == .virtual)
        // The demo answers 503 for a few seconds while its restore VM "boots".
        let started = ContinuousClock.now
        let partitions = try await files.entries(at: disk.filePath)
        #expect(ContinuousClock.now - started > .seconds(2))
        #expect(partitions.map(\.name) == ["part"])
        let numbered = try await files.entries(at: partitions[0].filePath)
        #expect(numbered.map(\.name) == ["1", "2"])
        let system = try await files.entries(at: numbered[1].filePath)
        #expect(system.map(\.name) == ["etc", "home", "var"])

    }

    @Test func vmDisksFailWhenTheRestoreVMTakesTooLong() async throws {
        let connection = try await connection()
        var files = GuestBackupFiles(connection: connection, node: "pve1", backup: try await backupServerBackup(of: 100, kind: .virtualMachine, connection))
        files.startTimeout = .zero
        let disk = try #require(try await files.entries(at: files.rootPath).first)
        await #expect(throws: ProxmoxError.api(status: 503, message: "starting VM for file-restore, try again", fieldErrors: [:])) {
            try await files.entries(at: disk.filePath)
        }
    }

    @Test func backupsOnOtherStoragesAreRefused() async throws {
        let connection = try await connection()
        let detail = GuestDetail(reference: GuestReference(node: "pve1", vmid: 100, kind: .virtualMachine), connection: connection)
        await detail.loadBackups()
        let local = try #require(detail.backups?.first { !$0.isOnBackupServer })
        await #expect(throws: ProxmoxError.self) {
            try await GuestBackupFiles(connection: connection, node: "pve1", backup: local).entries(at: "/")
        }
    }
}
