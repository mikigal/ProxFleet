import Foundation
import Observation
import PBSKit
import ProxmoxCore
import PVEKit

/// One datastore of a backup server: its status, settings, history and permissions, and the actions on it.
@MainActor
@Observable
public final class DatastoreDetail {
    public let store: String
    public let connection: ServerConnection

    public private(set) var status: DatastoreStatus?
    public private(set) var config: DatastoreConfig?
    /// Digest of the configuration file the settings were read from.
    public private(set) var configDigest: String?
    public private(set) var garbageCollection: GarbageCollectionStatus?
    public private(set) var history: [DatastoreRRDPoint] = []
    public private(set) var operations: DatastoreOperations?
    /// Privileges on `/datastore/{store}`; nil until loaded, when everything counts as allowed.
    public private(set) var privileges: Set<String>?
    /// Permissions on the datastore and below it.
    public private(set) var permissions: [BackupServerACLEntry]?
    private var permissionsDigest: String?
    public private(set) var loadError: String?
    public private(set) var hasLoaded = false

    public var timeframe: RRDTimeframe = .day {
        didSet {
            guard timeframe != oldValue else { return }
            Task { await loadHistory() }
        }
    }

    public init(store: String, connection: ServerConnection) {
        self.store = store
        self.connection = connection
    }

    public var aclPath: String { "/datastore/\(store)" }
    public var summary: DatastoreSummary? { connection.backupServer?.datastores.first { $0.store == store } }
    public var usage: DatastoreUsage? { connection.backupServer?.usage(of: store) }
    public var isMounted: Bool { summary?.mountStatus != .notMounted }

    /// Whether the user holds a privilege on the datastore. Unknown privileges count as granted.
    public func can(_ privilege: String) -> Bool {
        privileges?.contains(privilege) ?? true
    }

    // MARK: - Loading

    public func load() async {
        async let status: Void = loadStatus()
        async let configuration: Void = loadConfig()
        async let history: Void = loadHistory()
        async let privileges = try? connection.apiSession.backupServerPrivileges(on: aclPath)
        _ = await (status, configuration, history)
        if let privileges = await privileges { self.privileges = privileges }
        hasLoaded = true
    }

    /// Keeps the status and running operations current while the screen is visible.
    public func keepRefreshing() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { break }
            await loadStatus()
        }
    }

    private func loadStatus() async {
        guard isMounted else {
            status = nil
            loadError = nil
            return
        }
        do {
            async let status = connection.send(PBS.datastoreStatus(store))
            async let garbageCollection = try? connection.send(PBS.garbageCollectionStatus(store))
            async let operations = try? connection.send(PBS.activeOperations(store))
            self.status = try await status
            self.garbageCollection = await garbageCollection
            self.operations = await operations
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func loadConfig() async {
        if let digested = try? await connection.send(PBS.datastoreConfig(store)) {
            config = digested.value
            configDigest = digested.digest
        }
    }

    private func loadHistory() async {
        if let points = try? await connection.send(PBS.datastoreRRD(store, timeframe: timeframe)) {
            history = points.filter(\.hasData)
        }
    }

    // MARK: - Actions

    private func runTask(_ request: APIRequest<String>) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        do {
            return try connection.tasks.track(try await connection.send(request))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    @discardableResult
    public func startGarbageCollection() async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.startGarbageCollection(store))
    }

    /// Verifies every snapshot of the datastore, like the web interface's Verify All.
    @discardableResult
    public func verifyAll(skipVerified: Bool, reverifyAfterDays: Int?) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.verify(store, skipVerified: skipVerified, reverifyAfterDays: reverifyAfterDays))
    }

    @discardableResult
    public func mount() async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.mountDatastore(store))
    }

    @discardableResult
    public func unmount() async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.unmountDatastore(store))
    }

    @discardableResult
    public func refreshFromS3() async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.refreshFromS3(store))
    }

    /// Saves changed settings, refused when the configuration changed since it was loaded.
    public func save(_ update: BackupServerConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        var update = update
        if update.digest == nil { update.digest = configDigest }
        do {
            _ = try await connection.send(PBS.updateDatastore(store, update))
        } catch {
            let failure = ConfigUpdateError(error)
            if failure == .conflict { await loadConfig() }
            throw failure
        }
        await loadConfig()
        await connection.refresh()
    }

    /// Puts the datastore into maintenance, or back into normal operation with nil.
    public func setMaintenance(_ maintenance: DatastoreMaintenance?) async throws(ConfigUpdateError) {
        var update = BackupServerConfigUpdate(digest: configDigest)
        update.set("maintenance-mode", maintenance?.stringValue)
        try await save(update)
    }

    /// Removes the datastore. Without `destroyData` the backups stay on disk and can be added again later.
    @discardableResult
    public func delete(destroyData: Bool, keepJobs: Bool) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.deleteDatastore(store, destroyData: destroyData, keepJobs: keepJobs, digest: nil))
    }

    // MARK: - Permissions

    public func loadPermissions() async -> String? {
        do {
            let digested = try await connection.send(PBS.acl(path: aclPath))
            permissions = digested.value.filter { $0.path == aclPath || $0.path.hasPrefix(aclPath + "/") }
                .sorted { ($0.path, $0.authID) < ($1.path, $1.authID) }
            permissionsDigest = digested.digest
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func addPermission(_ entry: BackupServerACLEntry) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.send(PBS.setACL(entry))
        } catch {
            throw ConfigUpdateError(error)
        }
        _ = await loadPermissions()
    }

    public func removePermission(_ entry: BackupServerACLEntry) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.send(PBS.setACL(entry, remove: true, digest: permissionsDigest))
        } catch {
            throw ConfigUpdateError(error)
        }
        _ = await loadPermissions()
    }
}

extension ServerConnection {
    /// Creates a datastore and follows the task that sets up its chunk store. Validation errors come back by field.
    public func createDatastore(_ draft: DatastoreDraft) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        let parameters = draft.creationParameters(usesNotificationSystem: supports(backupServer: .notifications))
        do {
            return try tasks.track(try await send(PBS.createDatastore(parameters)), reportsFailure: false)
        } catch {
            throw ConfigUpdateError(error)
        }
    }
}
