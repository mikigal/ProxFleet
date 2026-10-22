import Foundation
import ProxmoxCore

/// A scheduled backup job in demo mode, stored as the API returns it.
struct DemoBackupJob: Sendable {
    var id: String
    var values: [String: String]
}

/// `/cluster/backup`, `/cluster/backup-info` and `/cluster/jobs/schedule-analyze` in demo mode.
extension DemoState {
    private static let jobKeys: Set<String> = [
        "enabled", "schedule", "storage", "node", "mode", "compress", "all", "exclude", "vmid", "pool", "comment",
        "notes-template", "prune-backups", "protected", "repeat-missed",
    ]

    static func sampleBackupJobs(for cluster: DemoCluster) -> [DemoBackupJob] {
        var jobs = [
            DemoBackupJob(id: "backup-6b1f2c9e-0d41", values: [
                "schedule": "21:00", "storage": "local", "mode": "snapshot", "compress": "zstd", "all": "1", "exclude": "9000",
                "notes-template": "{{guestname}}", "comment": "Nightly, everything", "enabled": "1",
            ]),
        ]
        if cluster.clusterName != nil {
            jobs.append(DemoBackupJob(id: "backup-a37e5d10-77c2", values: [
                "schedule": "sat 02:00", "storage": "pbs", "mode": "snapshot", "vmid": "100,101,200",
                "notes-template": "{{guestname}} weekly", "comment": "Weekly to PBS", "enabled": "1", "prune-backups": "keep-weekly=8",
            ]))
        }
        return jobs
    }

