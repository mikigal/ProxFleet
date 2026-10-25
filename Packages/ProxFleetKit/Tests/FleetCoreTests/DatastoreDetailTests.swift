import DemoServer
@testable import FleetCore
import Foundation
import PBSKit
import ProxmoxCore
import Testing

@MainActor
struct DatastoreDetailTests {
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

    @Test func loadsStatusSettingsAndHistory() async throws {
        let detail = DatastoreDetail(store: "main", connection: try await connectedDemo())
        await detail.load()
        let status = try #require(detail.status)
        #expect(status.counts[.vm]?.groups == 4)
        #expect(status.counts[.ct]?.groups == 3)
        #expect(detail.garbageCollection?.schedule == "daily")
        #expect(detail.garbageCollection?.deduplicationFactor ?? 0 > 1)
        #expect(detail.config?.verifyNew == true)
        #expect(detail.configDigest != nil)
        #expect(!detail.history.isEmpty)
        #expect(detail.can("Datastore.Modify"))
        #expect(detail.summary?.comment == "Nightly backups of the home lab")
    }

    @Test func savesOnlyChangesAndRefusesStaleOnes() async throws {
        let connection = try await connectedDemo()
        let detail = DatastoreDetail(store: "main", connection: connection)
        await detail.load()
        let original = DatastoreDraft(try #require(detail.config))
        var draft = original
        draft.comment = "Changed"
        draft.verifyNew = false
        try await detail.save(draft.changes(from: original))
        #expect(detail.config?.comment == "Changed")
        #expect(detail.config?.verifyNew == false)
        #expect(connection.backupServer?.datastores.first { $0.store == "main" }?.comment == "Changed")

        // A form opened before the change is refused.
        var stale = original.changes(from: original)
        stale.set("comment", "Old form")
        stale.digest = String(repeating: "0", count: 64)
        await #expect(throws: ConfigUpdateError.conflict) { try await detail.save(stale) }
    }

    @Test func maintenanceModes() async throws {
        let connection = try await connectedDemo()
        let detail = DatastoreDetail(store: "main", connection: connection)
        await detail.load()
        try await detail.setMaintenance(DatastoreMaintenance(kind: .readOnly, message: "Disk swap"))
        #expect(detail.config?.maintenance == DatastoreMaintenance(kind: .readOnly, message: "Disk swap"))
        #expect(connection.backupServer?.datastores.first { $0.store == "main" }?.maintenance?.kind == .readOnly)
        try await detail.setMaintenance(nil)
        #expect(detail.config?.maintenance == nil)
    }

    @Test func garbageCollectionAndVerificationRunAsTasks() async throws {
        let connection = try await connectedDemo()
        let detail = DatastoreDetail(store: "main", connection: connection)
        let gc = try await detail.startGarbageCollection()
        #expect(gc.upid.type == "garbage_collection")
        #expect(gc.title == "main – Garbage Collection")
        let verify = try await detail.verifyAll(skipVerified: true, reverifyAfterDays: 30)
        #expect(verify.upid.type == "verify")
        #expect(await connection.tasks.result(of: verify.id) == .succeeded)
    }

    @Test func permissions() async throws {
        let detail = DatastoreDetail(store: "main", connection: try await connectedDemo())
        #expect(await detail.loadPermissions() == nil)
        #expect(detail.permissions?.map(\.authID) == ["backup@pbs", "anna@pbs"])
        let entry = BackupServerACLEntry(path: "/datastore/main", authID: "monitoring@pbs!zabbix", role: "DatastoreAudit")
        try await detail.addPermission(entry)
        #expect(detail.permissions?.contains(entry) == true)
        try await detail.removePermission(entry)
        #expect(detail.permissions?.contains(entry) == false)
    }

    @Test func createsAndRemovesDatastores() async throws {
        let connection = try await connectedDemo()
        var draft = DatastoreDraft()
        draft.name = "archive"
        draft.path = "/mnt/datastore/archive"
        let task = try await connection.createDatastore(draft)
        #expect(await connection.tasks.result(of: task.id) == .succeeded)
        await connection.refresh()
        #expect(connection.backupServer?.datastores.map(\.store) == ["archive", "main", "offsite", "s3-archive"])

        var invalid = DatastoreDraft()
        invalid.name = "main"
        invalid.path = "/mnt/x"
        await #expect(throws: ConfigUpdateError.failed("datastore 'main' already exists.")) { try await connection.createDatastore(invalid) }

        let detail = DatastoreDetail(store: "archive", connection: connection)
        let removal = try await detail.delete(destroyData: true, keepJobs: false)
        #expect(await connection.tasks.result(of: removal.id) == .succeeded)
        await connection.refresh()
        #expect(connection.backupServer?.datastores.map(\.store) == ["main", "offsite", "s3-archive"])
    }

    @Test func removableDatastoresMountAndUnmount() async throws {
        let connection = try await connectedDemo()
        let detail = DatastoreDetail(store: "offsite", connection: connection)
        await detail.load()
        #expect(!detail.isMounted)
        #expect(detail.status == nil)
        let mount = try await detail.mount()
        #expect(await connection.tasks.result(of: mount.id) == .succeeded)
        #expect(detail.isMounted)
        await detail.load()
        #expect(detail.status != nil)
        #expect(detail.config?.isRemovable == true)
    }
}
