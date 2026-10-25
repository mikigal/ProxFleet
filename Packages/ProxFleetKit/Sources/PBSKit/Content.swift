import Foundation
import ProxmoxCore

/// What a backup group holds: a virtual machine, a container, or files of a host backed up with the client.
public enum BackupType: String, Sendable, CaseIterable, Identifiable, Comparable {
    case vm, ct, host

    public var id: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A namespace of a datastore: `""` is the root, nested ones are paths such as `pve/nested`.
public struct BackupNamespace: Decodable, Sendable, Hashable, Identifiable {
    public var path: String

    public init(_ path: String) {
        self.path = path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        path = container.lossyString(AnyCodingKey("ns")) ?? ""
    }

    public static let root = BackupNamespace("")

    public var id: String { path }
    public var isRoot: Bool { path.isEmpty }
    public var components: [String] { path.split(separator: "/").map(String.init) }
    /// The last component; empty for the root.
    public var name: String { components.last ?? "" }
    /// 0 for the root, 1 for its children and so on.
    public var depth: Int { components.count }
    /// Proxmox Backup Server allows namespaces up to this depth below the root.
    public static let maximumDepth = 7

    public var parent: BackupNamespace? {
        isRoot ? nil : BackupNamespace(components.dropLast().joined(separator: "/"))
    }

    public func child(_ name: String) -> BackupNamespace {
        BackupNamespace(isRoot ? name : "\(path)/\(name)")
    }

    /// Whether `other` is this namespace or below it.
    public func contains(_ other: BackupNamespace) -> Bool {
        isRoot || other.path == path || other.path.hasPrefix(path + "/")
    }
}

/// A backup group in a namespace, such as `ct/200`: the parameters most content calls take.
public struct BackupGroupReference: Sendable, Hashable, Identifiable {
    public var namespace: BackupNamespace
    public var type: BackupType
    public var backupID: String

    public init(namespace: BackupNamespace = .root, type: BackupType, backupID: String) {
        self.namespace = namespace
        self.type = type
        self.backupID = backupID
    }

    public var id: String { "\(namespace.path)|\(path)" }
    /// For example `ct/200`.
    public var path: String { "\(type.rawValue)/\(backupID)" }

    public var parameters: APIParameters {
        var parameters: APIParameters = ["backup-type": .string(type.rawValue), "backup-id": .string(backupID)]
        if !namespace.isRoot { parameters["ns"] = .string(namespace.path) }
        return parameters
    }

    public func snapshot(at time: Int) -> SnapshotReference {
        SnapshotReference(group: self, time: time)
    }
}

/// One backup snapshot of a group, identified by its time.
public struct SnapshotReference: Sendable, Hashable, Identifiable {
    public var group: BackupGroupReference
    /// Seconds since 1970, exactly as the server reports it.
    public var time: Int

    public init(group: BackupGroupReference, time: Int) {
        self.group = group
        self.time = time
    }

    public var id: String { "\(group.id)/\(time)" }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }
    /// The name clients use, e.g. `vm/100/2026-10-24T14:09:52Z`, as the web interface's Copy Name gives it.
    public var name: String { "\(group.path)/\(date.formatted(.iso8601))" }

    public var parameters: APIParameters {
        var parameters = group.parameters
        parameters["backup-time"] = .int(time)
        return parameters
    }
}

/// One entry of `GET /admin/datastore/{store}/groups`.
public struct BackupGroup: Decodable, Sendable, Equatable, Identifiable {
    public var reference: BackupGroupReference
    public var snapshotCount: Int
    public var lastBackup: Date?
    public var owner: String?
    /// The first line of the group's notes.
    public var comment: String?
    /// Files of the latest snapshot.
    public var files: [String]

    public var id: String { reference.id }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let type = container.lossyString(AnyCodingKey("backup-type")).flatMap(BackupType.init),
              let backupID = container.lossyString(AnyCodingKey("backup-id"))
        else { throw ProxmoxError.invalidResponse("backup group without type or ID") }
        reference = BackupGroupReference(type: type, backupID: backupID)
        snapshotCount = container.lossyInt(AnyCodingKey("backup-count")) ?? 0
        lastBackup = container.date("last-backup")
        owner = container.lossyString(AnyCodingKey("owner"))
        comment = container.lossyString(AnyCodingKey("comment")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        files = (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("files"))) ?? []
    }

    /// The group in the namespace it was listed from; the server leaves that out of every entry.
    public func `in`(_ namespace: BackupNamespace) -> BackupGroup {
        var group = self
        group.reference.namespace = namespace
        return group
    }
}

