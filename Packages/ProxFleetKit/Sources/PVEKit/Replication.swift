import Foundation
import ProxmoxCore

/// A storage replication job: a guest's ZFS volumes copied to another node on a schedule, so the guest can start
/// there quickly, by migration or HA. `GET /cluster/replication` lists the configuration; a node's
/// `GET /nodes/{node}/replication` adds the state of the jobs of its guests.
public struct ReplicationJob: Decodable, Sendable, Equatable, Identifiable {
    /// `<guest>-<job number>`, e.g. `100-0`.
    public var id: String
    public var guest: Int
    public var jobNumber: Int
    public var target: String
    /// The node the guest ran on when the job last ran.
    public var source: String?
    public var schedule: String
    /// Megabytes per second; nil for unlimited.
    public var rate: Double?
    public var comment: String?
    public var isEnabled: Bool
    /// `local` or `full` once the job is deleted: it removes its snapshots (and with `full` the copies on the
    /// target) on its next run, then disappears.
    public var removal: String?
    public var digest: String?

    // State, from a node's list only.

    /// `qemu` or `lxc`.
    public var guestType: String?
    public var lastSync: Date?
    public var lastTry: Date?
    /// Before the first run Proxmox reports a time in 1970, which the web interface shows as pending.
    public var nextSync: Date?
    public var duration: TimeInterval?
    public var failCount: Int
    public var error: String?
    /// The job is copying right now.
    public var isRunning: Bool

    public static let defaultSchedule = "*/15"

