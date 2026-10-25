import Foundation
import ProxmoxCore

/// A sync, verification or prune job of the demo backup server, with its settings as the API names them.
struct DemoBackupServerJob: Sendable {
    enum Kind: String, Sendable {
        case sync, verify, prune

        /// The task type its runs have.
        var taskType: String {
            switch self {
            case .sync: "syncjob"
            case .verify: "verificationjob"
            case .prune: "prunejob"
            }
        }
    }

    var kind: Kind
    var id: String
    var settings: [String: String]
    /// List settings: `group-filter` and `associated-key`.
    var lists: [String: [String]] = [:]

    var store: String { settings["store"] ?? "" }

    /// The task ID its runs have, as the real server builds it.
    var workerID: String {
        switch kind {
        case .sync:
            let ns = settings["ns"] ?? ""
            return "\(settings["remote"] ?? "-"):\(settings["remote-store"] ?? ""):\(store):\(ns):\(id)"
        case .verify:
            return "\(store):\(id)"
        case .prune:
            let ns = settings["ns"] ?? ""
            return ns.isEmpty ? store : "\(store):\(ns)"
        }
    }
}

/// A remote of the demo backup server. The password is kept, but never returned.
struct DemoBackupServerRemote: Sendable {
    var name: String
    var settings: [String: String]
    var password: String
}

/// Jobs, remotes and encryption keys of the demo backup server.
extension DemoBackupServerState {
    static let defaultJobs: [DemoBackupServerJob] = [
        DemoBackupServerJob(kind: .sync, id: "offsite-copy", settings: [
            "store": "offsite", "remote-store": "main", "remote-ns": "homelab", "schedule": "sun 05:00", "comment": "Copy to the USB disk",
            "remove-vanished": "1", "run-on-mount": "1", "unmount-on-done": "1", "owner": "root@pam",
        ]),
        DemoBackupServerJob(kind: .sync, id: "cloud-push", settings: [
            "store": "main", "ns": "homelab", "remote": "cloud", "remote-store": "homelab-copy", "schedule": "06:30", "sync-direction": "push",
            "comment": "Off-site copy in the cloud", "transfer-last": "3", "rate-out": "20 MiB", "owner": "backup@pbs",
            "active-encryption-key": "cloud-2026",
        ], lists: ["group-filter": ["type:vm", "type:ct", "exclude:group:vm/103"], "associated-key": ["cloud-2025"]]),
        DemoBackupServerJob(kind: .verify, id: "weekly-verify", settings: [
            "store": "main", "schedule": "sun 04:00", "comment": "Weekly verification", "ignore-verified": "1", "outdated-after": "30",
        ]),
        DemoBackupServerJob(kind: .prune, id: "default-main-e0c4a2f1-3b8d", settings: [
            "store": "main", "schedule": "03:00", "comment": "Nightly retention", "keep-last": "3", "keep-daily": "7", "keep-weekly": "4",
            "keep-monthly": "6",
        ]),
    ]

    static let defaultRemotes: [DemoBackupServerRemote] = [
        DemoBackupServerRemote(name: "cloud", settings: [
            "host": "pbs.example.net", "auth-id": "sync@pbs!homelab", "comment": "Rented backup server",
            "fingerprint": "4f:1c:9a:e2:7b:30:d5:88:61:0e:ab:3c:f2:94:17:c6:5d:a0:22:8e:b9:43:7f:16:e8:0b:c5:72:39:fd:a6:01",
        ], password: "secret"),
    ]

