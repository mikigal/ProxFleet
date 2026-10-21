import Foundation
import ProxmoxCore

/// Which guests a backup job covers.
public enum BackupSelection: Equatable, Sendable {
    /// Every guest, except the listed IDs.
    case all(excluding: [Int])
    case guests([Int])
    case pool(String)
}

/// One entry of `GET /cluster/backup`: a scheduled `vzdump` job.
public struct BackupJob: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var isEnabled: Bool
    /// A systemd-style calendar event, e.g. `sat 02:00` or `*/6:00`.
    public var schedule: String
    public var storage: String?
    /// Only runs on this node; nil for all nodes.
    public var node: String?
    public var mode: String
    public var compression: String?
    public var selection: BackupSelection
    public var comment: String?
    public var notesTemplate: String?
    /// nil uses the retention of the target storage.
    public var prune: PruneOptions?
    public var isProtected: Bool
    public var repeatMissed: Bool
    public var nextRun: Date?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func text(_ key: String) -> String? {
            container.lossyString(AnyCodingKey(key))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        func ids(_ key: String) -> [Int] {
            (text(key) ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
        }
        id = text("id") ?? ""
        isEnabled = container.lossyBool(AnyCodingKey("enabled")) ?? true
        // Jobs from before PVE 7 have `dow` and `starttime`; the server converts them, but old entries may linger.
        schedule = text("schedule") ?? [text("dow"), text("starttime")].compactMap { $0 }.joined(separator: " ")
        storage = text("storage")
        node = text("node")
        mode = text("mode") ?? "snapshot"
        compression = text("compress")
        if container.lossyBool(AnyCodingKey("all")) == true {
            selection = .all(excluding: ids("exclude"))
        } else if let pool = text("pool") {
            selection = .pool(pool)
        } else {
            selection = .guests(ids("vmid"))
        }
        comment = text("comment")
        notesTemplate = text("notes-template")
        // `prune-backups` comes as an object here, unlike in storage definitions.
        if let nested = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("prune-backups")) {
            var options = PruneOptions()
            options.keepAll = nested.lossyBool(AnyCodingKey("keep-all")) ?? false
            for key in PruneOptions.keys {
                if let value = nested.lossyString(AnyCodingKey(key)) { options.counts[key] = value }
            }
            prune = options
        } else {
            prune = text("prune-backups").map { PruneOptions($0) }
        }
        isProtected = container.lossyBool(AnyCodingKey("protected")) ?? false
        repeatMissed = container.lossyBool(AnyCodingKey("repeat-missed")) ?? false
        nextRun = container.lossyInt(AnyCodingKey("next-run")).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// The `vzdump` calls that run the job now, one per node, as the web interface's Run Now does: jobs for all
    /// guests or a pool run on every online node, jobs for listed guests on the nodes those guests are on.
    public func runNowRequests(in snapshot: ClusterSnapshot) -> [(node: String, request: APIRequest<String?>)] {
        let online = snapshot.nodes.filter(\.isOnline).map(\.name).filter { node == nil || $0 == node }
        var base = APIParameters()
        if let storage { base["storage"] = .string(storage) }
        base["mode"] = .string(mode)
        if let compression { base["compress"] = .string(compression) }
        if let notesTemplate { base["notes-template"] = .string(notesTemplate) }
        if isProtected { base["protected"] = true }
        if let prune = prune?.serialized { base["prune-backups"] = .string(prune) }

        func request(_ node: String, _ extra: APIParameters) -> (node: String, request: APIRequest<String?>) {
            var parameters = base
            for item in extra.items { parameters[item.name] = item.value }
            return (node, APIRequest(.post, "/nodes/\(node)/vzdump", parameters: parameters))
        }
        switch selection {
        case .all(let excluding):
            var extra: APIParameters = ["all": true]
            if !excluding.isEmpty { extra["exclude"] = .string(excluding.map(String.init).joined(separator: ",")) }
            return online.map { request($0, extra) }
        case .pool(let pool):
            return online.map { request($0, ["pool": .string(pool)]) }
        case .guests(let vmids):
            let byNode = Dictionary(grouping: vmids) { vmid in snapshot.guests.first { $0.vmid == vmid }?.node ?? "" }
            return online.compactMap { node in
                guard let ids = byNode[node], !ids.isEmpty else { return nil }
                return request(node, ["vmid": .string(ids.sorted().map(String.init).joined(separator: ","))])
            }
        }
    }
}

/// `GET /cluster/jobs/schedule-analyze`: when a schedule runs next.
public struct ScheduledRun: Decodable, Sendable, Equatable {
    public var date: Date

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        date = Date(timeIntervalSince1970: TimeInterval(container.lossyInt(AnyCodingKey("timestamp")) ?? 0))
    }
}

/// A guest that no backup job covers, from `GET /cluster/backup-info/not-backed-up`.
public struct UnprotectedGuest: Decodable, Sendable, Equatable, Identifiable {
    public var vmid: Int
    public var name: String?
    /// `qemu` or `lxc`.
    public var type: String

    public var id: Int { vmid }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        vmid = container.lossyInt(AnyCodingKey("vmid")) ?? 0
        name = container.lossyString(AnyCodingKey("name"))
        type = container.lossyString(AnyCodingKey("type")) ?? "qemu"
    }
}

