import Foundation
import ProxmoxCore
import PVEKit

/// Whether a datastore lives on a device that can be detached, and if so, whether it is attached now.
public enum DatastoreMountStatus: String, Sendable, Equatable {
    case nonRemovable = "nonremovable"
    case mounted
    case notMounted = "notmounted"
}

/// A datastore's maintenance mode, from its `maintenance-mode` setting: `type=read-only,message="…"`.
public struct DatastoreMaintenance: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case readOnly = "read-only"
        case offline
        /// Set by the server itself while it unmounts, deletes or refreshes a datastore.
        case unmount
        case delete
        case s3Refresh = "s3-refresh"
    }

    /// Nil for a kind this app does not know, which the raw text still shows.
    public var kind: Kind?
    public var rawKind: String
    public var message: String?

    public init(kind: Kind, message: String? = nil) {
        self.kind = kind
        rawKind = kind.rawValue
        self.message = message
    }

    /// Reads `type=offline,message="…"`, also with the type unnamed or after the message. The message is quoted, with
    /// `\"` for quotes inside it.
    public init?(parsing text: String?) {
        guard let text, !text.isEmpty else { return nil }
        var type: String?
        var message: String?
        var current = ""
        var inQuotes = false
        var escaped = false
        func finishItem() {
            if let separator = current.firstIndex(of: "=") {
                let key = current[..<separator]
                let value = String(current[current.index(after: separator)...])
                if key == "message" { message = value } else if key == "type" { type = value }
            } else if !current.isEmpty {
                type = current
            }
            current = ""
        }
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                finishItem()
            } else {
                current.append(character)
            }
        }
        finishItem()
        guard let type else { return nil }
        rawKind = type
        kind = Kind(rawValue: type)
        self.message = message.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The setting's text. Like the web interface, it drops backslashes from the message and escapes quotes.
    public var stringValue: String {
        guard let message, !message.isEmpty else { return "type=\(rawKind)" }
        let escaped = message.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "\\\"")
        return "type=\(rawKind),message=\"\(escaped)\""
    }
}

/// Retention settings (`keep-last`, `keep-daily`…) of a datastore, prune job or prune request. Nil keeps nothing by
/// that rule; with no rule at all, everything is kept.
public struct RetentionPolicy: Sendable, Equatable, Hashable {
    public var last: Int?
    public var hourly: Int?
    public var daily: Int?
    public var weekly: Int?
    public var monthly: Int?
    public var yearly: Int?

    public init(last: Int? = nil, hourly: Int? = nil, daily: Int? = nil, weekly: Int? = nil, monthly: Int? = nil, yearly: Int? = nil) {
        self.last = last
        self.hourly = hourly
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
        self.yearly = yearly
    }

    /// Reads the `keep-*` keys of an object that also holds other settings.
    init(_ container: KeyedDecodingContainer<AnyCodingKey>) {
        func keep(_ name: String) -> Int? { container.lossyInt(AnyCodingKey("keep-\(name)")) }
        self.init(last: keep("last"), hourly: keep("hourly"), daily: keep("daily"), weekly: keep("weekly"),
                  monthly: keep("monthly"), yearly: keep("yearly"))
    }

    public static let keys = ["keep-last", "keep-hourly", "keep-daily", "keep-weekly", "keep-monthly", "keep-yearly"]

    /// The rules in the order of `keys`.
    public var values: [Int?] { [last, hourly, daily, weekly, monthly, yearly] }

    public var keepsEverything: Bool { values.allSatisfy { $0 == nil || $0 == 0 } }

    /// The set rules as request parameters; unset ones are left out.
    public var parameters: APIParameters {
        var parameters = APIParameters()
        for (key, value) in zip(Self.keys, values) {
            if let value, value > 0 { parameters[key] = .int(value) }
        }
        return parameters
    }
}

/// One entry of `GET /admin/datastore`: the datastores the user can see.
public struct DatastoreSummary: Decodable, Sendable, Equatable, Identifiable {
    public var store: String
    public var comment: String?
    /// `filesystem` or `s3`.
    public var backendType: String
    public var mountStatus: DatastoreMountStatus
    public var maintenance: DatastoreMaintenance?

    public var id: String { store }
    public var isS3: Bool { backendType == "s3" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        store = container.lossyString(AnyCodingKey("store")) ?? ""
        comment = container.lossyString(AnyCodingKey("comment")).flatMap { $0.isEmpty ? nil : $0 }
        backendType = container.lossyString(AnyCodingKey("backend-type")) ?? "filesystem"
        mountStatus = container.lossyString(AnyCodingKey("mount-status")).flatMap(DatastoreMountStatus.init) ?? .nonRemovable
        maintenance = DatastoreMaintenance(parsing: container.lossyString(AnyCodingKey("maintenance")))
    }
}

