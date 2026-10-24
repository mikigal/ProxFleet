import Foundation
import Observation
import PBSKit
import ProxmoxCore
import PVEKit

/// One namespace of a datastore: the namespaces directly below it and its backup groups.
@MainActor
@Observable
public final class DatastoreContent {
    public let store: String
    public let namespace: BackupNamespace
    public let connection: ServerConnection

    /// The namespaces one level below.
    public private(set) var namespaces: [BackupNamespace]?
    public private(set) var groups: [BackupGroup]?
    /// Privileges on the namespace; nil until loaded, when everything counts as allowed.
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?

    public init(store: String, namespace: BackupNamespace = .root, connection: ServerConnection) {
        self.store = store
        self.namespace = namespace
        self.connection = connection
    }

    public var aclPath: String { Self.aclPath(store: store, namespace: namespace) }

    static func aclPath(store: String, namespace: BackupNamespace) -> String {
        namespace.isRoot ? "/datastore/\(store)" : "/datastore/\(store)/\(namespace.path)"
    }

    public func can(_ privilege: String) -> Bool {
        privileges?.contains(privilege) ?? true
    }

    public func load() async {
        do {
            async let namespaces = connection.send(PBS.namespaces(store, parent: namespace, maxDepth: 1))
            async let groups = connection.send(PBS.groups(store, namespace: namespace))
            async let privileges = try? connection.apiSession.backupServerPrivileges(on: aclPath)
            self.namespaces = try await namespaces.filter { $0 != namespace }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.groups = try await groups.map { $0.in(namespace) }.sorted(by: Self.groupOrder)
            if let privileges = await privileges { self.privileges = privileges }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// VMs, containers, then hosts, each by ID with numbers in numeric order, like the web interface.
    static func groupOrder(_ lhs: BackupGroup, _ rhs: BackupGroup) -> Bool {
        if lhs.reference.type != rhs.reference.type { return lhs.reference.type < rhs.reference.type }
        return lhs.reference.backupID.localizedStandardCompare(rhs.reference.backupID) == .orderedAscending
    }

    private func perform(_ request: APIRequest<Nothing>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    private func runTask(_ request: APIRequest<String>) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        do {
            return try connection.tasks.track(try await connection.send(request))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func createNamespace(_ name: String) async throws(ConfigUpdateError) {
        try await perform(PBS.createNamespace(store, name: name.trimmingCharacters(in: .whitespaces), parent: namespace))
        await load()
    }

    /// Deletes a namespace below this one; with `deleteGroups` also its backups. Protected snapshots stay.
    public func deleteNamespace(_ child: BackupNamespace, deleteGroups: Bool) async throws(ConfigUpdateError) -> DeletionResult? {
        let result: DeletionResult?
        do {
            result = try await connection.send(PBS.deleteNamespace(store, child, deleteGroups: deleteGroups))
        } catch {
            throw ConfigUpdateError(error)
        }
        await load()
        return result
    }

    @discardableResult
    public func moveNamespace(_ child: BackupNamespace, to target: BackupNamespace) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.moveNamespace(store, child, to: target, mergeGroups: true))
    }

    /// Verifies every snapshot in the namespace and below.
    @discardableResult
    public func verify(skipVerified: Bool, reverifyAfterDays: Int?) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.verify(store, namespace: namespace, skipVerified: skipVerified, reverifyAfterDays: reverifyAfterDays))
    }

    /// Prunes every group in the namespace and below by the rules, like the web interface's Prune All.
    @discardableResult
    public func pruneAll(keep retention: RetentionPolicy, dryRun: Bool) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.pruneNamespace(store, namespace, keep: retention, dryRun: dryRun))
    }

    /// Every namespace of the datastore, for choosing where to move something.
    public func allNamespaces() async -> [BackupNamespace] {
        (try? await connection.send(PBS.namespaces(store))) ?? []
    }
}

/// One backup group: its snapshots, notes and the actions on it.
@MainActor
@Observable
public final class BackupGroupDetail {
    public let store: String
    public let group: BackupGroupReference
    public let connection: ServerConnection

    /// Newest first.
    public private(set) var snapshots: [BackupSnapshot]?
    public private(set) var notes: String?
    public private(set) var owner: String?
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?

    public init(store: String, group: BackupGroup, connection: ServerConnection) {
        self.store = store
        self.group = group.reference
        self.connection = connection
        owner = group.owner
    }

    public var aclPath: String { DatastoreContent.aclPath(store: store, namespace: group.namespace) }

    public func can(_ privilege: String) -> Bool {
        privileges?.contains(privilege) ?? true
    }

    /// Notes, protection and owner-limited actions: with `Datastore.Modify`, or `Datastore.Backup` on one's own backups.
    public var canChangeBackups: Bool {
        can("Datastore.Modify") || (can("Datastore.Backup") && owner?.split(separator: "!").first.map(String.init) == connection.profile.userID)
    }