    /// Routes below `/admin/{sync,verify,prune,gc}` and `/config/{sync,verify,prune,remote}`. nil for other paths.
    func handleJobs(_ method: HTTPMethod, parts: [String], parameters: [String: String]) -> HTTPResponse? {
        switch (method, parts) {
        case (.get, ["admin", "gc"]):
            return success(.array(server.datastores.map(garbageCollectionJSON)))
        case (.get, let path) where path.count == 2 && path[0] == "admin":
            guard let kind = DemoBackupServerJob.Kind(rawValue: path[1]) else { return nil }
            return digested(.array(listedJobs(kind, parameters).map { jobJSON($0, withState: true) }))
        case (.post, let path) where path.count == 4 && path[0] == "admin" && path[3] == "run":
            guard let kind = DemoBackupServerJob.Kind(rawValue: path[1]) else { return nil }
            guard let job = jobs.first(where: { $0.kind == kind && $0.id == path[2] }) else { return failure(400, "job '\(path[2])' does not exist.") }
            return startTask(kind.taskType, job.workerID, duration: 4)
        case (.get, ["config", "remote"]):
            return digested(.array(remotes.map(remoteJSON)))
        case (.post, ["config", "remote"]):
            return createRemote(parameters)
        case (let method, let path) where path.count >= 3 && path[0] == "config" && path[1] == "remote":
            return handleRemote(method, name: path[2], rest: Array(path.dropFirst(3)), parameters: parameters)
        case (.get, let path) where path.count == 2 && path[0] == "config":
            guard let kind = DemoBackupServerJob.Kind(rawValue: path[1]) else { return nil }
            return digested(.array(listedJobs(kind, parameters).map { jobJSON($0, withState: false) }))
        case (.post, let path) where path.count == 2 && path[0] == "config":
            guard let kind = DemoBackupServerJob.Kind(rawValue: path[1]) else { return nil }
            return createJob(kind, parameters)
        case (let method, let path) where path.count == 3 && path[0] == "config":
            guard let kind = DemoBackupServerJob.Kind(rawValue: path[1]) else { return nil }
            return handleJob(method, kind: kind, id: path[2], parameters: parameters)
        default:
            return nil
        }
    }

    // MARK: - Jobs

    private func listedJobs(_ kind: DemoBackupServerJob.Kind, _ parameters: [String: String]) -> [DemoBackupServerJob] {
        jobs.filter { job in
            guard job.kind == kind else { return false }
            if let store = parameters["store"], job.store != store { return false }
            if kind == .sync {
                // Without the parameter the real server lists pull jobs only.
                let direction = job.settings["sync-direction"] ?? "pull"
                switch parameters["sync-direction"] ?? "pull" {
                case "all": break
                case let wanted where wanted != direction: return false
                default: break
                }
            }
            return true
        }
    }

    private static let flagSettings: Set<String> = [
        "remove-vanished", "resync-corrupt", "encrypted-only", "verified-only", "run-on-mount", "unmount-on-done", "ignore-verified", "disable",
        "use-node-proxy",
    ]
    private static let numberSettings: Set<String> = [
        "max-depth", "transfer-last", "worker-threads", "outdated-after", "read-threads", "verify-threads", "port",
        "keep-last", "keep-hourly", "keep-daily", "keep-weekly", "keep-monthly", "keep-yearly",
    ]

    private static func value(_ key: String, _ text: String) -> JSONValue {
        if flagSettings.contains(key) { return .bool(text == "1" || text == "true") }
        if numberSettings.contains(key), let number = Int(text) { return .int(number) }
        return .string(text)
    }

    private func jobJSON(_ job: DemoBackupServerJob, withState: Bool) -> JSONValue {
        var data: [String: JSONValue] = ["id": .string(job.id)]
        for (key, text) in job.settings { data[key] = Self.value(key, text) }
        for (key, items) in job.lists { data[key] = .array(items.map { .string($0) }) }
        guard withState else { return .object(data) }
        let now = Date()
        if let last = tasks.first(where: { $0.type == job.kind.taskType && $0.workerID == job.workerID }) {
            data["last-run-upid"] = .string(last.upid)
            if last.isFinished(at: now) {
                data["last-run-state"] = .string(last.result)
                data["last-run-endtime"] = .int(Int(last.startedAt.timeIntervalSince1970 + last.duration))
            }
        }
        if job.settings["disable"] != "1", let next = Self.nextRun(of: job.settings["schedule"], after: now) {
            data["next-run"] = .int(Int(next.timeIntervalSince1970))
        }
        return .object(data)
    }