/// Outcome of the latest garbage collection of a datastore, from its status, `GET .../gc` or `GET /admin/gc`, which
/// also carry the schedule and the last and next runs.
public struct GarbageCollectionStatus: Decodable, Sendable, Equatable, Identifiable {
    public var store: String?
    /// The latest run; nil when it never ran.
    public var upid: String?
    public var indexFileCount: Int
    /// Bytes the backups reference, before deduplication.
    public var indexDataBytes: Int64
    /// Bytes the chunks take on disk.
    public var diskBytes: Int64
    public var diskChunks: Int
    public var removedBytes: Int64
    public var removedChunks: Int
    /// Bytes of chunks that are no longer used but too young to be removed yet.
    public var pendingBytes: Int64
    public var pendingChunks: Int
    public var removedBad: Int
    public var stillBad: Int
    public var schedule: String?
    public var nextRun: Date?
    /// `OK`, `WARNINGS: n` or an error; nil while running or before the first run.
    public var lastRunState: String?
    public var lastRunEnd: Date?
    public var duration: TimeInterval?

    public var id: String { store ?? "" }

    /// How many times the referenced data is larger than what it takes on disk.
    public var deduplicationFactor: Double? {
        diskBytes > 0 ? Double(indexDataBytes) / Double(diskBytes) : nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func int(_ key: String) -> Int { container.lossyInt(AnyCodingKey(key)) ?? 0 }
        store = container.lossyString(AnyCodingKey("store"))
        upid = container.lossyString(AnyCodingKey("upid"))
        indexFileCount = int("index-file-count")
        indexDataBytes = container.int64("index-data-bytes") ?? 0
        diskBytes = container.int64("disk-bytes") ?? 0
        diskChunks = int("disk-chunks")
        removedBytes = container.int64("removed-bytes") ?? 0
        removedChunks = int("removed-chunks")
        pendingBytes = container.int64("pending-bytes") ?? 0
        pendingChunks = int("pending-chunks")
        removedBad = int("removed-bad")
        stillBad = int("still-bad")
        schedule = container.lossyString(AnyCodingKey("schedule"))
        nextRun = container.date("next-run")
        lastRunState = container.lossyString(AnyCodingKey("last-run-state"))
        lastRunEnd = container.date("last-run-endtime")
        duration = container.lossyDouble(AnyCodingKey("duration"))
    }
}

/// One entry of `GET /status/datastore-usage`: usage, its history and when the datastore will be full.
public struct DatastoreUsage: Decodable, Sendable, Equatable, Identifiable {
    public var store: String
    public var total: Int64
    public var used: Int64
    public var available: Int64
    /// Share of the datastore used, one value per `historyInterval` since `historyStart`; nil where nothing was recorded.
    public var history: [Double?]
    public var historyStart: Date?
    public var historyInterval: TimeInterval?
    /// The server's estimate from the history; nil without enough of it.
    public var estimatedFullDate: Date?
    /// Why the usage could not be read, e.g. a removable datastore that is not mounted.
    public var error: String?
    public var garbageCollection: GarbageCollectionStatus?
    public var mountStatus: DatastoreMountStatus
    public var backendType: String

    public var id: String { store }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        store = container.lossyString(AnyCodingKey("store")) ?? ""
        total = container.int64("total") ?? 0
        used = container.int64("used") ?? 0
        available = container.int64("avail") ?? 0
        var history: [Double?] = []
        if var list = try? container.nestedUnkeyedContainer(forKey: AnyCodingKey("history")) {
            while !list.isAtEnd {
                if let value = try? list.decode(Double.self) {
                    history.append(value)
                } else {
                    _ = try? list.decodeNil()
                    history.append(nil)
                }
            }
        }
        self.history = history
        historyStart = container.date("history-start")
        historyInterval = container.lossyDouble(AnyCodingKey("history-delta"))
        // An estimate of 0 or below means "never", as the web interface reads it.
        estimatedFullDate = container.date("estimated-full-date").flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        error = container.lossyString(AnyCodingKey("error"))
        garbageCollection = try? container.decodeIfPresent(GarbageCollectionStatus.self, forKey: AnyCodingKey("gc-status"))
        mountStatus = container.lossyString(AnyCodingKey("mount-status")).flatMap(DatastoreMountStatus.init) ?? .nonRemovable
        backendType = container.lossyString(AnyCodingKey("backend-type")) ?? "filesystem"
    }
}

/// `GET /admin/datastore/{store}/status`: usage plus, with `verbose`, backup counts and the last garbage collection.
public struct DatastoreStatus: Decodable, Sendable, Equatable {
    public struct Counts: Sendable, Equatable {
        public var groups: Int
        public var snapshots: Int
    }

