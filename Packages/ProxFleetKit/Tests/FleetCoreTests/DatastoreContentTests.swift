import DemoServer
@testable import FleetCore
import Foundation
import PBSKit
import ProxmoxCore
import Testing

@MainActor
struct DatastoreContentTests {
    private func connectedDemo() async throws -> ServerConnection {
        let fleet = Fleet(environment: FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in
            DemoBackupServerTransport()
        })
        let profile = fleet.addSaved(ServerProfile(name: "pbs", product: .backupServer, addresses: [ServerAddress(host: "pbs.lan", port: 8007)],
                                                   username: "root", realm: "pam"), password: "secret")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        return connection
    }

    private func groupDetail(_ connection: ServerConnection, _ type: BackupType, _ id: String, namespace: String = "homelab") async throws -> BackupGroupDetail {
        let content = DatastoreContent(store: "main", namespace: BackupNamespace(namespace), connection: connection)
        await content.load()
        let group = try #require(content.groups?.first { $0.reference.type == type && $0.reference.backupID == id })
        let detail = BackupGroupDetail(store: "main", group: group, connection: connection)
        await detail.load()
        return detail
    }

    @Test func namespacesAndGroups() async throws {
        let connection = try await connectedDemo()
        let root = DatastoreContent(store: "main", connection: connection)
        await root.load()
        #expect(root.namespaces?.map(\.path) == ["homelab", "laptops"])
        #expect(root.groups?.map(\.reference.path) == ["host/pbs"])
        let homelab = DatastoreContent(store: "main", namespace: BackupNamespace("homelab"), connection: connection)
        await homelab.load()
        // VMs, then containers, each by ID.
        #expect(homelab.groups?.map(\.reference.path) == ["vm/100", "vm/101", "vm/103", "vm/104", "ct/200", "ct/201", "ct/202"])
        #expect(homelab.groups?.first?.reference.namespace == BackupNamespace("homelab"))
        #expect(homelab.groups?.first?.comment == "home-assistant")
        #expect(homelab.aclPath == "/datastore/main/homelab")

        try await homelab.createNamespace("archive")
        #expect(homelab.namespaces?.map(\.path) == ["homelab/archive"])
        let empty = try await homelab.deleteNamespace(BackupNamespace("homelab/archive"), deleteGroups: false)
        #expect(empty?.removedSnapshots == 0)
        #expect(homelab.namespaces?.isEmpty == true)
    }

    @Test func groupsWithSnapshotsAndNotes() async throws {
        let connection = try await connectedDemo()
        let detail = try await groupDetail(connection, .vm, "100")
        let snapshots = try #require(detail.snapshots)
        #expect(snapshots.count == 11)
        #expect(snapshots.map(\.reference.time) == snapshots.map(\.reference.time).sorted(by: >))
        #expect(snapshots.first?.verification == nil)
        #expect(snapshots.contains { $0.isProtected && $0.comment == "Before the 2026.10 update" })
        #expect(detail.notes == "home-assistant")
        #expect(detail.owner == "backup@pbs")

        try await detail.setNotes("Home Assistant OS\nUpdated monthly")
        #expect(detail.notes == "Home Assistant OS\nUpdated monthly")
        let newest = try #require(snapshots.first)
        try await detail.setProtected(newest.reference, true)
        #expect(detail.snapshots?.first?.isProtected == true)
        await #expect(throws: ConfigUpdateError.self) { try await detail.deleteSnapshot(newest.reference) }
        try await detail.setProtected(newest.reference, false)
        try await detail.deleteSnapshot(newest.reference)
        #expect(detail.snapshots?.count == 10)
    }

    @Test func pruneLikeTheServer() async throws {
        let connection = try await connectedDemo()
        let detail = try await groupDetail(connection, .vm, "100")
        // Keep the last two: the protected snapshot stays as well.
        let preview = try await detail.previewPrune(keep: RetentionPolicy(last: 2))
        #expect(preview.count == 11)
        #expect(preview.filter { $0.keep }.count == 3)
        #expect(preview.filter { $0.isProtected }.allSatisfy { $0.keep })
        // Without rules nothing is removed.
        #expect(try await detail.previewPrune(keep: RetentionPolicy()).allSatisfy { $0.keep })
        let task = try await detail.prune(keep: RetentionPolicy(last: 2))
        #expect(task.upid.type == "prune")
        #expect(await connection.tasks.result(of: task.id) == .succeeded)
        await detail.load()
        #expect(detail.snapshots?.count == 3)
    }

    @Test func ownerMoveAndDeletion() async throws {
        let connection = try await connectedDemo()
        let detail = try await groupDetail(connection, .ct, "201")
        try await detail.changeOwner(to: "anna@pbs")
        #expect(detail.owner == "anna@pbs")
        let move = try await detail.move(to: BackupNamespace("laptops"), merge: true)
        #expect(move.title == "main ct/201 → laptops – Move Group")
        #expect(await connection.tasks.result(of: move.id) == .succeeded)
        let laptops = DatastoreContent(store: "main", namespace: BackupNamespace("laptops"), connection: connection)
        await laptops.load()
        #expect(laptops.groups?.contains { $0.reference.path == "ct/201" } == true)

        // The protected snapshot keeps the group alive.
        let protected = try await groupDetail(connection, .vm, "100")
        let result = try #require(try await protected.delete())
        #expect(result.protectedSnapshots == 1)
        #expect(result.removedSnapshots == 10)
        #expect(result.removedGroups == 0)
    }

    @Test func browsesAndDownloadsFiles() async throws {
        let connection = try await connectedDemo()
        let group = try await groupDetail(connection, .ct, "200")
        let snapshot = try #require(group.snapshots?.first)
        let detail = SnapshotDetail(store: "main", reference: snapshot.reference, connection: connection)
        await detail.loadNotes()
        #expect(detail.notes == "pihole")

        let archives = try await detail.catalog("/", archive: nil)
        #expect(archives.map(\.name) == ["root.pxar.didx"])
        let top = try await detail.catalog(try #require(archives.first).filePath, archive: nil)
        #expect(top.map(\.name) == ["etc", "root", "var"])
        let etc = try #require(top.first)
        let files = try await detail.catalog(etc.filePath, archive: nil)
        // Directories first.
        #expect(files.map(\.name) == ["pihole", "hostname", "hosts", "resolv.conf"])
        let hostname = try #require(files.first { $0.name == "hostname" })

        let file = try await detail.download(hostname, archive: nil)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(file.lastPathComponent == "ct-200-hostname")
        #expect(try String(contentsOf: file, encoding: .utf8) == "pihole\n")

        let zip = try await detail.download(etc, archive: nil)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        #expect(zip.lastPathComponent == "ct-200-etc.zip")
        #expect(try Data(contentsOf: zip).prefix(2) == Data("PK".utf8))

        let config = try #require(snapshot.files.first { $0.name == "pct.conf.blob" })
        #expect(try await detail.text(of: config).contains("hostname: pihole"))
    }
}