    /// The next run of a schedule, roughly: the next full hour for hourly ones, otherwise the time of day it names,
    /// ignoring weekdays.
    static func nextRun(of schedule: String?, after date: Date) -> Date? {
        guard let schedule, !schedule.isEmpty else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        if schedule == "hourly" || schedule.contains("*:") {
            return calendar.nextDate(after: date, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)
        }
        var time = DateComponents(hour: 0, minute: 0)
        if let match = schedule.firstMatch(of: /(\d{1,2}):(\d{2})/) {
            time = DateComponents(hour: Int(match.1), minute: Int(match.2))
        }
        return calendar.nextDate(after: date, matching: time, matchingPolicy: .nextTime)
    }

    private static func listParameter(_ text: String?) -> [String] {
        (text ?? "").components(separatedBy: DemoState.listSeparator).filter { !$0.isEmpty }
    }

    /// The real server's checks of a job's settings that the app's forms rely on.
    private func problems(_ kind: DemoBackupServerJob.Kind, _ settings: [String: String], lists: [String: [String]]) -> [String: String] {
        var problems: [String: String] = [:]
        for key in ["store", "remote-store"] where kind == .sync || key == "store" {
            guard let store = settings[key] else {
                problems[key] = "parameter is missing and it is not optional."
                continue
            }
            // The other side of a sync with a remote is not on this server.
            if key == "store" || settings["remote"] == nil, datastoreIndex(store) == nil {
                problems[key] = "datastore '\(store)' does not exist"
            }
        }
        if let remote = settings["remote"], !remotes.contains(where: { $0.name == remote }) {
            problems["remote"] = "remote '\(remote)' does not exist"
        }
        if settings["sync-direction"] == "push", settings["remote"] == nil {
            problems["remote"] = "push jobs need a remote"
        }
        if kind == .prune, settings["schedule"] == nil {
            problems["schedule"] = "parameter is missing and it is not optional."
        }
        if let schedule = settings["schedule"], schedule.contains("every") {
            problems["schedule"] = "unable to parse calendar event at 'every'"
        }
        for filter in lists["group-filter"] ?? [] where filter.wholeMatch(of: /(exclude:)?(type:(vm|ct|host)|group:(vm|ct|host)\/[^\/]+|regex:.+)/) == nil {
            problems["group-filter"] = "invalid group filter '\(filter)'"
        }
        if let threads = settings["worker-threads"].flatMap(Int.init), !(1...32).contains(threads) {
            problems["worker-threads"] = "value must have a minimum value of 1 and a maximum of 32"
        }
        return problems
    }