    public var total: Int64
    public var used: Int64
    public var available: Int64
    public var counts: [BackupType: Counts]
    /// Groups of a type this app does not know.
    public var otherCounts: Counts?
    public var garbageCollection: GarbageCollectionStatus?
    public var backendType: String
    /// S3 datastores: traffic and requests since the counters were last reset.
    public var s3Statistics: S3Statistics?

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        total = container.int64("total") ?? 0
        used = container.int64("used") ?? 0
        available = container.int64("avail") ?? 0
        func counts(_ object: KeyedDecodingContainer<AnyCodingKey>?, _ key: String) -> Counts? {
            guard let nested = try? object?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(key)) else { return nil }
            return Counts(groups: nested.lossyInt(AnyCodingKey("groups")) ?? 0, snapshots: nested.lossyInt(AnyCodingKey("snapshots")) ?? 0)
        }
        let all = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("counts"))
        var byType: [BackupType: Counts] = [:]
        for type in BackupType.allCases {
            byType[type] = counts(all, type.rawValue)
        }
        self.counts = byType
        otherCounts = counts(all, "other")
        garbageCollection = try? container.decodeIfPresent(GarbageCollectionStatus.self, forKey: AnyCodingKey("gc-status"))
        backendType = container.lossyString(AnyCodingKey("backend-type")) ?? "filesystem"
        s3Statistics = try? container.decodeIfPresent(S3Statistics.self, forKey: AnyCodingKey("s3-statistics"))
    }
}

/// What an S3 datastore sent to and fetched from its bucket, as the web interface's S3 statistics panel shows it.
public struct S3Statistics: Decodable, Sendable, Equatable {
    public var uploaded: Int64
    public var downloaded: Int64
    public var get: Int
    public var put: Int
    public var post: Int
    public var head: Int
    public var delete: Int

    public init(uploaded: Int64 = 0, downloaded: Int64 = 0, get: Int = 0, put: Int = 0, post: Int = 0, head: Int = 0, delete: Int = 0) {
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.get = get
        self.put = put
        self.post = post
        self.head = head
        self.delete = delete
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        uploaded = container.int64("uploaded") ?? 0
        downloaded = container.int64("downloaded") ?? 0
        get = container.lossyInt(AnyCodingKey("get")) ?? 0
        put = container.lossyInt(AnyCodingKey("put")) ?? 0
        post = container.lossyInt(AnyCodingKey("post")) ?? 0
        head = container.lossyInt(AnyCodingKey("head")) ?? 0
        delete = container.lossyInt(AnyCodingKey("delete")) ?? 0
    }
}

/// Readers and writers working on a datastore right now, from `GET .../active-operations`.
public struct DatastoreOperations: Decodable, Sendable, Equatable {
    public var read: Int
    public var write: Int

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        read = container.lossyInt(AnyCodingKey("read")) ?? 0
        write = container.lossyInt(AnyCodingKey("write")) ?? 0
    }
}

/// One sample of `GET /admin/datastore/{store}/rrd`.
public struct DatastoreRRDPoint: Decodable, Sendable, Equatable, Identifiable {
    public var time: Date
    public var total: Double?
    public var used: Double?
    public var available: Double?
    /// Bytes per second.
    public var readBytes: Double?
    public var writeBytes: Double?
    /// Operations per second.
    public var readOperations: Double?
    public var writeOperations: Double?
    /// Share of time the device was busy.
    public var ioTicks: Double?
    /// S3 datastores: bytes per second sent to and fetched from the bucket.
    public var s3Uploaded: Double?
    public var s3Downloaded: Double?

    public var id: Date { time }
    public var hasData: Bool { used != nil || readBytes != nil }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func value(_ key: String) -> Double? { container.lossyDouble(AnyCodingKey(key)) }
        time = Date(timeIntervalSince1970: value("time") ?? 0)
        total = value("total")
        used = value("used")
        available = value("available")
        readBytes = value("read_bytes")
        writeBytes = value("write_bytes")
        readOperations = value("read_ios")
        writeOperations = value("write_ios")
        ioTicks = value("io_ticks")
        s3Uploaded = value("s3/uploaded")
        s3Downloaded = value("s3/downloaded")
    }

    /// Milliseconds an operation waited, as the web interface works it out from the busy time and the operations.
    public var ioDelay: Double? {
        guard let ioTicks else { return nil }
        let operations = (readOperations ?? 0) + (writeOperations ?? 0)
        return operations == 0 ? 0 : ioTicks * 1000 / operations
    }
}