    public init(
        id: String, guest: Int, jobNumber: Int = 0, target: String, source: String? = nil, schedule: String = defaultSchedule, rate: Double? = nil,
        comment: String? = nil, isEnabled: Bool = true, removal: String? = nil, lastSync: Date? = nil, nextSync: Date? = nil, failCount: Int = 0,
        error: String? = nil, isRunning: Bool = false
    ) {
        self.id = id
        self.guest = guest
        self.jobNumber = jobNumber
        self.target = target
        self.source = source
        self.schedule = schedule
        self.rate = rate
        self.comment = comment
        self.isEnabled = isEnabled
        self.removal = removal
        self.lastSync = lastSync
        self.nextSync = nextSync
        self.failCount = failCount
        self.error = error
        self.isRunning = isRunning
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func date(_ key: String) -> Date? {
            container.lossyDouble(AnyCodingKey(key)).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        }
        id = container.lossyString(AnyCodingKey("id")) ?? ""
        let parts = id.split(separator: "-")
        guest = container.lossyInt(AnyCodingKey("guest")) ?? parts.first.flatMap { Int($0) } ?? 0
        jobNumber = container.lossyInt(AnyCodingKey("jobnum")) ?? parts.last.flatMap { Int($0) } ?? 0
        target = container.lossyString(AnyCodingKey("target")) ?? ""
        source = container.lossyString(AnyCodingKey("source"))
        schedule = container.lossyString(AnyCodingKey("schedule")) ?? Self.defaultSchedule
        rate = container.lossyDouble(AnyCodingKey("rate"))
        comment = container.lossyString(AnyCodingKey("comment"))
        isEnabled = !(container.lossyBool(AnyCodingKey("disable")) ?? false)
        removal = container.lossyString(AnyCodingKey("remove_job"))
        digest = container.lossyString(AnyCodingKey("digest"))
        guestType = container.lossyString(AnyCodingKey("vmtype"))
        lastSync = date("last_sync")
        lastTry = date("last_try")
        nextSync = date("next_sync")
        duration = container.lossyDouble(AnyCodingKey("duration"))
        failCount = container.lossyInt(AnyCodingKey("fail_count")) ?? 0
        error = container.lossyString(AnyCodingKey("error"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        isRunning = container.lossyInt(AnyCodingKey("pid")) != nil
    }

    /// Whether the next run is due, like the web interface's "pending".
    public func isPending(at now: Date = Date()) -> Bool {
        nextSync.map { $0 < now } ?? false
    }
}

/// The web interface's Replication Job dialog.
public struct ReplicationJobDraft: Sendable, Equatable {
    public var guest: Int
    public var target = ""
    public var schedule = ReplicationJob.defaultSchedule
    /// Megabytes per second, empty for unlimited.
    public var rate = ""
    public var comment = ""
    public var isEnabled = true

    public init(guest: Int, target: String = "") {
        self.guest = guest
        self.target = target
    }

    public init(_ job: ReplicationJob) {
        guest = job.guest
        target = job.target
        schedule = job.schedule
        rate = job.rate.map(Self.number) ?? ""
        comment = job.comment ?? ""
        isEnabled = job.isEnabled
    }

    /// Schedules the web interface's calendar field suggests, with what they mean.
    public static let schedulePresets: [(schedule: String, title: String)] = [
        ("*/1", String(localized: "Every minute")),
        ("*/15", String(localized: "Every 15 minutes")),
        ("*/30", String(localized: "Every 30 minutes")),
        ("*/2:00", String(localized: "Every two hours")),
        ("21:00", String(localized: "Every day at 21:00")),
        ("mon..fri 00:00", String(localized: "Monday to Friday at 00:00")),
    ]

    /// Proxmox does not number jobs itself: the web interface takes the guest's highest job number plus one.
    public static func nextID(for guest: Int, existing: [ReplicationJob]) -> String {
        let highest = existing.filter { $0.guest == guest }.map(\.jobNumber).max() ?? -1
        return "\(guest)-\(highest + 1)"
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Values as stored, nil for the default; the default schedule is left out, as in the web interface.
    func serialized() -> [String: String?] {
        let schedule = Self.text(schedule)
        return [
            "schedule": schedule == ReplicationJob.defaultSchedule ? nil : schedule,
            "rate": Self.text(rate).map { $0.replacingOccurrences(of: ",", with: ".") },
            "comment": Self.text(comment),
            "disable": isEnabled ? nil : "1",
        ]
    }

    func creationParameters(id: String) -> APIParameters {
        var parameters: APIParameters = ["id": .string(id), "type": "local", "target": .string(target)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        return parameters
    }

    /// Changed settings; cleared ones are deleted, so they fall back to their default.
    public func changes(from original: ReplicationJobDraft) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let old = original.serialized()
        for (key, value) in serialized() where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        return update
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if !(100...999_999_999).contains(guest) { problems["guest"] = String(localized: "Choose a guest.") }
        if target.isEmpty { problems["target"] = String(localized: "Choose a target node.") }
        if let rate = Self.text(rate), !(Double(rate.replacingOccurrences(of: ",", with: ".")).map { $0 >= 1 } ?? false) {
            problems["rate"] = String(localized: "Enter at least 1 MB/s, or leave it empty for no limit.")
        }
        return problems
    }
}

extension PVE {
    /// The configuration of every replication job of the cluster.
    public static func replicationJobs() -> APIRequest<[ReplicationJob]> {
        APIRequest(.get, "/cluster/replication")
    }

    /// The jobs of the guests on a node, with their state; only those of one guest when given.
    public static func replicationStatus(node: String, guest: Int? = nil) -> APIRequest<[ReplicationJob]> {
        APIRequest(.get, "/nodes/\(node)/replication", parameters: guest.map { ["guest": .int($0)] } ?? [:])
    }

    public static func replicationJob(_ id: String) -> APIRequest<ReplicationJob> {
        APIRequest(.get, "/cluster/replication/\(escapePath(id))")
    }

    /// Creates a job. Proxmox refuses guests with volumes on storage that cannot replicate (only ZFS can).
    public static func createReplicationJob(_ draft: ReplicationJobDraft, id: String) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/replication", parameters: draft.creationParameters(id: id))
    }

    public static func updateReplicationJob(_ id: String, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/cluster/replication/\(escapePath(id))", parameters: update.parameters)
    }

    /// Marks the job for removal: its next run deletes its snapshots and, unless `keep`, the copies on the target,
    /// then the job itself.
    public static func deleteReplicationJob(_ id: String, keep: Bool = false) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/replication/\(escapePath(id))", parameters: keep ? ["keep": true] : [:])
    }

    /// Runs the job as soon as the node's scheduler gets to it, within about a minute. Not a task.
    public static func runReplicationNow(node: String, id: String) -> APIRequest<String?> {
        APIRequest(.post, "/nodes/\(node)/replication/\(escapePath(id))/schedule_now")
    }

    /// The log of the job's last run, on the node it runs on.
    public static func replicationLog(node: String, id: String) -> APIRequest<[TaskLogLine]> {
        APIRequest(.get, "/nodes/\(node)/replication/\(escapePath(id))/log", parameters: ["limit": 500])
    }
}
