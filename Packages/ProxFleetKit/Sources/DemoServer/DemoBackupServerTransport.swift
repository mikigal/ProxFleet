import Foundation
import ProxmoxCore

/// Answers API requests like a Proxmox Backup Server, from an in-memory `DemoBackupServer`.
///
/// Sign-in follows the real server's rules (the realm belongs in the user ID, `realm` and `new-format` are refused),
/// so the demo catches requests a real server would reject. Any password but `wrong` is accepted; user names
/// containing `tfa` need the TOTP code `123456`.
public final class DemoBackupServerTransport: HTTPTransport {
    private let state: DemoBackupServerState

    public init(server: DemoBackupServer = .homelab) {
        state = DemoBackupServerState(server: server)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await Task.sleep(for: .milliseconds(150))
        return await state.handle(request)
    }
}

struct DemoBackupTask: Sendable {
    var number: Int
    var type: String
    /// The worker ID as the API reports it, e.g. `main:vm/100`.
    var workerID: String
    var user: String
    var startedAt: Date
    var duration: TimeInterval
    /// `OK`, `WARNINGS: n` or an error message.
    var result: String

    var upid: String {
        let start = String(format: "%08X", Int(startedAt.timeIntervalSince1970))
        return "UPID:pbs:00000F2A:000012AB:\(String(format: "%08X", number)):\(start):\(type):\(Self.escape(workerID)):\(user):"
    }

    func isFinished(at date: Date) -> Bool { date.timeIntervalSince(startedAt) >= duration }

    /// systemd's unit name escaping, as the real server uses for task IDs.
    static func escape(_ text: String) -> String {
        var escaped = ""
        for character in text.unicodeScalars {
            switch character {
            case "/": escaped += "-"
            case "-", ":", "\\": escaped += String(format: "\\x%02x", character.value)
            default: escaped.unicodeScalars.append(character)
            }
        }
        return escaped
    }
}