/// How a file of a snapshot is protected.
public enum CryptMode: String, Sendable, Equatable {
    case none
    case encrypt
    case signOnly = "sign-only"
}

/// One file of a snapshot, such as `root.pxar.didx` or `drive-scsi0.img.fidx`.
public struct SnapshotFile: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A file archive that can be browsed: `.pxar`, or the metadata half of a split archive (`.mpxar`).
        case fileArchive
        /// The payload half of a split archive (`.ppxar`), browsed through its `.mpxar`.
        case filePayload
        case diskImage
        case catalog
        /// Configuration, the index, the client log and other small files.
        case blob
        case other
    }

    public var name: String
    /// Nil for files without size, such as a client log that was not uploaded.
    public var size: Int64?
    public var cryptMode: CryptMode?

    public var id: String { name }

    public init(name: String, size: Int64? = nil, cryptMode: CryptMode? = nil) {
        self.name = name
        self.size = size
        self.cryptMode = cryptMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("filename")) ?? ""
        size = container.int64("size")
        cryptMode = container.lossyString(AnyCodingKey("crypt-mode")).flatMap(CryptMode.init)
    }

    public var kind: Kind {
        if name.hasPrefix("catalog.") { return .catalog }
        if name.hasSuffix(".pxar.didx") || name.hasSuffix(".mpxar.didx") { return .fileArchive }
        if name.hasSuffix(".ppxar.didx") { return .filePayload }
        if name.hasSuffix(".img.fidx") { return .diskImage }
        if name.hasSuffix(".blob") { return .blob }
        return .other
    }

    /// The name without the index suffix, as the web interface shows it: `root.pxar`, `drive-scsi0.img`.
    public var displayName: String {
        for suffix in [".didx", ".fidx", ".blob"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}

/// The verification state of a snapshot.
public struct SnapshotVerification: Sendable, Equatable {
    public var succeeded: Bool
    /// The task that verified it.
    public var upid: String?
}

/// One entry of `GET /admin/datastore/{store}/snapshots`.
public struct BackupSnapshot: Decodable, Sendable, Equatable, Identifiable {
    public var reference: SnapshotReference
    /// The first line of the snapshot's notes.
    public var comment: String?
    public var files: [SnapshotFile]
    public var owner: String?
    public var isProtected: Bool
    /// Total size of the files, before deduplication.
    public var size: Int64?
    /// Fingerprint of the key the snapshot was encrypted with.
    public var keyFingerprint: String?
    /// Nil when it was never verified.
    public var verification: SnapshotVerification?

    public var id: String { reference.id }
    public var date: Date { reference.date }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let type = container.lossyString(AnyCodingKey("backup-type")).flatMap(BackupType.init),
              let backupID = container.lossyString(AnyCodingKey("backup-id")),
              let time = container.lossyInt(AnyCodingKey("backup-time"))
        else { throw ProxmoxError.invalidResponse("backup snapshot without type, ID or time") }
        reference = SnapshotReference(group: BackupGroupReference(type: type, backupID: backupID), time: time)
        comment = container.lossyString(AnyCodingKey("comment")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        files = (try? container.decodeIfPresent([SnapshotFile].self, forKey: AnyCodingKey("files"))) ?? []
        owner = container.lossyString(AnyCodingKey("owner"))
        isProtected = container.lossyBool(AnyCodingKey("protected")) ?? false
        size = container.int64("size")
        keyFingerprint = container.lossyString(AnyCodingKey("fingerprint"))
        if let verification = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("verification")) {
            self.verification = SnapshotVerification(
                succeeded: verification.lossyString(AnyCodingKey("state")) == "ok",
                upid: verification.lossyString(AnyCodingKey("upid"))
            )
        }
    }

    /// The snapshot in the namespace it was listed from; the server leaves that out of every entry.
    public func `in`(_ namespace: BackupNamespace) -> BackupSnapshot {
        var snapshot = self
        snapshot.reference.group.namespace = namespace
        return snapshot
    }

    /// Encrypted when every file with a crypt mode is, signed when they are signed, nil for plain backups.
    public var cryptMode: CryptMode? {
        let modes = Set(files.compactMap(\.cryptMode))
        if modes == [.encrypt] { return .encrypt }
        if modes.contains(.signOnly) { return .signOnly }
        return modes.contains(.encrypt) ? .encrypt : nil
    }

    /// File archives that can be browsed with the catalog.
    public var browsableArchives: [SnapshotFile] {
        files.filter { $0.kind == .fileArchive }
    }
}

