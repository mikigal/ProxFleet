import DemoServer
@testable import FleetCore
import Foundation
import PBSKit
import ProxmoxCore
import Testing

@MainActor
struct BackupServerJobsTests {
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

    @Test func listsEveryKindWithItsState() async throws {
        let connection = try await connectedDemo()
        let jobs = BackupServerJobs(connection: connection)
        await jobs.load()
        #expect(jobs.loadError == nil)
        // Push jobs too: the demo is new enough for `sync-direction=all`.
        #expect(jobs.syncJobs?.map(\.id) == ["cloud-push", "offsite-copy"])
        let copy = try #require(jobs.syncJobs?.first { $0.id == "offsite-copy" })
        #expect(copy.isLocal)
        #expect(copy.routeDescription == "main/homelab → offsite")
        #expect(copy.state.lastRunSucceeded != nil)
        #expect(copy.state.nextRun != nil)
        let push = try #require(jobs.syncJobs?.first { $0.id == "cloud-push" })
        #expect(push.routeDescription == "main/homelab → cloud:homelab-copy")
        #expect(push.groupFilters == ["type:vm", "type:ct", "exclude:group:vm/103"])
        #expect(push.state.lastRunUPID == nil)
        #expect(jobs.verifyJobs?.map(\.id) == ["weekly-verify"])
        #expect(jobs.pruneJobs?.first?.retention == RetentionPolicy(last: 3, daily: 7, weekly: 4, monthly: 6))
        #expect(jobs.garbageCollection?.map(\.store) == ["main", "offsite"])
        #expect(jobs.canChange(.sync, store: "main", direction: .push))
        #expect(jobs.lockReason(.prune, store: "main") == nil)

        let offsite = BackupServerJobs(connection: connection, store: "offsite")
        await offsite.load()
        #expect(offsite.syncJobs?.map(\.id) == ["offsite-copy"])
        #expect(offsite.verifyJobs?.isEmpty == true)
        #expect(offsite.garbageCollection?.map(\.store) == ["offsite"])
        #expect(offsite.stores == ["offsite"])
    }

    @Test func runNowIsFollowedUntilTheStateShowsIt() async throws {
        let connection = try await connectedDemo()
        let jobs = BackupServerJobs(connection: connection)
        await jobs.load()
        let task = try await jobs.run(.verify, id: "weekly-verify")
        #expect(task.upid.type == "verificationjob")
        #expect(jobs.verifyJobs?.first?.state.isRunning == true)
        #expect(await connection.tasks.result(of: task.id) == .succeeded)
        await jobs.load()
        #expect(jobs.verifyJobs?.first?.state.lastRunUPID == task.id)
        #expect(jobs.verifyJobs?.first?.state.lastRunState == "OK")

        let collection = try await jobs.run(.garbageCollection, id: "main")
        #expect(collection.upid.type == "garbage_collection")
        await #expect(throws: ConfigUpdateError.self) { try await jobs.run(.prune, id: "missing") }
    }

    @Test func syncJobLifecycle() async throws {
        let connection = try await connectedDemo()
        let jobs = BackupServerJobs(connection: connection)
        await jobs.load()
        var draft = SyncJobDraft(direction: .pull, store: "offsite", owner: "root@pam")
        draft.id = "laptops-copy"
        draft.isLocal = true
        draft.remoteStore = "main"
        draft.remoteNamespace = "laptops"
        draft.groupFilters = [GroupFilter(kind: .type, value: "host")]
        #expect(draft.problems(isNew: true).isEmpty)
        try await jobs.create(draft)
        let created = try #require(jobs.syncJobs?.first { $0.id == "laptops-copy" })
        #expect(created.groupFilters == ["type:host"])
        #expect(created.remote == nil)

        var edited = SyncJobDraft(created)
        edited.groupFilters = []
        edited.comment = "Laptops to the USB disk"
        try await jobs.update(.sync, id: created.id, edited.changes(from: SyncJobDraft(created)))
        let saved = try #require(jobs.syncJobs?.first { $0.id == "laptops-copy" })
        #expect(saved.groupFilters.isEmpty)
        #expect(saved.comment == "Laptops to the USB disk")

        // The server checks what the form cannot, field by field.
        var invalid = SyncJobDraft(saved)
        invalid.groupFilters = [GroupFilter(kind: .group, value: "vm")]
        await #expect(throws: ConfigUpdateError.invalid(message: "parameter verification errors", fields: ["group-filter": "invalid group filter 'group:vm'"])) {
            try await jobs.update(.sync, id: saved.id, invalid.changes(from: SyncJobDraft(saved)))
        }

