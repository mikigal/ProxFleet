import Foundation
import ProxmoxCore

/// The last and next run of a scheduled job, which the `/admin/...` lists add to the job's settings.
public struct JobState: Sendable, Equatable {
    public var lastRunUPID: String?
    /// `OK`, `WARNINGS: n` or an error; nil while it runs or before the first run.
    public var lastRunState: String?
    public var lastRunEnd: Date?
    public var nextRun: Date?

    public init(lastRunUPID: String? = nil, lastRunState: String? = nil, lastRunEnd: Date? = nil, nextRun: Date? = nil) {
        self.lastRunUPID = lastRunUPID
        self.lastRunState = lastRunState
        self.lastRunEnd = lastRunEnd
        self.nextRun = nextRun
    }

    init(_ container: KeyedDecodingContainer<AnyCodingKey>) {
        lastRunUPID = container.lossyString(AnyCodingKey("last-run-upid"))
        lastRunState = container.lossyString(AnyCodingKey("last-run-state"))
        lastRunEnd = container.date("last-run-endtime")
        nextRun = container.date("next-run")
    }

    /// A run was started and has not finished yet.
    public var isRunning: Bool { lastRunUPID != nil && lastRunState == nil }
    public var lastRunSucceeded: Bool? {
        lastRunState.map { $0 == "OK" || $0.hasPrefix("WARNINGS") }
    }
}

/// Every setting of a job as text, so editors can keep the ones they do not know.
private func textValues(_ container: KeyedDecodingContainer<AnyCodingKey>) -> [String: String] {
    var values: [String: String] = [:]
    for key in container.allKeys {
        if let text = container.lossyString(key) {
            values[key.stringValue] = text
        } else if let flag = container.lossyBool(key) {
            values[key.stringValue] = flag ? "1" : "0"
        }
    }
    return values
}

public enum SyncDirection: String, Sendable, CaseIterable, Identifiable {
    /// From a remote, or from another local datastore, into this one.
    case pull
    /// From this datastore to a remote.
    case push

    public var id: String { rawValue }
}

/// A sync job, from `GET /admin/sync` (with its state) or `GET /config/sync`.
public struct SyncJob: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var direction: SyncDirection
    /// The local datastore and namespace.
    public var store: String
    public var namespace: BackupNamespace
    /// Nil for a sync between two local datastores.
    public var remote: String?
    public var remoteStore: String
    public var remoteNamespace: BackupNamespace
    public var schedule: String?
    public var comment: String?
    /// Who owns the synced groups locally (pull) or which user's groups are pushed.
    public var owner: String?
    public var removeVanished: Bool
    /// Namespace levels below the namespace to include; nil for all.
    public var maxDepth: Int?
    /// `type:ct`, `group:vm/100`, `regex:…`, each optionally prefixed with `exclude:`.
    public var groupFilters: [String]
    /// Only the newest this many snapshots of each group.
    public var transferLast: Int?
    /// Keys for decrypting pulled snapshots, or for snapshots pushed with an earlier key (4.2 and newer).
    public var associatedKeys: [String]
    public var state: JobState
    public var values: [String: String]

    public var isLocal: Bool { remote == nil }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        values = textValues(container)
        id = values["id"] ?? ""
        direction = values["sync-direction"].flatMap(SyncDirection.init) ?? .pull
        store = values["store"] ?? ""
        namespace = BackupNamespace(values["ns"] ?? "")
        remote = values["remote"].flatMap { $0.isEmpty ? nil : $0 }
        remoteStore = values["remote-store"] ?? ""
        remoteNamespace = BackupNamespace(values["remote-ns"] ?? "")
        schedule = values["schedule"]
        comment = values["comment"].flatMap { $0.isEmpty ? nil : $0 }
        owner = values["owner"]
        removeVanished = container.lossyBool(AnyCodingKey("remove-vanished")) ?? false
        maxDepth = container.lossyInt(AnyCodingKey("max-depth"))
        groupFilters = container.stringList("group-filter")
        transferLast = container.lossyInt(AnyCodingKey("transfer-last"))
        associatedKeys = container.stringList("associated-key")
        state = JobState(container)
    }
}

extension SyncJob {
    /// Where the job copies from and to, e.g. `self:store1/pve → store2`.
    public var routeDescription: String {
        func location(_ store: String, _ namespace: BackupNamespace) -> String {
            namespace.isRoot ? store : "\(store)/\(namespace.path)"
        }
        let local = location(store, namespace)
        let other = (remote.map { "\($0):" } ?? "") + location(remoteStore, remoteNamespace)
        return direction == .push ? "\(local) → \(other)" : "\(other) → \(local)"
    }
}

