import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct StorageDetailTests {
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

    @Test func browsesContentByType() async throws {
        let detail = StorageDetail(node: "pve1", storage: "local", connection: try await connection())
        await detail.load()
        #expect(detail.status?.contentTypes == [.iso, .vztmpl, .backup, .snippets, .import])
        #expect(detail.volumes(of: .iso).map(\.fileName) == ["debian-13.1.0-amd64-netinst.iso", "ubuntu-24.04.3-live-server-amd64.iso"])
        #expect(detail.volumes(of: .backup).map(\.vmid) == [100, 100, 101, 200, 202])
        #expect(detail.volumes(of: .backup).contains { $0.isProtected })

        let disks = StorageDetail(node: "pve1", storage: "local-lvm", connection: detail.connection)
        await disks.load()
        #expect(disks.volumes(of: .images).map(\.vmid) == [100, 101, 104, 9000])
        #expect(disks.volumes(of: .rootdir).map(\.vmid) == [200, 202])
        let disk = try #require(disks.volumes(of: .images).first)
        await #expect(throws: ConfigUpdateError.self) { try await disks.delete(disk) }
    }

    @Test func downloadsUploadsAndDeletes() async throws {
        let detail = StorageDetail(node: "pve1", storage: "local", connection: try await connection())
        await detail.load()
        var draft = StorageFileDraft(content: .iso)
        draft.url = "https://cdimage.example.org/debian-13.2.0-amd64-netinst.iso"
        draft.fileName = try await detail.metadata(of: draft.url, verifyCertificates: true).fileName ?? ""
        #expect(draft.fileName == "debian-13.2.0-amd64-netinst.iso")
        let task = try #require(try await detail.download(draft))
        #expect(await detail.connection.tasks.result(of: task.id) == .succeeded)
        await detail.load()
        #expect(detail.volumes(of: .iso).contains { $0.fileName == "debian-13.2.0-amd64-netinst.iso" })

        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).iso")
        try Data(repeating: 7, count: 2048).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var upload = StorageFileDraft(content: .iso)
        upload.fileName = "uploaded tools.iso"
        try await detail.upload(file, as: upload)
        #expect(detail.upload == nil)
        let uploaded = try #require(detail.volumes(of: .iso).first { $0.fileName == "uploaded tools.iso" })
        await #expect(throws: ConfigUpdateError.self) { try await detail.upload(file, as: upload) }

        try await detail.delete(uploaded)
        #expect(!detail.volumes(of: .iso).contains { $0.fileName == "uploaded tools.iso" })
    }

    @Test func auditorCannotChangeContent() async throws {
        let detail = StorageDetail(node: "pve1", storage: "local", connection: try await connection(username: "auditor"))
        await detail.load()
        #expect(!detail.can("Datastore.AllocateSpace"))
        let iso = try #require(detail.volumes(of: .iso).first)
        await #expect(throws: ConfigUpdateError.self) { try await detail.delete(iso) }
    }

    @Test func datacenterStorageDefinitions() async throws {
        let connection = try await connection()
        let storage = DatacenterStorage(connection: connection)
        await storage.load()
        #expect(storage.configs?.map(\.storage) == ["local", "local-lvm", "nas", "pbs"])
        #expect(storage.canModify && storage.scanNode == "pve1")

        let exports = try await storage.scan(PVE.scanNFS(node: "pve1", server: "10.0.10.5"))
        #expect(exports.map(\.name) == ["/mnt/tank/proxmox", "/mnt/tank/media"])
        var nfs = StorageConfigDraft(type: .nfs)
        nfs.storage = "media"
        nfs.server = "10.0.10.5"
        nfs.export = exports[1].name
        nfs.content = ["iso"]
        try await storage.create(nfs)
        #expect(storage.configs?.contains { $0.storage == "media" } == true)
        #expect(connection.snapshot?.storages.filter { $0.name == "media" }.count == 3)

        let created = try #require(storage.configs?.first { $0.storage == "media" })
        let original = try #require(StorageConfigDraft(created))
        var edit = original
        edit.nodes = ["pve1"]
        edit.isEnabled = false
        try await storage.update("media", edit.changes(from: original), digest: created.digest)
        #expect(storage.configs?.first { $0.storage == "media" }?.isDisabled == true)
        #expect(connection.snapshot?.storages.contains { $0.name == "media" } == false)
        // The first update changed the digest, so a form opened before it is refused.
        await #expect(throws: ConfigUpdateError.conflict) {
            try await storage.update("media", edit.changes(from: original), digest: created.digest)
        }

        var pbs = StorageConfigDraft(type: .pbs)
        pbs.storage = "offsite"
        pbs.server = "10.0.10.6"
        pbs.datastore = "offsite"
        pbs.username = "backup@pbs"
        pbs.password = "wrong"
        await #expect(throws: ConfigUpdateError.self) { try await storage.create(pbs) }
        await #expect(throws: (any Error).self) {
            _ = try await storage.scan(PVE.scanPBS(node: "pve1", server: "10.0.10.6", username: "backup@pbs", password: "wrong", fingerprint: nil, port: nil))
        }
        #expect(try await storage.scan(PVE.scanPBS(node: "pve1", server: "10.0.10.6", username: "backup@pbs", password: "secret", fingerprint: nil, port: nil)).map(\.name) == ["main", "offsite"])

        try await storage.delete("media")
        #expect(storage.configs?.contains { $0.storage == "media" } == false)
    }

    @Test func auditorCannotChangeStorageDefinitions() async throws {
        let storage = DatacenterStorage(connection: try await connection(username: "auditor"))
        await storage.load()
        #expect(!storage.canModify)
        await #expect(throws: ConfigUpdateError.self) { try await storage.delete("nas") }
    }

    @Test func backupJobs() async throws {
        let connection = try await connection()
        let list = BackupJobList(connection: connection)
        await list.load()
        #expect(list.jobs?.count == 2 && list.canModify)
        // The nightly job covers everything but the template; the weekly one adds nothing to that.
        #expect(list.unprotectedGuests?.map(\.vmid) == [9000])

        guard case .success(let runs) = await list.nextRuns(of: "mon..fri 21:00") else { Issue.record("schedule refused"); return }
        #expect(runs.count == 3 && runs.allSatisfy { !Calendar.current.isDateInWeekend($0) })
        guard case .failure(.invalid(_, let fields)) = await list.nextRuns(of: "whenever") else { Issue.record("schedule accepted"); return }
        #expect(fields["schedule"] != nil)

        var draft = BackupJobDraft()
        draft.storage = "nas"
        draft.schedule = "*/6:00"
        draft.selectionMode = .pool
        draft.pool = "lab"
        try await list.create(draft)
        let created = try #require(list.jobs?.first { $0.selection == .pool("lab") })
        var edit = BackupJobDraft(created)
        edit.isEnabled = false
        try await list.update(created.id, edit.changes(from: BackupJobDraft(created)))
        #expect(list.jobs?.first { $0.id == created.id }?.isEnabled == false)

        let weekly = try #require(list.jobs?.first { $0.storage == "pbs" })
        let tasks = try await list.runNow(weekly)
        #expect(tasks.count == 1)
        #expect(await connection.tasks.result(of: tasks[0].id) == .succeeded)
        let pbs = StorageDetail(node: "pve1", storage: "pbs", connection: connection)
        await pbs.load()
        #expect(pbs.volumes(of: .backup).map(\.vmid) == [100, 101, 200])

        try await list.delete(created.id)
        #expect(list.jobs?.count == 2)
    }
}