    /// Routes below `/cluster/backup`, `/cluster/backup-info` and `/cluster/jobs`. nil for other paths.
    func handleBackupJobs(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard parts.count >= 2, parts[0] == "cluster" else { return nil }
        switch (method, Array(parts.dropFirst())) {
        case (.get, ["jobs", "schedule-analyze"]):
            guard let schedule = parameters["schedule"], let runs = Self.nextRuns(of: schedule, count: Int(parameters["iterations"] ?? "") ?? 10) else {
                return fieldFailure(["schedule": "invalid format - invalid calendar event '\(parameters["schedule"] ?? "")'"])
            }
            return success(.array(runs.map { ["timestamp": .int(Int($0.timeIntervalSince1970)), "utc": .string($0.description)] }))
        case (.get, ["backup-info", "not-backed-up"]):
            let covered = Set(cluster.guests.filter { guest in backupJobs.contains { covers($0, guest) } }.map(\.vmid))
            return success(.array(cluster.guests.filter { !covered.contains($0.vmid) }.map { guest in
                ["vmid": .int(guest.vmid), "name": .string(guest.name), "type": .string(guest.kind.rawValue)]
            }))
        case (.get, ["backup"]):
            return success(.array(backupJobs.map(jobJSON)))
        case (.get, let path) where path.count == 2 && path[0] == "backup":
            guard let job = backupJobs.first(where: { $0.id == path[1] }) else { return failure(500, "job '\(path[1])' does not exist") }
            return success(jobJSON(job))
        case (.post, ["backup"]):
            return saveJob(id: nil, parameters: parameters, user: user)
        case (.put, let path) where path.count == 2 && path[0] == "backup":
            return saveJob(id: path[1], parameters: parameters, user: user)
        case (.delete, let path) where path.count == 2 && path[0] == "backup":
            guard privileges(for: user).contains("Sys.Modify") else { return failure(403, "Permission check failed (/, Sys.Modify)") }
            guard let index = backupJobs.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "job '\(path[1])' does not exist") }
            backupJobs.remove(at: index)
            return success(nil)
        default:
            return nil
        }
    }

    private func saveJob(id: String?, parameters: [String: String], user: String) -> HTTPResponse {
        guard privileges(for: user).contains("Sys.Modify") else { return failure(403, "Permission check failed (/, Sys.Modify)") }
        if let schedule = parameters["schedule"], Self.nextRuns(of: schedule, count: 1) == nil {
            return fieldFailure(["schedule": "invalid format - invalid calendar event '\(schedule)'"])
        }
        if let storage = parameters["storage"], !storageConfigs.contains(where: { $0.id == storage && $0.content.contains("backup") }) {
            return fieldFailure(["storage": "storage '\(storage)' does not support backups"])
        }
        var values: [String: String] = [:]
        var index: Int?
        if let id {
            index = backupJobs.firstIndex { $0.id == id }
            guard let index else { return failure(500, "job '\(id)' does not exist") }
            values = backupJobs[index].values
            for key in (parameters["delete"] ?? "").split(separator: ",") { values[String(key)] = nil }
        }
        for (key, value) in parameters where Self.jobKeys.contains(key) { values[key] = value }
        // Selecting all guests replaces a list of guests and the other way round, as on a real server.
        if parameters["all"] == "1" { values["vmid"] = nil; values["pool"] = nil }
        if parameters["vmid"] != nil || parameters["pool"] != nil { values["all"] = nil; values["exclude"] = nil }
        guard values["all"] == "1" || values["vmid"] != nil || values["pool"] != nil else {
            return fieldFailure(["vmid": "please specify 'vmid', 'pool' or 'all'"])
        }
        if let index {
            backupJobs[index].values = values
        } else {
            backupJobs.append(DemoBackupJob(id: "backup-\(UUID().uuidString.prefix(13).lowercased())", values: values))
        }
        return success(nil)
    }

    private func covers(_ job: DemoBackupJob, _ guest: DemoCluster.Guest) -> Bool {
        guard job.values["enabled"] != "0" else { return false }
        let ids = { (key: String) in Set((job.values[key] ?? "").split(separator: ",").compactMap { Int($0) }) }
        if job.values["all"] == "1" { return !ids("exclude").contains(guest.vmid) }
        if let pool = job.values["pool"] { return poolGuests(pool).contains(guest.vmid) }
        return ids("vmid").contains(guest.vmid)
    }

    private func jobJSON(_ job: DemoBackupJob) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(job.id), "type": "vzdump"]
        for (key, value) in job.values {
            if key == "prune-backups" {
                let property = PropertyString(parsing: value)
                object[key] = .object(Dictionary(uniqueKeysWithValues: property.items.compactMap { item in item.key.map { ($0, JSONValue.string(item.value)) } }))
            } else if ["enabled", "all", "protected", "repeat-missed"].contains(key) {
                object[key] = .int(value == "1" ? 1 : 0)
            } else {
                object[key] = .string(value)
            }
        }
        if job.values["enabled"] != "0", let next = Self.nextRuns(of: job.values["schedule"] ?? "", count: 1)?.first {
            object["next-run"] = .int(Int(next.timeIntervalSince1970))
        }
        return .object(object)
    }

    /// A small subset of systemd calendar events: `[weekdays] hours:minutes`, where weekdays are `sat`, `mon..fri` or
    /// `mon,wed`, hours are `21`, `2,22` or `*/6`, and an optional `*-1..7` day range. nil when it cannot be parsed.
    static func nextRuns(of schedule: String, count: Int, from start: Date = Date()) -> [Date]? {
        let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        var parts = schedule.lowercased().split(separator: " ").map(String.init)
        guard let time = parts.popLast() else { return nil }
        var weekdays = Set(1...7)
        var monthDays = Set(1...31)
        for part in parts {
            if part.hasPrefix("*-") {
                let range = part.dropFirst(2).components(separatedBy: "..").compactMap { Int($0) }
                guard range.count == 2, range[0] <= range[1] else { return nil }
                monthDays = Set(range[0]...range[1])
                continue
            }
            var set = Set<Int>()
            for item in part.split(separator: ",") {
                let bounds = item.components(separatedBy: "..")
                guard let first = days.firstIndex(of: bounds[0]) else { return nil }
                let last = bounds.count > 1 ? days.firstIndex(of: bounds[1]) : first
                guard let last, first <= last else { return nil }
                set.formUnion((first...last).map { $0 + 1 })
            }
            weekdays = set
        }
        let pieces = time.split(separator: ":")
        guard pieces.count == 2, let minute = Int(pieces[1]), (0..<60).contains(minute) else { return nil }
        var hours: Set<Int>
        if pieces[0].hasPrefix("*/"), let step = Int(pieces[0].dropFirst(2)), step > 0 {
            hours = Set(stride(from: 0, to: 24, by: step))
        } else {
            let list = pieces[0].split(separator: ",").compactMap { Int($0) }
            guard !list.isEmpty, list.allSatisfy({ (0..<24).contains($0) }) else { return nil }
            hours = Set(list)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var runs: [Date] = []
        let today = calendar.startOfDay(for: start)
        for offset in 0..<62 where runs.count < count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let parts = calendar.dateComponents([.weekday, .day], from: day)
            guard weekdays.contains(parts.weekday ?? 0), monthDays.contains(parts.day ?? 0) else { continue }
            for hour in hours.sorted() where runs.count < count {
                if let run = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), run > start { runs.append(run) }
            }
        }
        return runs.isEmpty ? nil : runs
    }
}