/// One entry of `GET /admin/datastore/{store}/catalog`: a file or directory inside a snapshot.
public struct CatalogEntry: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case directory = "d"
        case file = "f"
        case symlink = "l"
        case hardlink = "h"
        case characterDevice = "c"
        case blockDevice = "b"
        case fifo = "p"
        case socket = "s"
        /// An archive at the top level of a snapshot.
        case virtual = "v"
    }

    /// Base64 path, which is sent back to list a directory or download the entry.
    public var filePath: String
    public var name: String
    public var kind: Kind?
    /// True when the entry has no children.
    public var isLeaf: Bool
    public var size: Int64?
    public var modified: Date?

    public var id: String { filePath }
    public var isDirectory: Bool { kind == .directory || kind == .virtual || !isLeaf }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        filePath = container.lossyString(AnyCodingKey("filepath")) ?? ""
        name = container.lossyString(AnyCodingKey("text")) ?? ""
        kind = container.lossyString(AnyCodingKey("type")).flatMap(Kind.init)
        isLeaf = container.lossyBool(AnyCodingKey("leaf")) ?? true
        size = container.int64("size")
        modified = container.date("mtime")
    }

    /// The decoded path, e.g. `root.pxar.didx/etc/hostname`.
    public var decodedPath: String? {
        Data(base64Encoded: filePath).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// What deleting a group or namespace removed. Older releases answer without it.
public struct DeletionResult: Decodable, Sendable, Equatable {
    public var removedGroups: Int
    public var removedSnapshots: Int
    /// Protected snapshots that stayed, and the groups holding them with them.
    public var protectedSnapshots: Int

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        removedGroups = container.lossyInt(AnyCodingKey("removed-groups")) ?? 0
        removedSnapshots = container.lossyInt(AnyCodingKey("removed-snapshots")) ?? 0
        protectedSnapshots = container.lossyInt(AnyCodingKey("protected-snapshots")) ?? 0
    }
}

/// One entry of a prune: a snapshot and whether the retention rules keep it.
public struct SnapshotPruneDecision: Decodable, Sendable, Equatable, Identifiable {
    public var reference: SnapshotReference
    public var keep: Bool
    public var isProtected: Bool

    public var id: String { reference.id }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let type = container.lossyString(AnyCodingKey("backup-type")).flatMap(BackupType.init),
              let backupID = container.lossyString(AnyCodingKey("backup-id")),
              let time = container.lossyInt(AnyCodingKey("backup-time"))
        else { throw ProxmoxError.invalidResponse("prune entry without type, ID or time") }
        reference = SnapshotReference(group: BackupGroupReference(type: type, backupID: backupID), time: time)
        keep = container.lossyBool(AnyCodingKey("keep")) ?? true
        isProtected = container.lossyBool(AnyCodingKey("protected")) ?? false
    }
}

extension PBS {
    private static func content(_ store: String, _ call: String) -> String {
        "/admin/datastore/\(escapePath(store))/\(call)"
    }

    private static func namespaceParameters(_ namespace: BackupNamespace) -> APIParameters {
        namespace.isRoot ? APIParameters() : ["ns": .string(namespace.path)]
    }

    /// The namespaces below `parent` (or all of them), including `parent` itself.
    public static func namespaces(_ store: String, parent: BackupNamespace = .root, maxDepth: Int? = nil) -> APIRequest<[BackupNamespace]> {
        var parameters = APIParameters()
        if !parent.isRoot { parameters["parent"] = .string(parent.path) }
        if let maxDepth { parameters["max-depth"] = .int(maxDepth) }
        return APIRequest(.get, content(store, "namespace"), parameters: parameters)
    }