actor DemoBackupServerState {
    var server: DemoBackupServer
    var tasks: [DemoBackupTask]
    let started = Date()
    private var ticketCounter = 0

    init(server: DemoBackupServer) {
        self.server = server
        tasks = Self.taskHistory(for: server, now: started)
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let prefix = APIFormat.pathPrefix
        let fullPath = request.url.path(percentEncoded: false)
        guard fullPath.hasPrefix(prefix) else { return failure(404, "Not found") }
        let path = String(fullPath.dropFirst(prefix.count))
        let parameters = Self.parameters(of: request)

        switch (request.method, path) {
        case (.post, "/access/ticket"):
            return ticket(parameters)
        case (.get, "/access/domains"):
            return success([
                ["realm": "pam", "type": "pam", "comment": "Linux PAM standard authentication", "default": true],
                ["realm": "pbs", "type": "pbs", "comment": "Proxmox Backup authentication server"],
            ])
        case (.get, "/ping"):
            return success(["pong": true])
        default:
            break
        }
        guard request.headers["Cookie"]?.contains("PBSAuthCookie=") == true else {
            return HTTPResponse(statusCode: 401, body: Data("authentication failed".utf8))
        }

        let parts = path.split(separator: "/").map(String.init)
        switch (request.method, parts) {
        case (.get, ["version"]):
            return success(["version": .string(server.version), "release": .string(server.release), "repoid": "demo"])
        case (.get, ["nodes"]):
            return success([["node": .string(server.name)]])
        case (.get, ["access", "permissions"]):
            return success(permissions(path: parameters["path"] ?? "/"))
        case (.get, ["status", "datastore-usage"]):
            return success(.array(server.datastores.map(usageJSON)))
        case (.get, ["admin", "datastore"]):
            return success(.array(server.datastores.map { datastore in
                [
                    "store": .string(datastore.name), "comment": .string(datastore.comment), "backend-type": "filesystem",
                    "mount-status": .string(datastore.backingDevice == nil ? "nonremovable" : datastore.isMounted ? "mounted" : "notmounted"),
                ]
            }))
        case (_, let parts) where parts.count >= 2 && parts[0] == "nodes":
            return handleNode(request.method, rest: Array(parts.dropFirst(2)), parameters: parameters)
                ?? failure(400, "Method '\(request.method.rawValue) \(path)' is not available in demo mode")
        default:
            return failure(400, "Method '\(request.method.rawValue) \(path)' is not available in demo mode")
        }
    }

    // MARK: - Authentication

    private func ticket(_ parameters: [String: String]) -> HTTPResponse {
        // The real server's schema allows nothing else.
        let extra = Set(parameters.keys).subtracting(["username", "password", "tfa-challenge", "path", "privs", "port"])
        if !extra.isEmpty {
            return fieldFailure(Dictionary(uniqueKeysWithValues: extra.map { ($0, "schema does not allow additional properties.") }))
        }
        let userid = parameters["username"] ?? ""
        guard userid.contains("@") else { return fieldFailure(["username": "value does not match the regex pattern"]) }
        let password = parameters["password"] ?? ""

        if let challenge = parameters["tfa-challenge"] {
            guard challenge.hasPrefix("PBS:!tfa!") else { return failure(401, "authentication failure") }
            let accepted = password == "totp:\(DemoTransport.totpCode)" || (password.hasPrefix("recovery:") && password.count > 9)
            return accepted ? fullTicket(for: userid) : failure(401, "authentication failure")
        }
        if password.hasPrefix("PBS:") {
            return fullTicket(for: userid)
        }
        if password == "wrong" || password.isEmpty {
            return failure(401, "authentication failure")
        }
        if userid.contains("tfa") {
            let challenge = #"{"totp":true,"recovery":"available"}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return success(["username": .string(userid), "ticket": .string("PBS:!tfa!\(challenge):DEMO::sig")])
        }
        return fullTicket(for: userid)
    }

    private func fullTicket(for userid: String) -> HTTPResponse {
        ticketCounter += 1
        return success([
            "username": .string(userid),
            "ticket": .string("PBS:\(userid):DEMO\(ticketCounter)::demo-signature"),
            "CSRFPreventionToken": .string("DEMO\(ticketCounter):csrf"),
        ])
    }

    private static let privileges = [
        "Datastore.Allocate", "Datastore.Audit", "Datastore.Backup", "Datastore.Modify", "Datastore.Prune", "Datastore.Read",
        "Datastore.Verify", "Permissions.Modify", "Realm.Allocate", "Remote.Audit", "Remote.DatastoreBackup", "Remote.DatastoreModify",
        "Remote.DatastorePrune", "Remote.Modify", "Remote.Read", "Sys.Audit", "Sys.Console", "Sys.Modify", "Sys.PowerManagement",
    ]

    /// The demo user is an administrator, like `root@pam`.
    private func permissions(path: String) -> JSONValue {
        .object([path: .object(Dictionary(uniqueKeysWithValues: Self.privileges.map { ($0, JSONValue.bool(true)) }))])
    }

    // MARK: - Server

    private func handleNode(_ method: HTTPMethod, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        switch (method, rest) {
        case (.get, ["status"]):
            return success(nodeStatus())
        case (.get, ["rrd"]):
            return success(nodeHistory(timeframe: parameters["timeframe"] ?? "hour"))
        case (.get, ["subscription"]):
            return success([
                "status": "active", "productname": "Proxmox Backup Server Community Subscription 1 CPU", "serverid": "DEMO",
                "nextduedate": "2027-03-01", "checktime": .int(Int(started.timeIntervalSince1970)),
            ])
        case (.get, ["tasks"]):
            return taskList(parameters)
        case (.get, let path) where path.count == 3 && path[0] == "tasks" && path[2] == "status":
            guard let task = tasks.first(where: { $0.upid == path[1] }) else { return failure(400, "no such task") }
            return success(taskStatusJSON(task))
        case (.get, let path) where path.count == 3 && path[0] == "tasks" && path[2] == "log":
            guard let task = tasks.first(where: { $0.upid == path[1] }) else { return failure(400, "no such task") }
            return success(taskLog(task))
        default:
            return nil
        }
    }

    private func nodeStatus() -> JSONValue {
        let gib = 1_073_741_824.0
        let elapsed = Date().timeIntervalSince(started)
        let cpu = DemoState.load(seed: 6, elapsed: elapsed, base: 0.05, swing: 0.04)
        return [
            "cpu": .double(cpu), "wait": .double(0.004),
            "memory": ["total": .double(16 * gib), "used": .double(5.2 * gib), "free": .double(10.8 * gib)],
            "swap": ["total": .double(8 * gib), "used": 0, "free": .double(8 * gib)],
            "root": ["total": .double(32 * gib), "used": .double(5.6 * gib), "avail": .double(26.4 * gib)],
            "loadavg": [.double(0.31 + cpu), 0.27, 0.22],
            "uptime": .int(1_209_600 + Int(elapsed)),
            "kversion": "Linux 7.0.0-3-pve #1 SMP PREEMPT_DYNAMIC PMX 7.0.0-3",
            "current-kernel": ["release": "7.0.0-3-pve", "machine": "x86_64", "sysname": "Linux", "version": "#1 SMP PREEMPT_DYNAMIC PMX 7.0.0-3"],
            "cpuinfo": ["cpus": 8, "model": "Intel(R) N305", "sockets": 1],
            "boot-info": ["mode": "efi", "secureboot": false],
            "info": ["fingerprint": "3a:9f:00:12:7c:44:de:51:08:b2:61:e0:aa:4d:93:5c:2e:71:fd:c8:0b:36:94:57:e2:1f:68:ad:09:c3:b7:40"],
        ]
    }

    private func nodeHistory(timeframe: String) -> JSONValue {
        let step: TimeInterval = ["day": 1800, "week": 10_800, "month": 43_200, "year": 604_800][timeframe] ?? 60
        let end = (Date().timeIntervalSince1970 / step).rounded(.down) * step
        let gib = 1_073_741_824.0
        return .array((0..<70).map { index in
            let time = end - Double(69 - index) * step
            let wave = sin(time / (step * 11) + 6) * 0.5 + 0.5
            return [
                "time": .int(Int(time)), "cpu": .double(0.03 + 0.15 * wave), "iowait": .double(0.002 + 0.02 * wave),
                "memtotal": .double(16 * gib), "memused": .double(gib * (4.5 + 1.5 * wave)),
                "netin": .double(15_000 + 4_000_000 * wave), "netout": .double(6_000 + 90_000 * (1 - wave)),
                "loadavg": .double(0.2 + 1.4 * wave), "total": .double(32 * gib), "used": .double(5.6 * gib),
            ]
        })
    }

    // MARK: - Datastores

    private func usageJSON(_ datastore: DemoBackupServer.Datastore) -> JSONValue {
        let gib = 1_073_741_824.0
        var entry: [String: JSONValue] = [
            "store": .string(datastore.name), "backend-type": "filesystem",
            "mount-status": .string(datastore.backingDevice == nil ? "nonremovable" : datastore.isMounted ? "mounted" : "notmounted"),
        ]
        guard datastore.backingDevice == nil || datastore.isMounted else {
            entry["error"] = "datastore is not mounted"
            return .object(entry)
        }
        let total = datastore.totalGiB * gib
        let used = datastore.usedGiB * gib
        entry["total"] = .double(total)
        entry["used"] = .double(used)
        entry["avail"] = .double(total - used)
        // A month of history every six hours, growing slowly, so the server can estimate when the store is full.
        let step: TimeInterval = 21_600
        let count = 120
        let start = (started.timeIntervalSince1970 / step).rounded(.down) * step - Double(count - 1) * step
        entry["history-start"] = .int(Int(start))
        entry["history-delta"] = .int(Int(step))
        entry["history"] = .array((0..<count).map { index in
            .double((used - Double(count - 1 - index) * 0.9 * gib) / total)
        })
        let growthPerSecond = 0.9 * gib / step
        entry["estimated-full-date"] = .int(Int(started.timeIntervalSince1970 + (total - used) / growthPerSecond))
        return .object(entry)
    }

    // MARK: - Tasks

    /// A month of nightly backups, garbage collections, prunes, verifications and syncs, plus a verification
    /// running when the demo starts.
    static func taskHistory(for server: DemoBackupServer, now: Date) -> [DemoBackupTask] {
        var tasks: [DemoBackupTask] = []
        let calendar = Calendar(identifier: .gregorian)
        let midnight = calendar.startOfDay(for: now)
        func add(_ type: String, _ id: String, day: Int, minutes: Double, duration: TimeInterval, user: String = "root@pam", result: String = "OK") {
            let start = midnight.addingTimeInterval(Double(-day) * 86_400 + minutes * 60)
            guard start < now else { return }
            tasks.append(DemoBackupTask(number: 0, type: type, workerID: id, user: user, startedAt: start, duration: duration, result: result))
        }
        for day in 0..<30 {
            add("garbage_collection", "main", day: day, minutes: 1, duration: 312)
            for (index, group) in (server.datastores.first?.groups ?? []).enumerated() where group.namespace == "homelab" {
                let failed = day == 12 && group.id == "104"
                add("backup", "main:\(group.type)/\(group.id)", day: day, minutes: 120 + Double(index) * 6, duration: group.type == "vm" ? 240 : 45,
                    user: "backup@pbs", result: failed ? "backup failed: connection error: Connection reset by peer" : "OK")
            }
            add("prunejob", "main", day: day, minutes: 180, duration: 8)
            if day % 7 == 2 {
                add("verificationjob", "main:weekly-verify", day: day, minutes: 240, duration: 1_840, result: day == 16 ? "verification failed - please check the log for details" : "OK")
                add("syncjob", "-:main:offsite::offsite-copy", day: day, minutes: 300, duration: 2_400, result: day == 9 ? "WARNINGS: 1" : "OK")
            }
        }
        tasks.append(DemoBackupTask(number: 0, type: "verificationjob", workerID: "main:weekly-verify", user: "root@pam",
                                    startedAt: now.addingTimeInterval(-30), duration: 150, result: "OK"))
        tasks.sort { $0.startedAt > $1.startedAt }
        for index in tasks.indices { tasks[index].number = tasks.count - index }
        return tasks
    }

    private func taskJSON(_ task: DemoBackupTask) -> JSONValue {
        var data: [String: JSONValue] = [
            "upid": .string(task.upid), "node": "localhost", "pid": 3882, "pstart": 4779,
            "starttime": .int(Int(task.startedAt.timeIntervalSince1970)), "user": .string(task.user),
            "worker_type": .string(task.type), "worker_id": .string(task.workerID),
        ]
        if task.isFinished(at: Date()) {
            data["endtime"] = .int(Int(task.startedAt.timeIntervalSince1970 + task.duration))
            data["status"] = .string(task.result)
        }
        return .object(data)
    }

    private func taskList(_ parameters: [String: String]) -> HTTPResponse {
        let now = Date()
        let statuses = parameters["statusfilter"]?.components(separatedBy: DemoState.listSeparator) ?? []
        let filtered = tasks.filter { task in
            if let since = parameters["since"].flatMap(Double.init), task.startedAt.timeIntervalSince1970 < since { return false }
            if parameters["running"] == "1", task.isFinished(at: now) { return false }
            if parameters["errors"] == "1", !task.isFinished(at: now) || task.result == "OK" || task.result.hasPrefix("WARNINGS") { return false }
            if let type = parameters["typefilter"], !task.type.hasPrefix(type) { return false }
            if let store = parameters["store"], task.workerID != store, !task.workerID.hasPrefix(store + ":") { return false }
            if let user = parameters["userfilter"], !task.user.contains(user) { return false }
            if !statuses.isEmpty {
                guard task.isFinished(at: now) else { return false }
                let status = task.result == "OK" ? "ok" : task.result.hasPrefix("WARNINGS") ? "warning" : "error"
                if !statuses.contains(status) { return false }
            }
            return true
        }
        let start = parameters["start"].flatMap(Int.init) ?? 0
        let limit = parameters["limit"].flatMap(Int.init) ?? 50
        let page = filtered.dropFirst(start).prefix(limit == 0 ? filtered.count : limit)
        let body: JSONValue = ["data": .array(page.map(taskJSON)), "total": .int(filtered.count), "success": true]
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body.encoded())
    }

    private func taskStatusJSON(_ task: DemoBackupTask) -> JSONValue {
        let finished = task.isFinished(at: Date())
        var data: [String: JSONValue] = [
            "upid": .string(task.upid), "node": .string(server.name), "pid": 3882, "pstart": 4779, "type": .string(task.type),
            "id": .string(task.workerID), "user": .string(task.user), "starttime": .int(Int(task.startedAt.timeIntervalSince1970)),
            "status": finished ? "stopped" : "running",
        ]
        if finished { data["exitstatus"] = .string(task.result) }
        return .object(data)
    }

    private func taskLog(_ task: DemoBackupTask) -> JSONValue {
        var lines = ["starting \(task.type.replacingOccurrences(of: "_", with: " ")) on \(task.workerID)"]
        if task.isFinished(at: Date()) {
            switch task.result {
            case "OK": lines.append("TASK OK")
            case let result where result.hasPrefix("WARNINGS"): lines += ["some groups could not be synced", "TASK \(result)"]
            case let result: lines.append("TASK ERROR: \(result)")
            }
        }
        return .array(lines.enumerated().map { ["n": .int($0.offset + 1), "t": .string($0.element)] })
    }

    // MARK: - Helpers

    func success(_ data: JSONValue) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: JSONValue.object(["data": data, "success": true]).encoded())
    }

    /// The extjs format of Proxmox Backup Server: the status in the body and the HTTP status line.
    func failure(_ status: Int, _ message: String) -> HTTPResponse {
        let body: JSONValue = ["data": nil, "success": false, "status": .int(status), "message": .string(message), "errors": [:]]
        return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: body.encoded())
    }

    func fieldFailure(_ errors: [String: String]) -> HTTPResponse {
        let body: JSONValue = [
            "data": nil, "success": false, "status": 400, "message": "parameter verification errors",
            "errors": .object(errors.mapValues { .string($0) }),
        ]
        return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"], body: body.encoded())
    }

    static func parameters(of request: HTTPRequest) -> [String: String] {
        let encoded = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? request.url.query(percentEncoded: true) ?? ""
        var result: [String: String] = [:]
        for pair in encoded.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            let value = parts.count > 1 ? parts[1] : ""
            result[parts[0]] = result[parts[0]].map { $0 + DemoState.listSeparator + value } ?? value
        }
        return result
    }
}