        try await jobs.delete(.sync, id: "laptops-copy")
        #expect(jobs.syncJobs?.contains { $0.id == "laptops-copy" } == false)
    }

    @Test func staleDigestsAreRefused() async throws {
        let connection = try await connectedDemo()
        let jobs = BackupServerJobs(connection: connection)
        let other = BackupServerJobs(connection: connection)
        await jobs.load()
        await other.load()
        let job = try #require(other.pruneJobs?.first)
        var draft = PruneJobDraft(job)
        draft.comment = "Changed elsewhere"
        try await other.update(.prune, id: job.id, draft.changes(from: PruneJobDraft(job)))
        draft.comment = "Changed here"
        await #expect(throws: ConfigUpdateError.conflict) {
            try await jobs.update(.prune, id: job.id, draft.changes(from: PruneJobDraft(job)))
        }
        // The refusal reloads the lists, so the next attempt works.
        try await jobs.update(.prune, id: job.id, draft.changes(from: PruneJobDraft(job)))
        #expect(jobs.pruneJobs?.first?.comment == "Changed here")
    }

    @Test func verifyAndPruneJobsAndTheGarbageCollectionSchedule() async throws {
        let connection = try await connectedDemo()
        let jobs = BackupServerJobs(connection: connection)
        await jobs.load()
        var verify = VerifyJobDraft(store: "main")
        verify.namespace = "laptops"
        verify.skipVerified = false
        try await jobs.create(verify)
        let created = try #require(jobs.verifyJobs?.first { $0.namespace == BackupNamespace("laptops") })
        #expect(created.id.hasPrefix("v-"))
        #expect(!created.skipVerified)

        var prune = PruneJobDraft(store: "offsite")
        prune.retention.weekly = 8
        try await jobs.create(prune)
        #expect(jobs.pruneJobs?.contains { $0.store == "offsite" && $0.retention == RetentionPolicy(weekly: 8) } == true)
        var noSchedule = PruneJobDraft(store: "offsite")
        noSchedule.schedule = ""
        noSchedule.retention.last = 1
        #expect(noSchedule.problems(isNew: true)["schedule"] != nil)

        try await jobs.setGarbageCollectionSchedule("sat 03:00", of: "offsite")
        await jobs.load()
        #expect(jobs.garbageCollection?.first { $0.store == "offsite" }?.schedule == "sat 03:00")
        try await jobs.setGarbageCollectionSchedule(nil, of: "offsite")
        await jobs.load()
        #expect(jobs.garbageCollection?.first { $0.store == "offsite" }?.schedule == nil)
    }

    @Test func syncSourcesComeFromTheRemoteOrThisServer() async throws {
        let connection = try await connectedDemo()
        let jobs = BackupServerJobs(connection: connection)
        #expect(try await jobs.datastores(remote: "cloud") == ["customers", "homelab-copy"])
        #expect(try await jobs.namespaces(remote: "cloud", store: "homelab-copy") == [.root, BackupNamespace("homelab")])
        #expect(try await jobs.groups(remote: "cloud", store: "homelab-copy", namespace: BackupNamespace("homelab")).first?.reference.path == "vm/100")
        #expect(try await jobs.datastores(remote: nil) == ["main", "offsite"])
        #expect(try await jobs.namespaces(remote: nil, store: "main").map(\.path) == ["", "homelab", "laptops"])
        #expect(await jobs.remotes().map(\.name) == ["cloud"])
        #expect(await jobs.owners().contains("backup@pbs!pve"))
        #expect(await jobs.encryptionKeys().map(\.id) == ["cloud-2026", "cloud-2025"])
    }

    @Test func remoteLifecycle() async throws {
        let connection = try await connectedDemo()
        let remotes = BackupServerRemotes(connection: connection)
        await remotes.load()
        #expect(remotes.remotes?.map(\.name) == ["cloud"])
        #expect(remotes.canModify)

        var draft = RemoteDraft()
        draft.name = "second"
        draft.address = "pbs2.lan:8008"
        draft.authID = "sync@pbs"
        draft.password = "wrong"
        try await remotes.create(draft)
        let created = try #require(remotes.remotes?.first { $0.name == "second" })
        #expect(created.port == 8008)
        // The demo refuses the password `wrong` like a real remote would.
        guard case .failure = await remotes.check("second") else { Issue.record("expected the check to fail"); return }

        var edited = RemoteDraft(created)
        edited.password = "right"
        edited.address = "pbs2.lan"
        try await remotes.update("second", edited.update(from: RemoteDraft(created), digest: nil))
        #expect(remotes.remotes?.first { $0.name == "second" }?.port == nil)
        guard case .success(let stores) = await remotes.check("second") else { Issue.record("expected the check to work"); return }
        #expect(!stores.isEmpty)

        var invalid = RemoteDraft(created)
        invalid.fingerprint = "12:34"
        await #expect(throws: ConfigUpdateError.self) { try await remotes.update("second", invalid.update(from: RemoteDraft(created), digest: nil)) }

        // A remote that sync jobs use stays.
        await #expect(throws: ConfigUpdateError.self) { try await remotes.delete("cloud") }
        try await remotes.delete("second")
        #expect(remotes.remotes?.map(\.name) == ["cloud"])
    }

    @Test func datastoresCreatedWithRetentionGetAPruneJob() async throws {
        let connection = try await connectedDemo()
        var draft = DatastoreDraft()
        draft.name = "archive"
        draft.path = "/mnt/archive"
        draft.retention = RetentionPolicy(last: 4)
        let task = try await connection.createDatastore(draft)
        #expect(await connection.tasks.result(of: task.id) == .succeeded)
        let jobs = BackupServerJobs(connection: connection, store: "archive")
        await jobs.load()
        let job = try #require(jobs.pruneJobs?.first)
        #expect(job.id.hasPrefix("default-archive-"))
        #expect(job.retention == RetentionPolicy(last: 4))
    }
}