/// The form for a backup job. Like the other drafts, it sends only what changed and `delete` for cleared settings.
public struct BackupJobDraft: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable, Identifiable {
        case all, guests, exclude, pool

        public var id: String { rawValue }
    }

    /// Schedules the web interface suggests, with what they mean.
    public static let schedulePresets: [(schedule: String, title: String)] = [
        ("21:00", String(localized: "Every day at 21:00")),
        ("2,22:30", String(localized: "Every day at 02:30 and 22:30")),
        ("mon..fri 00:00", String(localized: "Monday to Friday at 00:00")),
        ("sat 02:00", String(localized: "Every Saturday at 02:00")),
        ("*/6:00", String(localized: "Every six hours")),
        ("sat *-1..7 15:00", String(localized: "First Saturday of the month at 15:00")),
    ]

    public var isEnabled = true
    public var schedule = "21:00"
    public var storage = ""
    /// Empty for all nodes.
    public var node = ""
    public var backupMode = "snapshot"
    public var compression = "zstd"
    public var selectionMode = Mode.all
    public var guests: Set<Int> = []
    public var pool = ""
    public var comment = ""
    public var notesTemplate = "{{guestname}}"
    /// Off uses the retention of the target storage.
    public var customRetention = false
    public var prune = PruneOptions()
    public var isProtected = false
    public var repeatMissed = false

    public init() {}

    public init(_ job: BackupJob) {
        isEnabled = job.isEnabled
        schedule = job.schedule
        storage = job.storage ?? ""
        node = job.node ?? ""
        backupMode = job.mode
        compression = job.compression ?? "0"
        switch job.selection {
        case .all(let excluding):
            selectionMode = excluding.isEmpty ? .all : .exclude
            guests = Set(excluding)
        case .guests(let vmids):
            selectionMode = .guests
            guests = Set(vmids)
        case .pool(let name):
            selectionMode = .pool
            pool = name
        }
        comment = job.comment ?? ""
        notesTemplate = job.notesTemplate ?? ""
        customRetention = job.prune != nil
        prune = job.prune ?? PruneOptions()
        isProtected = job.isProtected
        repeatMissed = job.repeatMissed
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        // updateValue keeps nil values, which mark settings to delete; assigning nil would drop the key.
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        let ids = guests.sorted().map(String.init).joined(separator: ",")
        set("enabled", isEnabled ? "1" : "0")
        set("schedule", Self.text(schedule))
        set("storage", Self.text(storage))
        set("node", Self.text(node))
        set("mode", backupMode)
        set("compress", compression)
        set("all", selectionMode == .all || selectionMode == .exclude ? "1" : nil)
        set("exclude", selectionMode == .exclude && !ids.isEmpty ? ids : nil)
        set("vmid", selectionMode == .guests && !ids.isEmpty ? ids : nil)
        set("pool", selectionMode == .pool ? Self.text(pool) : nil)
        set("comment", Self.text(comment))
        set("notes-template", Self.text(notesTemplate))
        set("prune-backups", customRetention ? (prune.serialized ?? "keep-all=1") : nil)
        set("protected", isProtected ? "1" : nil)
        set("repeat-missed", repeatMissed ? "1" : nil)
        return values
    }

    var creationParameters: APIParameters {
        var parameters = APIParameters()
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        return parameters
    }

    public func changes(from original: BackupJobDraft) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let old = original.serialized()
        for (key, value) in serialized() where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        return update
    }

    public var problems: [String: String] {
        var problems = customRetention ? prune.problems : [:]
        if Self.text(schedule) == nil { problems["schedule"] = String(localized: "Enter a schedule.") }
        if Self.text(storage) == nil { problems["storage"] = String(localized: "Choose a storage.") }
        switch selectionMode {
        case .guests where guests.isEmpty: problems["vmid"] = String(localized: "Choose at least one guest.")
        case .exclude where guests.isEmpty: problems["exclude"] = String(localized: "Choose the guests to leave out.")
        case .pool where Self.text(pool) == nil: problems["pool"] = String(localized: "Choose a pool.")
        default: break
        }
        return problems
    }
}

extension PVE {
    public static func backupJobs() -> APIRequest<[BackupJob]> {
        APIRequest(.get, "/cluster/backup")
    }

    public static func createBackupJob(_ draft: BackupJobDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/backup", parameters: draft.creationParameters)
    }

    public static func updateBackupJob(_ id: String, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/cluster/backup/\(escapePath(id))", parameters: update.parameters)
    }

    public static func deleteBackupJob(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/backup/\(escapePath(id))")
    }

    /// The next runs of a schedule. The server refuses schedules it cannot parse, with a message for `schedule`.
    public static func scheduleRuns(_ schedule: String, count: Int = 3) -> APIRequest<[ScheduledRun]> {
        APIRequest(.get, "/cluster/jobs/schedule-analyze", parameters: ["schedule": .string(schedule), "iterations": .int(count)])
    }

    public static func guestsWithoutBackupJob() -> APIRequest<[UnprotectedGuest]> {
        APIRequest(.get, "/cluster/backup-info/not-backed-up")
    }
}