    public static func createNamespace(_ store: String, name: String, parent: BackupNamespace) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["name": .string(name)]
        if !parent.isRoot { parameters["parent"] = .string(parent.path) }
        return APIRequest(.post, content(store, "namespace"), parameters: parameters)
    }

    /// Removes an empty namespace, or with `deleteGroups` everything in it. Protected snapshots stay with the
    /// namespaces holding them; without `keepProtected` the server reports that as an error.
    public static func deleteNamespace(_ store: String, _ namespace: BackupNamespace, deleteGroups: Bool, keepProtected: Bool = true) -> APIRequest<DeletionResult?> {
        var parameters: APIParameters = ["ns": .string(namespace.path), "delete-groups": .bool(deleteGroups)]
        if keepProtected { parameters["error-on-protected"] = false }
        return APIRequest(.delete, content(store, "namespace"), parameters: parameters)
    }

    /// Groups of one namespace, without those of its children.
    public static func groups(_ store: String, namespace: BackupNamespace = .root) -> APIRequest<[BackupGroup]> {
        APIRequest(.get, content(store, "groups"), parameters: namespaceParameters(namespace))
    }

    /// Snapshots of one namespace, or of one group in it.
    public static func snapshots(_ store: String, namespace: BackupNamespace = .root, group: BackupGroupReference? = nil) -> APIRequest<[BackupSnapshot]> {
        APIRequest(.get, content(store, "snapshots"), parameters: group?.parameters ?? namespaceParameters(namespace))
    }

    public static func snapshotFiles(_ store: String, _ snapshot: SnapshotReference) -> APIRequest<[SnapshotFile]> {
        APIRequest(.get, content(store, "files"), parameters: snapshot.parameters)
    }

    /// Lists a directory of a snapshot's file archives. `filePath` is `/` for the archives themselves, then the base64
    /// paths the entries carry. `archive` names the `.mpxar.didx` of a split archive.
    public static func catalog(_ store: String, _ snapshot: SnapshotReference, filePath: String, archive: String? = nil) -> APIRequest<[CatalogEntry]> {
        var parameters = snapshot.parameters
        parameters["filepath"] = .string(filePath)
        if let archive { parameters["archive-name"] = .string(archive) }
        return APIRequest(.get, content(store, "catalog"), parameters: parameters)
    }

    /// One file of an archive, or a directory as zip (or as `tar.zst` with `tar`). For `ProxmoxSession.download`.
    public static func downloadArchiveEntry(_ store: String, _ snapshot: SnapshotReference, filePath: String, archive: String? = nil, tar: Bool = false) -> APIRequest<Nothing> {
        var parameters = snapshot.parameters
        parameters["filepath"] = .string(filePath)
        if let archive { parameters["archive-name"] = .string(archive) }
        if tar { parameters["tar"] = true }
        return APIRequest(.get, content(store, "pxar-file-download"), parameters: parameters)
    }

    /// A whole file of a snapshot, decoded (indexes are turned back into the archive or image). For `ProxmoxSession.download`.
    public static func downloadSnapshotFile(_ store: String, _ snapshot: SnapshotReference, fileName: String) -> APIRequest<Nothing> {
        var parameters = snapshot.parameters
        parameters["file-name"] = .string(fileName)
        return APIRequest(.get, content(store, "download-decoded"), parameters: parameters)
    }

    public static func groupNotes(_ store: String, _ group: BackupGroupReference) -> APIRequest<String?> {
        APIRequest(.get, content(store, "group-notes"), parameters: group.parameters)
    }

    public static func setGroupNotes(_ store: String, _ group: BackupGroupReference, notes: String) -> APIRequest<Nothing> {
        var parameters = group.parameters
        parameters["notes"] = .string(notes)
        return APIRequest(.put, content(store, "group-notes"), parameters: parameters)
    }

    public static func snapshotNotes(_ store: String, _ snapshot: SnapshotReference) -> APIRequest<String?> {
        APIRequest(.get, content(store, "notes"), parameters: snapshot.parameters)
    }

    public static func setSnapshotNotes(_ store: String, _ snapshot: SnapshotReference, notes: String) -> APIRequest<Nothing> {
        var parameters = snapshot.parameters
        parameters["notes"] = .string(notes)
        return APIRequest(.put, content(store, "notes"), parameters: parameters)
    }

    public static func setProtected(_ store: String, _ snapshot: SnapshotReference, _ isProtected: Bool) -> APIRequest<Nothing> {
        var parameters = snapshot.parameters
        parameters["protected"] = .bool(isProtected)
        return APIRequest(.put, content(store, "protected"), parameters: parameters)
    }

    /// Deletes a snapshot. The server refuses protected ones.
    public static func deleteSnapshot(_ store: String, _ snapshot: SnapshotReference) -> APIRequest<Nothing> {
        APIRequest(.delete, content(store, "snapshots"), parameters: snapshot.parameters)
    }

    /// Deletes a group with its snapshots. Protected snapshots stay, and so does the group then. The server deletes
    /// the other snapshots either way, but reports that as an error unless `keepProtected` says it is expected.
    public static func deleteGroup(_ store: String, _ group: BackupGroupReference, keepProtected: Bool = true) -> APIRequest<DeletionResult?> {
        var parameters = group.parameters
        if keepProtected { parameters["error-on-protected"] = false }
        return APIRequest(.delete, content(store, "groups"), parameters: parameters)
    }

    /// Moves a group to another namespace of the datastore; returns the task. With `merge`, snapshots join a group of
    /// the same name there.
    public static func moveGroup(_ store: String, _ group: BackupGroupReference, to target: BackupNamespace, merge: Bool) -> APIRequest<String> {
        var parameters = group.parameters
        parameters["target-ns"] = .string(target.path)
        parameters["merge-group"] = .bool(merge)
        return APIRequest(.post, content(store, "move-group"), parameters: parameters)
    }

    /// Moves a namespace with everything below it (up to `maxDepth` levels); returns the task. Without
    /// `deletesSource`, the emptied source namespace stays.
    public static func moveNamespace(_ store: String, _ namespace: BackupNamespace, to target: BackupNamespace, mergeGroups: Bool,
                                     deletesSource: Bool = true, maxDepth: Int? = nil) -> APIRequest<String> {
        var parameters: APIParameters = ["ns": .string(namespace.path), "target-ns": .string(target.path), "merge-groups": .bool(mergeGroups)]
        // True is the server's default, so it is only sent to keep the source.
        if !deletesSource { parameters["delete-source"] = false }
        if let maxDepth { parameters["max-depth"] = .int(maxDepth) }
        return APIRequest(.post, content(store, "move-namespace"), parameters: parameters)
    }

    /// Prunes every group of a namespace (and the ones below, up to `maxDepth`) by the rules; returns the task, whose
    /// log lists what was kept and removed. With `dryRun` nothing is removed.
    public static func pruneNamespace(_ store: String, _ namespace: BackupNamespace, keep retention: RetentionPolicy, maxDepth: Int? = nil, dryRun: Bool = false) -> APIRequest<String> {
        var parameters = retention.parameters
        if !namespace.isRoot { parameters["ns"] = .string(namespace.path) }
        if let maxDepth { parameters["max-depth"] = .int(maxDepth) }
        if dryRun { parameters["dry-run"] = true }
        return APIRequest(.post, content(store, "prune-datastore"), parameters: parameters)
    }

    public static func changeOwner(_ store: String, _ group: BackupGroupReference, to owner: String) -> APIRequest<Nothing> {
        var parameters = group.parameters
        parameters["new-owner"] = .string(owner)
        return APIRequest(.post, content(store, "change-owner"), parameters: parameters)
    }

    /// Shows which snapshots of a group the rules keep, without removing any.
    public static func previewPrune(_ store: String, _ group: BackupGroupReference, keep retention: RetentionPolicy) -> APIRequest<[SnapshotPruneDecision]> {
        var parameters = group.parameters
        for item in retention.parameters.items { parameters[item.name] = item.value }
        parameters["dry-run"] = true
        return APIRequest(.post, content(store, "prune"), parameters: parameters)
    }

    /// Prunes a group as a task; returns it.
    public static func prune(_ store: String, _ group: BackupGroupReference, keep retention: RetentionPolicy) -> APIRequest<String> {
        var parameters = group.parameters
        for item in retention.parameters.items { parameters[item.name] = item.value }
        parameters["use-task"] = true
        return APIRequest(.post, content(store, "prune"), parameters: parameters)
    }

    /// Verifies a snapshot, a group, a namespace or the whole datastore; returns the task.
    /// - Parameters:
    ///   - skipVerified: leave out snapshots verified before, unless that was more than `reverifyAfterDays` ago.
    ///     Always sent, as the server skips them unless told otherwise.
    public static func verify(_ store: String, namespace: BackupNamespace = .root, group: BackupGroupReference? = nil, snapshot: SnapshotReference? = nil,
                              skipVerified: Bool, reverifyAfterDays: Int? = nil) -> APIRequest<String> {
        var parameters = snapshot?.parameters ?? group?.parameters ?? namespaceParameters(namespace)
        parameters["ignore-verified"] = .bool(skipVerified)
        if skipVerified, let reverifyAfterDays { parameters["outdated-after"] = .int(reverifyAfterDays) }
        return APIRequest(.post, content(store, "verify"), parameters: parameters)
    }
}