/// A verification job, from `GET /admin/verify` or `GET /config/verify`.
public struct VerifyJob: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var store: String
    public var namespace: BackupNamespace
    public var maxDepth: Int?
    public var schedule: String?
    public var comment: String?
    /// Skip snapshots verified before, unless that was more than `reverifyAfterDays` ago.
    public var skipVerified: Bool
    public var reverifyAfterDays: Int?
    public var state: JobState
    public var values: [String: String]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        values = textValues(container)
        id = values["id"] ?? ""
        store = values["store"] ?? ""
        namespace = BackupNamespace(values["ns"] ?? "")
        maxDepth = container.lossyInt(AnyCodingKey("max-depth"))
        schedule = values["schedule"]
        comment = values["comment"].flatMap { $0.isEmpty ? nil : $0 }
        // The server's default skips verified snapshots.
        skipVerified = container.lossyBool(AnyCodingKey("ignore-verified")) ?? true
        reverifyAfterDays = container.lossyInt(AnyCodingKey("outdated-after"))
        state = JobState(container)
    }
}

/// A prune job, from `GET /admin/prune` or `GET /config/prune`.
public struct PruneJob: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var store: String
    public var namespace: BackupNamespace
    public var maxDepth: Int?
    public var schedule: String
    public var comment: String?
    public var isDisabled: Bool
    public var retention: RetentionPolicy
    public var state: JobState
    public var values: [String: String]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        values = textValues(container)
        id = values["id"] ?? ""
        store = values["store"] ?? ""
        namespace = BackupNamespace(values["ns"] ?? "")
        maxDepth = container.lossyInt(AnyCodingKey("max-depth"))
        schedule = values["schedule"] ?? ""
        comment = values["comment"].flatMap { $0.isEmpty ? nil : $0 }
        isDisabled = container.lossyBool(AnyCodingKey("disable")) ?? false
        retention = RetentionPolicy(container)
        state = JobState(container)
    }
}

extension PBS {
    /// Sync jobs with their state, and the digest of their configuration file. `direction` nil leaves the filter out, which lists pull jobs only; servers before
    /// 3.3 have no push jobs and refuse the parameter.
    public static func syncJobs(direction: String? = "all", store: String? = nil) -> APIRequest<Digested<[SyncJob]>> {
        var parameters = APIParameters()
        if let direction { parameters["sync-direction"] = .string(direction) }
        if let store { parameters["store"] = .string(store) }
        return APIRequest(.get, "/admin/sync", parameters: parameters)
    }

    public static func verifyJobs(store: String? = nil) -> APIRequest<Digested<[VerifyJob]>> {
        APIRequest(.get, "/admin/verify", parameters: store.map { ["store": .string($0)] } ?? APIParameters())
    }

    public static func pruneJobs(store: String? = nil) -> APIRequest<Digested<[PruneJob]>> {
        APIRequest(.get, "/admin/prune", parameters: store.map { ["store": .string($0)] } ?? APIParameters())
    }

    /// Runs a job now; returns the task.
    public static func runSyncJob(_ id: String) -> APIRequest<String> {
        APIRequest(.post, "/admin/sync/\(escapePath(id))/run")
    }

    public static func runVerifyJob(_ id: String) -> APIRequest<String> {
        APIRequest(.post, "/admin/verify/\(escapePath(id))/run")
    }

    public static func runPruneJob(_ id: String) -> APIRequest<String> {
        APIRequest(.post, "/admin/prune/\(escapePath(id))/run")
    }

    public static func syncJobConfig(_ id: String) -> APIRequest<Digested<SyncJob>> {
        APIRequest(.get, "/config/sync/\(escapePath(id))")
    }

    public static func verifyJobConfig(_ id: String) -> APIRequest<Digested<VerifyJob>> {
        APIRequest(.get, "/config/verify/\(escapePath(id))")
    }

    public static func pruneJobConfig(_ id: String) -> APIRequest<Digested<PruneJob>> {
        APIRequest(.get, "/config/prune/\(escapePath(id))")
    }

    public static func deleteSyncJob(_ id: String, digest: String? = nil) -> APIRequest<Nothing> {
        APIRequest(.delete, "/config/sync/\(escapePath(id))", parameters: digest.map { ["digest": .string($0)] } ?? APIParameters())
    }

    public static func deleteVerifyJob(_ id: String, digest: String? = nil) -> APIRequest<Nothing> {
        APIRequest(.delete, "/config/verify/\(escapePath(id))", parameters: digest.map { ["digest": .string($0)] } ?? APIParameters())
    }

    public static func deletePruneJob(_ id: String, digest: String? = nil) -> APIRequest<Nothing> {
        APIRequest(.delete, "/config/prune/\(escapePath(id))", parameters: digest.map { ["digest": .string($0)] } ?? APIParameters())
    }
}