/// A datastore's settings, from `GET /config/datastore` and `GET /config/datastore/{name}`.
public struct DatastoreConfig: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    /// For removable datastores, relative to the device's mount point.
    public var path: String
    public var comment: String?
    public var gcSchedule: String?
    public var pruneSchedule: String?
    public var retention: RetentionPolicy
    public var verifyNew: Bool
    public var maintenance: DatastoreMaintenance?
    /// UUID of the file system on the removable device.
    public var backingDevice: String?
    /// `type=s3,client=<endpoint>,bucket=<bucket>` for S3 datastores.
    public var backend: PropertyString?
    /// Every setting as text, for editors that keep the ones they do not know.
    public var values: [String: String]

    public var id: String { name }
    public var isRemovable: Bool { backingDevice != nil }
    public var isS3: Bool { backend?["type"] == "s3" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: String] = [:]
        for key in container.allKeys {
            if let text = container.lossyString(key) {
                values[key.stringValue] = text
            } else if let flag = container.lossyBool(key) {
                values[key.stringValue] = flag ? "1" : "0"
            }
        }
        self.values = values
        name = values["name"] ?? ""
        path = values["path"] ?? ""
        comment = values["comment"].flatMap { $0.isEmpty ? nil : $0 }
        gcSchedule = values["gc-schedule"]
        pruneSchedule = values["prune-schedule"]
        retention = RetentionPolicy(container)
        verifyNew = container.lossyBool(AnyCodingKey("verify-new")) ?? false
        maintenance = DatastoreMaintenance(parsing: values["maintenance-mode"])
        backingDevice = values["backing-device"]
        backend = values["backend"].map(PropertyString.init(parsing:))
    }
}

extension PBS {
    /// Datastores the user can see, with their mount and maintenance state.
    public static func datastores() -> APIRequest<[DatastoreSummary]> {
        APIRequest(.get, "/admin/datastore")
    }

    public static func datastoreUsage() -> APIRequest<[DatastoreUsage]> {
        APIRequest(.get, "/status/datastore-usage")
    }

    public static func datastoreStatus(_ store: String) -> APIRequest<DatastoreStatus> {
        APIRequest(.get, "/admin/datastore/\(escapePath(store))/status", parameters: ["verbose": true])
    }

    public static func datastoreRRD(_ store: String, timeframe: RRDTimeframe) -> APIRequest<[DatastoreRRDPoint]> {
        APIRequest(.get, "/admin/datastore/\(escapePath(store))/rrd", parameters: ["timeframe": .string(timeframe.rawValue), "cf": "AVERAGE"])
    }

    public static func activeOperations(_ store: String) -> APIRequest<DatastoreOperations> {
        APIRequest(.get, "/admin/datastore/\(escapePath(store))/active-operations")
    }

    public static func garbageCollectionStatus(_ store: String) -> APIRequest<GarbageCollectionStatus> {
        APIRequest(.get, "/admin/datastore/\(escapePath(store))/gc")
    }

    /// Starts garbage collection; returns the task.
    public static func startGarbageCollection(_ store: String) -> APIRequest<String> {
        APIRequest(.post, "/admin/datastore/\(escapePath(store))/gc")
    }

    /// The garbage collection of every datastore with its schedule and last run.
    public static func garbageCollectionJobs() -> APIRequest<[GarbageCollectionStatus]> {
        APIRequest(.get, "/admin/gc")
    }

    public static func datastoreConfigs() -> APIRequest<Digested<[DatastoreConfig]>> {
        APIRequest(.get, "/config/datastore")
    }

    public static func datastoreConfig(_ name: String) -> APIRequest<Digested<DatastoreConfig>> {
        APIRequest(.get, "/config/datastore/\(escapePath(name))")
    }

    /// Mounts a removable datastore's device; returns the task.
    public static func mountDatastore(_ store: String) -> APIRequest<String> {
        APIRequest(.post, "/admin/datastore/\(escapePath(store))/mount")
    }

    public static func unmountDatastore(_ store: String) -> APIRequest<String> {
        APIRequest(.post, "/admin/datastore/\(escapePath(store))/unmount")
    }

    /// Reads the contents of an S3 datastore's bucket again, e.g. after objects changed outside the server. The
    /// datastore is in maintenance meanwhile. Returns the task.
    public static func refreshFromS3(_ store: String) -> APIRequest<String> {
        APIRequest(.put, "/admin/datastore/\(escapePath(store))/s3-refresh")
    }

    /// Removes a datastore; returns the task. With `destroyData` its backups are deleted too, and with `keepJobs`
    /// the jobs that use it stay configured.
    public static func deleteDatastore(_ name: String, destroyData: Bool, keepJobs: Bool, digest: String?) -> APIRequest<String> {
        var parameters: APIParameters = ["destroy-data": .bool(destroyData), "keep-job-configs": .bool(keepJobs)]
        if let digest { parameters["digest"] = .string(digest) }
        return APIRequest(.delete, "/config/datastore/\(escapePath(name))", parameters: parameters)
    }
}