    private func createJob(_ kind: DemoBackupServerJob.Kind, _ parameters: [String: String]) -> HTTPResponse {
        let id = parameters["id"] ?? ""
        guard id.count >= 3, id.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\-]*/) != nil else {
            return fieldFailure(["id": "value does not match the regex pattern"])
        }
        guard !jobs.contains(where: { $0.kind == kind && $0.id == id }) else { return failure(400, "job '\(id)' already exists.") }
        var job = DemoBackupServerJob(kind: kind, id: id, settings: [:])
        for (key, value) in parameters where !["id", "group-filter", "associated-key"].contains(key) {
            job.settings[key] = value
        }
        for key in ["group-filter", "associated-key"] where parameters[key] != nil {
            job.lists[key] = Self.listParameter(parameters[key])
        }
        let problems = problems(kind, job.settings, lists: job.lists)
        guard problems.isEmpty else { return fieldFailure(problems) }
        jobs.append(job)
        configRevision += 1
        return success(nil)
    }

    private static let deletableJobSettings: [DemoBackupServerJob.Kind: Set<String>] = [
        .sync: ["remote", "remote-ns", "ns", "owner", "comment", "schedule", "remove-vanished", "max-depth", "group-filter", "transfer-last",
                "rate-in", "rate-out", "burst-in", "burst-out", "worker-threads", "resync-corrupt", "encrypted-only", "verified-only",
                "run-on-mount", "unmount-on-done", "active-encryption-key", "associated-key"],
        .verify: ["ns", "max-depth", "schedule", "comment", "ignore-verified", "outdated-after", "read-threads", "verify-threads"],
        .prune: ["ns", "max-depth", "comment", "disable", "keep-last", "keep-hourly", "keep-daily", "keep-weekly", "keep-monthly", "keep-yearly"],
    ]

    private func handleJob(_ method: HTTPMethod, kind: DemoBackupServerJob.Kind, id: String, parameters: [String: String]) -> HTTPResponse? {
        guard let index = jobs.firstIndex(where: { $0.kind == kind && $0.id == id }) else {
            return failure(400, "job '\(id)' does not exist.")
        }
        if method != .get, let digest = parameters["digest"], digest != configDigest {
            return failure(400, "detected modified configuration - file changed by other user? Try again.")
        }
        switch method {
        case .get:
            return digested(jobJSON(jobs[index], withState: false))
        case .delete:
            jobs.remove(at: index)
            configRevision += 1
            return success(nil)
        case .put:
            var job = jobs[index]
            for key in Self.listParameter(parameters["delete"]) {
                guard Self.deletableJobSettings[kind]?.contains(key) == true else {
                    return fieldFailure(["delete": "value '\(key)' is not defined in the enumeration."])
                }
                job.settings[key] = nil
                job.lists[key] = nil
            }
            for (key, value) in parameters where !["delete", "digest", "id", "group-filter", "associated-key"].contains(key) {
                job.settings[key] = value
            }
            for key in ["group-filter", "associated-key"] where parameters[key] != nil {
                job.lists[key] = Self.listParameter(parameters[key])
            }
            let problems = problems(kind, job.settings, lists: job.lists)
            guard problems.isEmpty else { return fieldFailure(problems) }
            jobs[index] = job
            configRevision += 1
            return success(nil)
        default:
            return nil
        }
    }

    /// The prune job the real server makes when a datastore is created with retention settings.
    func addDefaultPruneJob(store: String, _ parameters: [String: String]) {
        let keep = parameters.filter { $0.key.hasPrefix("keep-") }
        guard let schedule = parameters["prune-schedule"], !keep.isEmpty else { return }
        let suffix = UUID().uuidString.lowercased().prefix(13)
        var settings = keep
        settings["store"] = store
        settings["schedule"] = schedule
        jobs.append(DemoBackupServerJob(kind: .prune, id: "default-\(store)-\(suffix)", settings: settings))
    }

    // MARK: - Remotes

    private func remoteJSON(_ remote: DemoBackupServerRemote) -> JSONValue {
        var data: [String: JSONValue] = ["name": .string(remote.name)]
        for (key, text) in remote.settings { data[key] = Self.value(key, text) }
        return .object(data)
    }

    private func remoteProblems(_ settings: [String: String]) -> [String: String] {
        var problems: [String: String] = [:]
        if (settings["host"] ?? "").isEmpty { problems["host"] = "parameter is missing and it is not optional." }
        if let authID = settings["auth-id"], authID.wholeMatch(of: /[^\s:\/@!]+@[^\s:\/@!]+(![^\s:\/@!]+)?/) == nil {
            problems["auth-id"] = "value does not match the regex pattern"
        }
        if let fingerprint = settings["fingerprint"], fingerprint.wholeMatch(of: /([0-9a-fA-F]{2}:){31}[0-9a-fA-F]{2}/) == nil {
            problems["fingerprint"] = "value does not match the regex pattern"
        }
        return problems
    }

    private func createRemote(_ parameters: [String: String]) -> HTTPResponse {
        let name = parameters["name"] ?? ""
        guard name.count >= 3, name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\-]*/) != nil else {
            return fieldFailure(["name": "value does not match the regex pattern"])
        }
        guard !remotes.contains(where: { $0.name == name }) else { return failure(400, "remote '\(name)' already exists.") }
        guard let password = parameters["password"], !password.isEmpty else { return fieldFailure(["password": "parameter is missing and it is not optional."]) }
        var settings = parameters
        for key in ["name", "password"] { settings[key] = nil }
        if settings["auth-id"] == nil { return fieldFailure(["auth-id": "parameter is missing and it is not optional."]) }
        let problems = remoteProblems(settings)
        guard problems.isEmpty else { return fieldFailure(problems) }
        remotes.append(DemoBackupServerRemote(name: name, settings: settings, password: password))
        configRevision += 1
        return success(nil)
    }

    private func handleRemote(_ method: HTTPMethod, name: String, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        guard let index = remotes.firstIndex(where: { $0.name == name }) else { return failure(400, "remote '\(name)' does not exist.") }
        if method != .get, let digest = parameters["digest"], digest != configDigest {
            return failure(400, "detected modified configuration - file changed by other user? Try again.")
        }
        switch (method, rest) {
        case (.get, []):
            return digested(remoteJSON(remotes[index]))
        case (.delete, []):
            if let job = jobs.first(where: { $0.settings["remote"] == name }) {
                return failure(400, "remote '\(name)' is used by sync job '\(job.id)' (datastore '\(job.store)')")
            }
            remotes.remove(at: index)
            configRevision += 1
            return success(nil)
        case (.put, []):
            var remote = remotes[index]
            for key in Self.listParameter(parameters["delete"]) {
                guard ["comment", "fingerprint", "port", "use-node-proxy"].contains(key) else {
                    return fieldFailure(["delete": "value '\(key)' is not defined in the enumeration."])
                }
                remote.settings[key] = nil
            }
            for (key, value) in parameters where !["delete", "digest", "name"].contains(key) {
                if key == "password" { remote.password = value } else { remote.settings[key] = value }
            }
            let problems = remoteProblems(remote.settings)
            guard problems.isEmpty else { return fieldFailure(problems) }
            remotes[index] = remote
            configRevision += 1
            return success(nil)
        case (.get, ["scan"]):
            return scan(remotes[index]) ?? success(.array(remoteDatastores(remotes[index]).map { ["store": .string($0.store), "comment": .string($0.comment)] }))
        case (.get, let path) where path.count == 3 && path[0] == "scan" && path[2] == "namespaces":
            if let failure = scan(remotes[index]) { return failure }
            return success(.array(remoteNamespaces(remotes[index], store: path[1]).map { ["ns": .string($0)] }))
        case (.get, let path) where path.count == 3 && path[0] == "scan" && path[2] == "groups":
            if let failure = scan(remotes[index]) { return failure }
            return success(.array(remoteGroups(remotes[index], store: path[1], namespace: parameters["namespace"] ?? "")))
        default:
            return nil
        }
    }

    /// The error signing in to the remote gives, or nil when it works: the demo's remotes fail with the
    /// password `wrong` or a host containing `unreachable`.
    private func scan(_ remote: DemoBackupServerRemote) -> HTTPResponse? {
        if remote.password == "wrong" {
            return failure(400, "error trying to connect: authentication failed - invalid credentials")
        }
        if remote.settings["host"]?.contains("unreachable") == true {
            return failure(400, "error trying to connect: tcp connect error: No route to host (os error 113)")
        }
        return nil
    }

    /// The cloud remote holds a copy of the home lab; other remotes look like this server.
    private func remoteDatastores(_ remote: DemoBackupServerRemote) -> [(store: String, comment: String)] {
        guard remote.name != "cloud" else { return [("homelab-copy", "Copy of the home lab"), ("customers", "")] }
        return server.datastores.map { ($0.name, datastoreSettings[$0.name]?["comment"] ?? "") }
    }

    private func remoteNamespaces(_ remote: DemoBackupServerRemote, store: String) -> [String] {
        guard remote.name != "cloud" else { return store == "homelab-copy" ? ["", "homelab"] : [""] }
        return server.datastores.first { $0.name == store }?.namespaces ?? [""]
    }

    private func remoteGroups(_ remote: DemoBackupServerRemote, store: String, namespace: String) -> [JSONValue] {
        let source = remote.name == "cloud" ? (store == "homelab-copy" && namespace == "homelab" ? server.datastores.first : nil)
            : server.datastores.first { $0.name == store }
        let groupNamespace = remote.name == "cloud" ? "homelab" : namespace
        return (source?.groups ?? []).filter { $0.namespace == groupNamespace }.map { group in
            [
                "backup-type": .string(group.type), "backup-id": .string(group.id), "owner": .string(group.owner), "comment": .string(group.notes),
                "backup-count": .int(group.snapshots.count),
                "last-backup": .int(Int(started.timeIntervalSince1970 - (group.snapshots.map(\.daysAgo).min() ?? 0) * 86_400)),
            ]
        }
    }
}
