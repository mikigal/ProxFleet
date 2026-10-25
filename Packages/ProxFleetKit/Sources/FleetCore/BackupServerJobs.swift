import Foundation
import Observation
import PBSKit
import ProxmoxCore
import PVEKit

/// The scheduled jobs of a backup server, or of one of its datastores: sync, verification, prune and garbage
/// collection, with their last and next runs.
@MainActor
@Observable
public final class BackupServerJobs {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case sync, verify, prune, garbageCollection
        public var id: String { rawValue }
    }

    public let connection: ServerConnection
    /// Limits the lists to one datastore; nil lists the jobs of all.
    public let store: String?

    public private(set) var syncJobs: [SyncJob]?
    public private(set) var verifyJobs: [VerifyJob]?
    public private(set) var pruneJobs: [PruneJob]?
    /// The garbage collection of each datastore, which its settings schedule.
    public private(set) var garbageCollection: [GarbageCollectionStatus]?
    public private(set) var loadError: String?
    /// Digests of the job configuration files the lists were read from.
    private var digests: [Kind: String] = [:]
    /// Privileges on each datastore; a datastore missing here counts as allowed.
    private var privileges: [String: Set<String>] = [:]
    private var remotePrivileges: Set<String>?

    public init(connection: ServerConnection, store: String? = nil) {
        self.connection = connection
        self.store = store
    }

    /// Datastores the jobs can be for.
    public var stores: [String] {
        store.map { [$0] } ?? (connection.backupServer?.datastores.map(\.store) ?? []).sorted()
    }

    public var isEmpty: Bool {
        [syncJobs?.isEmpty, verifyJobs?.isEmpty, pruneJobs?.isEmpty, garbageCollection?.isEmpty].allSatisfy { $0 ?? true }
    }

    // MARK: - Privileges

    /// The privilege on the job's datastore that changing and running a job needs, as the server checks it.
    public static func requiredPrivilege(_ kind: Kind, direction: SyncDirection = .pull) -> String {
        switch kind {
        case .sync: direction == .pull ? "Datastore.Backup" : "Datastore.Read"
        case .verify: "Datastore.Verify"
        case .prune, .garbageCollection: "Datastore.Modify"
        }
    }

    public func can(_ privilege: String, on store: String) -> Bool {
        privileges[store]?.contains(privilege) ?? true
    }

    public func canChange(_ kind: Kind, store: String, direction: SyncDirection = .pull) -> Bool {
        can(Self.requiredPrivilege(kind, direction: direction), on: store)
    }

    /// Why the user cannot change a job, or nil when they can.
    public func lockReason(_ kind: Kind, store: String, direction: SyncDirection = .pull) -> String? {
        guard !store.isEmpty, !canChange(kind, store: store, direction: direction) else { return nil }
        let privilege = Self.requiredPrivilege(kind, direction: direction)
        return String(localized: "Read only. Changing this needs the \(privilege) privilege on /datastore/\(store).")
    }

    /// Adding and changing remotes needs `Remote.Modify` on `/remote`.
    public var canModifyRemotes: Bool { remotePrivileges?.contains("Remote.Modify") ?? true }

    // MARK: - Loading

    public func load() async {
        let stores = stores
        let direction: String? = connection.supports(backupServer: .pushSync) ? "all" : nil
        async let sync = connection.send(PBS.syncJobs(direction: direction, store: store))
        async let verify = connection.send(PBS.verifyJobs(store: store))
        async let prune = connection.send(PBS.pruneJobs(store: store))
        async let garbageCollection = loadGarbageCollection(stores)
        async let privileges = loadPrivileges(stores)
        async let remotePrivileges = try? connection.apiSession.backupServerPrivileges(on: "/remote")
        do {
            let (sync, verify, prune) = try await (sync, verify, prune)
            syncJobs = sync.value.sorted(by: Self.order)
            verifyJobs = verify.value.sorted(by: Self.order)
            pruneJobs = prune.value.sorted(by: Self.order)
            digests = [.sync: sync.digest, .verify: verify.digest, .prune: prune.digest].compactMapValues { $0 }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        self.garbageCollection = await garbageCollection
        self.privileges = await privileges
        if let remotePrivileges = await remotePrivileges { self.remotePrivileges = remotePrivileges }
    }

    private static func order<Job: Identifiable>(_ lhs: Job, _ rhs: Job) -> Bool where Job.ID == String {
        lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    /// `GET /admin/gc` lists every datastore; releases without it are asked one datastore at a time.
    private func loadGarbageCollection(_ stores: [String]) async -> [GarbageCollectionStatus]? {
        if let all = try? await connection.send(PBS.garbageCollectionJobs()) {
            return all.filter { status in store.map { status.store == $0 } ?? true }
                .sorted { ($0.store ?? "").localizedStandardCompare($1.store ?? "") == .orderedAscending }
        }
        var statuses: [GarbageCollectionStatus] = []
        for store in stores {
            if var status = try? await connection.send(PBS.garbageCollectionStatus(store)) {
                status.store = status.store ?? store
                statuses.append(status)
            }
        }
        return statuses
    }

    private func loadPrivileges(_ stores: [String]) async -> [String: Set<String>] {
        let session = connection.apiSession
        return await withTaskGroup(of: (String, Set<String>?).self) { group in
            for store in stores {
                group.addTask { (store, try? await session.backupServerPrivileges(on: "/datastore/\(store)")) }
            }
            var privileges: [String: Set<String>] = [:]
            for await (store, granted) in group {
                if let granted { privileges[store] = granted }
            }
            return privileges
        }
    }

    // MARK: - Running

    /// Runs a job now, or a datastore's garbage collection when `kind` is `.garbageCollection` and `id` the
    /// datastore. The lists reload when the task ends.
    @discardableResult
    public func run(_ kind: Kind, id: String) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        let request = switch kind {
        case .sync: PBS.runSyncJob(id)
        case .verify: PBS.runVerifyJob(id)
        case .prune: PBS.runPruneJob(id)
        case .garbageCollection: PBS.startGarbageCollection(id)
        }
        let task: TaskCenter.TrackedTask
        do {
            task = try connection.tasks.track(try await connection.send(request))
        } catch {
            throw ConfigUpdateError(error)
        }
        await load()
        Task { [weak self, tasks = connection.tasks] in
            _ = await tasks.result(of: task.id)
            await self?.load()
        }
        return task
    }

    // MARK: - Changing

    public func create(_ draft: SyncJobDraft) async throws(ConfigUpdateError) {
        try await perform(PBS.createSyncJob(draft.creationParameters))
    }

    public func create(_ draft: VerifyJobDraft) async throws(ConfigUpdateError) {
        try await perform(PBS.createVerifyJob(draft.creationParameters))
    }

    public func create(_ draft: PruneJobDraft) async throws(ConfigUpdateError) {
        try await perform(PBS.createPruneJob(draft.creationParameters))
    }

    /// Saves changes to a job, refused when its configuration changed since the list was loaded.
    public func update(_ kind: Kind, id: String, _ update: BackupServerConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        var update = update
        if update.digest == nil { update.digest = digests[kind] }
        let request: APIRequest<Nothing> = switch kind {
        case .sync: PBS.updateSyncJob(id, update)
        case .verify: PBS.updateVerifyJob(id, update)
        case .prune: PBS.updatePruneJob(id, update)
        case .garbageCollection: PBS.updateDatastore(id, update)
        }
        try await perform(request)
    }

    /// Changes when a datastore's garbage collection runs; nil turns the schedule off.
    public func setGarbageCollectionSchedule(_ schedule: String?, of store: String) async throws(ConfigUpdateError) {
        var update = BackupServerConfigUpdate()
        update.set("gc-schedule", schedule.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
        try await perform(PBS.updateDatastore(store, update))
        await connection.refresh()
    }

    public func delete(_ kind: Kind, id: String) async throws(ConfigUpdateError) {
        let request: APIRequest<Nothing>? = switch kind {
        case .sync: PBS.deleteSyncJob(id, digest: digests[kind])
        case .verify: PBS.deleteVerifyJob(id, digest: digests[kind])
        case .prune: PBS.deletePruneJob(id, digest: digests[kind])
        case .garbageCollection: nil
        }
        guard let request else { return }
        try await perform(request)
    }

    /// Sends a change and reloads the lists, also when the server refused it for a conflict.
    private func perform(_ request: APIRequest<Nothing>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.send(request)
        } catch {
            let failure = ConfigUpdateError(error)
            if failure == .conflict { await load() }
            throw failure
        }
        await load()
    }

    // MARK: - Sync job sources

    /// The datastores a sync job can use on the other side: the remote's, or this server's for a local pull.
    public func datastores(remote: String?) async throws(ConfigUpdateError) -> [String] {
        do {
            let stores = try await connection.send(remote.map { PBS.remoteDatastores($0) } ?? PBS.datastores())
            return stores.map(\.store).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    /// The namespaces of a datastore on the remote, or of this server's datastore without one, root first.
    public func namespaces(remote: String?, store: String) async throws(ConfigUpdateError) -> [BackupNamespace] {
        do {
            let namespaces = try await connection.send(remote.map { PBS.remoteNamespaces($0, store: store) } ?? PBS.namespaces(store))
            return ([.root] + namespaces.filter { !$0.isRoot }).sorted { ($0.isRoot ? "" : $0.path) < ($1.isRoot ? "" : $1.path) }
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    /// The groups of a namespace on the remote or this server, for picking group filters.
    public func groups(remote: String?, store: String, namespace: BackupNamespace) async throws(ConfigUpdateError) -> [BackupGroup] {
        do {
            let groups = try await connection.send(remote.map { PBS.remoteGroups($0, store: store, namespace: namespace) } ?? PBS.groups(store, namespace: namespace))
            return groups.sorted(by: DatastoreContent.groupOrder)
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    /// Encryption keys a sync job can use; empty before 4.2.
    public func encryptionKeys() async -> [EncryptionKeyEntry] {
        guard connection.supports(backupServer: .syncEncryption) else { return [] }
        return (try? await connection.send(PBS.encryptionKeys(includeArchived: true)).value) ?? []
    }

    /// The remotes sync jobs can use.
    public func remotes() async -> [BackupRemote] {
        (try? await connection.send(PBS.remotes()).value.sorted { $0.name < $1.name }) ?? []
    }

    /// Users and API tokens that can own synced groups, as the web interface offers them.
    public func owners() async -> [String] {
        (try? await connection.send(PBS.users(includeTokens: true)).value.flatMap(\.authIDs).sorted()) ?? []
    }
}

/// The remotes of a backup server, for sync jobs to pull from or push to.
@MainActor
@Observable
public final class BackupServerRemotes {
    public let connection: ServerConnection

    public private(set) var remotes: [BackupRemote]?
    public private(set) var loadError: String?
    private var digest: String?
    private var privileges: Set<String>?

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    /// Adding and changing remotes needs `Remote.Modify` on `/remote`.
    public var canModify: Bool { privileges?.contains("Remote.Modify") ?? true }

    public func load() async {
        async let privileges = try? connection.apiSession.backupServerPrivileges(on: "/remote")
        do {
            let digested = try await connection.send(PBS.remotes())
            remotes = digested.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            digest = digested.digest
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { self.privileges = privileges }
    }

    public func create(_ draft: RemoteDraft) async throws(ConfigUpdateError) {
        try await perform(PBS.createRemote(draft.creationParameters))
    }

    public func update(_ name: String, _ update: BackupServerConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        var update = update
        if update.digest == nil { update.digest = digest }
        try await perform(PBS.updateRemote(name, update))
    }

    public func delete(_ name: String) async throws(ConfigUpdateError) {
        try await perform(PBS.deleteRemote(name, digest: digest))
    }

    /// Signs in to the remote with its stored credentials and lists its datastores, to check the remote works.
    public func check(_ name: String) async -> Result<[DatastoreSummary], ConfigUpdateError> {
        do {
            return .success(try await connection.send(PBS.remoteDatastores(name)))
        } catch {
            return .failure(ConfigUpdateError(error))
        }
    }

    private func perform(_ request: APIRequest<Nothing>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.send(request)
        } catch {
            let failure = ConfigUpdateError(error)
            if failure == .conflict { await load() }
            throw failure
        }
        await load()
    }
}