    public func load() async {
        do {
            async let snapshots = connection.send(PBS.snapshots(store, group: group))
            async let notes = try? connection.send(PBS.groupNotes(store, group))
            async let privileges = try? connection.apiSession.backupServerPrivileges(on: aclPath)
            self.snapshots = try await snapshots.map { $0.in(group.namespace) }.sorted { $0.reference.time > $1.reference.time }
            self.notes = await notes ?? nil
            if let privileges = await privileges { self.privileges = privileges }
            owner = self.snapshots?.first?.owner ?? owner
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func perform<Response>(_ request: APIRequest<Response>) async throws(ConfigUpdateError) -> Response {
        do {
            return try await connection.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    private func runTask(_ request: APIRequest<String>) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        do {
            return try connection.tasks.track(try await connection.send(request))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func setNotes(_ notes: String) async throws(ConfigUpdateError) {
        _ = try await perform(PBS.setGroupNotes(store, group, notes: notes))
        await load()
    }

    @discardableResult
    public func verify(skipVerified: Bool = false) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.verify(store, group: group, skipVerified: skipVerified))
    }

    /// Which snapshots the rules keep, as the server decides it; nothing is removed.
    public func previewPrune(keep retention: RetentionPolicy) async throws(ConfigUpdateError) -> [SnapshotPruneDecision] {
        try await perform(PBS.previewPrune(store, group, keep: retention))
    }

    @discardableResult
    public func prune(keep retention: RetentionPolicy) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.prune(store, group, keep: retention))
    }

    public func changeOwner(to owner: String) async throws(ConfigUpdateError) {
        _ = try await perform(PBS.changeOwner(store, group, to: owner))
        self.owner = owner
        await load()
    }

    @discardableResult
    public func move(to target: BackupNamespace, merge: Bool) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.moveGroup(store, group, to: target, merge: merge))
    }

    /// Deletes the group; protected snapshots and the group holding them stay.
    public func delete() async throws(ConfigUpdateError) -> DeletionResult? {
        try await perform(PBS.deleteGroup(store, group))
    }

    public func setProtected(_ snapshot: SnapshotReference, _ isProtected: Bool) async throws(ConfigUpdateError) {
        _ = try await perform(PBS.setProtected(store, snapshot, isProtected))
        await load()
    }

    public func deleteSnapshot(_ snapshot: SnapshotReference) async throws(ConfigUpdateError) {
        _ = try await perform(PBS.deleteSnapshot(store, snapshot))
        await load()
    }

    @discardableResult
    public func verify(_ snapshot: SnapshotReference) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await runTask(PBS.verify(store, snapshot: snapshot, skipVerified: false))
    }
}

/// One snapshot: its notes and files, browsing its file archives and downloading from them.
@MainActor
@Observable
public final class SnapshotDetail {
    public let store: String
    public let reference: SnapshotReference
    public let connection: ServerConnection
    public private(set) var notes: String?
    public private(set) var notesError: String?

    public init(store: String, reference: SnapshotReference, connection: ServerConnection) {
        self.store = store
        self.reference = reference
        self.connection = connection
    }

    public func loadNotes() async {
        do {
            notes = try await connection.send(PBS.snapshotNotes(store, reference)) ?? ""
            notesError = nil
        } catch {
            notesError = error.localizedDescription
        }
    }

    public func setNotes(_ notes: String) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.send(PBS.setSnapshotNotes(store, reference, notes: notes))
        } catch {
            throw ConfigUpdateError(error)
        }
        self.notes = notes
    }

    /// Entries of a directory in a file archive. `filePath` is `/` for the archives, then the entries' own paths.
    public func catalog(_ filePath: String, archive: String?) async throws -> [CatalogEntry] {
        // Directories first, then by name, like a file manager.
        try await connection.send(PBS.catalog(store, reference, filePath: filePath, archive: archive)).sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Downloads a file, or a directory as zip or `tar.zst`, named like the web interface names it:
    /// `ct-200-hostname`, `ct-200-etc.zip`.
    public func download(_ entry: CatalogEntry, archive: String?, asTar: Bool = false,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> URL {
        let suffix = entry.isDirectory ? (asTar ? ".tar.zst" : ".zip") : ""
        return try await connection.downloadFile(PBS.downloadArchiveEntry(store, reference, filePath: entry.filePath, archive: archive, tar: asTar),
                                                 named: "\(reference.group.type.rawValue)-\(reference.group.backupID)-\(entry.name)\(suffix)", progress: progress)
    }

    /// A whole file of the snapshot, decoded, e.g. the guest configuration or the client log.
    public func download(file: SnapshotFile, progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> URL {
        try await connection.downloadFile(PBS.downloadSnapshotFile(store, reference, fileName: file.name),
                                          named: "\(reference.group.type.rawValue)-\(reference.group.backupID)-\(file.displayName)", progress: progress)
    }

    /// The text of a small file such as `pct.conf.blob` or `client.log.blob`.
    public func text(of file: SnapshotFile) async throws -> String {
        let url = try await download(file: file)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}

extension ServerConnection {
    /// Downloads into a folder of its own in the temporary directory, under the given name, so it can be shared as
    /// that file. Delete the folder when done.
    public func downloadFile(_ request: APIRequest<Nothing>, named name: String,
                             progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let file = try await apiSession.download(request, into: folder, progress: progress)
            let safeName = name.replacingOccurrences(of: "/", with: "-")
            let target = folder.appending(path: safeName.isEmpty ? "download" : safeName)
            try FileManager.default.moveItem(at: file, to: target)
            return target
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
