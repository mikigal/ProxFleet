import Foundation
import ProxmoxCore

/// Datastores, their settings and permissions on the demo backup server.
extension DemoBackupServerState {
    static func settings(of datastore: DemoBackupServer.Datastore) -> [String: String] {
        var settings = ["name": datastore.name, "path": datastore.path, "comment": datastore.comment, "notification-mode": "notification-system"]
        if let schedule = datastore.gcSchedule { settings["gc-schedule"] = schedule }
        if let device = datastore.backingDevice { settings["backing-device"] = device }
        if datastore.name == "main" { settings["verify-new"] = "1" }
        return settings
    }

    /// A system disk, the main datastore's ZFS disks, and a USB disk with a file system for removable datastores.
    static let disks: JSONValue = [
        ["name": "nvme0n1", "devpath": "/dev/nvme0n1", "model": "Samsung SSD 980 500GB", "size": 500_107_862_016, "disk-type": "ssd", "used": "partitions",
         "status": "passed", "wearout": 98, "gpt": true, "partitions": [
            ["name": "nvme0n1p2", "devpath": "/dev/nvme0n1p2", "size": 1_073_741_824, "used": "EFI", "filesystem": "vfat", "uuid": "8C1A-77D2", "mounted": false],
            ["name": "nvme0n1p3", "devpath": "/dev/nvme0n1p3", "size": 498_000_000_000, "used": "LVM", "mounted": false],
         ]],
        ["name": "sda", "devpath": "/dev/sda", "model": "WDC WD40EFZX", "size": 4_000_787_030_016, "disk-type": "hdd", "used": "ZFS", "status": "passed", "gpt": true, "partitions": []],
        ["name": "sdb", "devpath": "/dev/sdb", "model": "WDC WD40EFZX", "size": 4_000_787_030_016, "disk-type": "hdd", "used": "ZFS", "status": "passed", "gpt": true, "partitions": []],
        ["name": "sdc", "devpath": "/dev/sdc", "model": "Samsung T7", "vendor": "Samsung", "size": 2_000_398_934_016, "disk-type": "usb", "used": "partitions",
         "status": "unknown", "gpt": true, "partitions": [
            ["name": "sdc1", "devpath": "/dev/sdc1", "size": 2_000_397_885_440, "used": "filesystem", "filesystem": "ext4",
             "uuid": "c3d7e1f0-5a2b-4c9e-8f61-2b7d40a9e113", "mounted": false],
         ]],
    ]

    var configDigest: String {
        String(format: "%064x", configRevision)
    }

    func datastoreIndex(_ name: String) -> Int? {
        server.datastores.firstIndex { $0.name == name }
    }

    func startTask(_ type: String, _ workerID: String, duration: TimeInterval, result: String = "OK") -> HTTPResponse {
        let task = DemoBackupTask(number: (tasks.map(\.number).max() ?? 0) + 1, type: type, workerID: workerID, user: "demo@pbs",
                                  startedAt: Date(), duration: duration, result: result)
        tasks.insert(task, at: 0)
        return success(.string(task.upid))
    }

    /// Routes below `/config/datastore` and `/admin/datastore/{store}`. nil for other paths.
    func handleDatastores(_ method: HTTPMethod, parts: [String], parameters: [String: String]) -> HTTPResponse? {
        switch (method, parts) {
        case (.get, ["config", "datastore"]):
            let list = server.datastores.compactMap { datastoreSettings[$0.name] }.map(Self.settingsJSON)
            return digested(.array(list))
        case (.post, ["config", "datastore"]):
            return createDatastore(parameters)
        case (.get, let path) where path.count == 3 && path[0] == "config" && path[1] == "datastore":
            let name = path[2]
            guard let settings = datastoreSettings[name] else { return failure(400, "unable to find datastore '\(name)'") }
            return digested(Self.settingsJSON(settings))
        case (.put, let path) where path.count == 3 && path[0] == "config" && path[1] == "datastore":
            return updateDatastore(path[2], parameters)
        case (.delete, let path) where path.count == 3 && path[0] == "config" && path[1] == "datastore":
            let name = path[2]
            guard let index = datastoreIndex(name) else { return failure(400, "unable to find datastore '\(name)'") }
            server.datastores.remove(at: index)
            datastoreSettings[name] = nil
            acl.removeAll { $0.path == "/datastore/\(name)" || $0.path.hasPrefix("/datastore/\(name)/") }
            configRevision += 1
            return startTask("delete-datastore", name, duration: 1.5)
        case (let method, let path) where path.count >= 4 && path[0] == "admin" && path[1] == "datastore":
            guard let index = datastoreIndex(path[2]) else { return failure(400, "no such datastore '\(path[2])'") }
            return handleDatastore(method, index: index, rest: Array(path.dropFirst(3)), parameters: parameters)
        case (.get, ["config", "s3"]):
            return digested([["id": "minio", "endpoint": "minio.home.arpa", "port": 9000, "region": "us-east-1", "access-key": "pbs", "path-style": true]])
        case (.get, let path) where path.count == 4 && path[0] == "config" && path[1] == "s3" && path[3] == "list-buckets":
            return success([["name": "pbs-offsite"], ["name": "photos"]])
        default:
            return nil
        }
    }

    private func handleDatastore(_ method: HTTPMethod, index: Int, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        let datastore = server.datastores[index]
        let name = datastore.name
        let mounted = datastore.backingDevice == nil || datastore.isMounted
        switch (method, rest) {
        case (.post, ["mount"]):
            server.datastores[index].isMounted = true
            return startTask("mount-device", name, duration: 2)
        case (.post, ["unmount"]):
            server.datastores[index].isMounted = false
            return startTask("unmount-device", name, duration: 2)
        default:
            break
        }
        guard mounted else { return failure(400, "datastore '\(name)' is not mounted") }
        if let mode = datastoreSettings[name]?["maintenance-mode"], mode.contains("offline") {
            return failure(400, "datastore is being maintained: offline")
        }
        switch (method, rest) {
        case (.get, ["status"]):
            return success(statusJSON(datastore))
        case (.get, ["gc"]):
            return success(garbageCollectionJSON(datastore))
        case (.post, ["gc"]):
            return startTask("garbage_collection", name, duration: 4)
        case (.get, ["active-operations"]):
            return success(["read": 0, "write": 0])
        case (.get, ["rrd"]):
            return success(historyJSON(datastore, timeframe: parameters["timeframe"] ?? "day"))
        case (.get, ["namespace"]):
            let parent = parameters["parent"] ?? ""
            let maxDepth = parameters["max-depth"].flatMap(Int.init)
            let namespaces = datastore.namespaces.filter { namespace in
                let isBelow = parent.isEmpty || namespace == parent || namespace.hasPrefix(parent + "/")
                let depth = namespace.split(separator: "/").count - parent.split(separator: "/").count
                return isBelow && (maxDepth.map { depth <= $0 } ?? true)
            }
            return success(.array(namespaces.map { ["ns": .string($0)] }))
        default:
            return handleContent(method, index: index, rest: rest, parameters: parameters)
        }
    }

    private func createDatastore(_ parameters: [String: String]) -> HTTPResponse {
        let name = parameters["name"] ?? ""
        guard name.count >= 3, name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\-]*/) != nil else {
            return fieldFailure(["name": "value does not match the regex pattern"])
        }
        guard datastoreIndex(name) == nil else { return failure(400, "datastore '\(name)' already exists.") }
        let path = parameters["path"] ?? ""
        if parameters["backing-device"] == nil, !path.hasPrefix("/") {
            return failure(400, "expected an absolute path, got \(path)")
        }
        var settings = ["name": name, "path": path]
        for key in ["comment", "gc-schedule", "backing-device", "backend", "notification-mode", "verify-new"] {
            if let value = parameters[key] { settings[key] = value }
        }
        server.datastores.append(DemoBackupServer.Datastore(
            name: name, path: path, comment: parameters["comment"] ?? "", totalGiB: parameters["backing-device"] == nil ? 3_726 : 1_863, usedGiB: 0.1,
            backingDevice: parameters["backing-device"], gcSchedule: parameters["gc-schedule"], namespaces: [""], groups: []
        ))
        datastoreSettings[name] = settings
        configRevision += 1
        return startTask("create-datastore", name, duration: 2)
    }

    private static let deletableSettings: Set<String> = [
        "comment", "gc-schedule", "gc-on-unmount", "prune-schedule", "keep-last", "keep-hourly", "keep-daily", "keep-weekly", "keep-monthly",
        "keep-yearly", "verify-new", "notify-user", "notify", "notification-mode", "tuning", "maintenance-mode",
    ]

    private func updateDatastore(_ name: String, _ parameters: [String: String]) -> HTTPResponse {
        guard var settings = datastoreSettings[name] else { return failure(400, "unable to find datastore '\(name)'") }
        if let digest = parameters["digest"], digest != configDigest {
            return failure(400, "detected modified configuration - file changed by other user? Try again.")
        }
        for key in (parameters["delete"] ?? "").components(separatedBy: DemoState.listSeparator) where !key.isEmpty {
            guard Self.deletableSettings.contains(key) else { return fieldFailure(["delete": "value '\(key)' is not defined in the enumeration."]) }
            settings[key] = nil
        }
        if let schedule = parameters["gc-schedule"], schedule.contains("every") {
            return fieldFailure(["gc-schedule": "unable to parse calendar event at 'every'"])
        }
        if let mode = parameters["maintenance-mode"], !["read-only", "offline"].contains(where: { mode.contains($0) }) {
            return fieldFailure(["maintenance-mode": "value does not match the regex pattern"])
        }
        for (key, value) in parameters where !["delete", "digest", "name"].contains(key) {
            settings[key] = value
        }
        datastoreSettings[name] = settings
        configRevision += 1
        return success(nil)
    }

    private func statusJSON(_ datastore: DemoBackupServer.Datastore) -> JSONValue {
        let gib = 1_073_741_824.0
        var counts: [String: JSONValue] = ["other": nil]
        for type in ["vm", "ct", "host"] {
            let groups = datastore.groups.filter { $0.type == type }
            counts[type] = ["groups": .int(groups.count), "snapshots": .int(groups.reduce(0) { $0 + $1.snapshots.count })]
        }
        return [
            "total": .double(datastore.totalGiB * gib), "used": .double(datastore.usedGiB * gib),
            "avail": .double((datastore.totalGiB - datastore.usedGiB) * gib), "backend-type": "filesystem",
            "counts": .object(counts), "gc-status": garbageCollectionJSON(datastore),
        ]
    }

    private func garbageCollectionJSON(_ datastore: DemoBackupServer.Datastore) -> JSONValue {
        let gib = 1_073_741_824.0
        let referenced = datastore.groups.flatMap(\.snapshots).reduce(0) { $0 + $1.sizeGiB } * gib
        var status: [String: JSONValue] = [
            "store": .string(datastore.name), "index-file-count": .int(datastore.groups.flatMap(\.snapshots).count * 3),
            "index-data-bytes": .double(referenced), "disk-bytes": .double(datastore.usedGiB * gib), "disk-chunks": .int(Int(datastore.usedGiB * 256)),
            "removed-bytes": .double(3.2 * gib), "removed-chunks": 812, "pending-bytes": .double(0.4 * gib), "pending-chunks": 103,
            "removed-bad": 0, "still-bad": 0,
        ]
        if let schedule = datastoreSettings[datastore.name]?["gc-schedule"] {
            status["schedule"] = .string(schedule)
            let midnight = Calendar(identifier: .gregorian).startOfDay(for: Date())
            status["next-run"] = .int(Int(midnight.timeIntervalSince1970) + 86_400)
        }
        if let last = tasks.first(where: { $0.type == "garbage_collection" && $0.workerID == datastore.name && $0.isFinished(at: Date()) }) {
            status["upid"] = .string(last.upid)
            status["last-run-state"] = .string(last.result)
            status["last-run-endtime"] = .int(Int(last.startedAt.timeIntervalSince1970 + last.duration))
            status["duration"] = .int(Int(last.duration))
        } else {
            status["upid"] = nil
        }
        return .object(status)
    }

    private func historyJSON(_ datastore: DemoBackupServer.Datastore, timeframe: String) -> JSONValue {
        let step: TimeInterval = ["hour": 60, "week": 10_800, "month": 43_200, "year": 604_800][timeframe] ?? 1800
        let end = (Date().timeIntervalSince1970 / step).rounded(.down) * step
        let gib = 1_073_741_824.0
        let total = datastore.totalGiB * gib
        return .array((0..<70).map { index in
            let time = end - Double(69 - index) * step
            let wave = sin(time / (step * 7)) * 0.5 + 0.5
            // Nightly backups write a lot for a short while; the rest of the day is quiet.
            let busy = wave > 0.8 ? 1.0 : 0.05
            let used = datastore.usedGiB * gib - Double(69 - index) * step / 86_400 * 4 * gib
            return [
                "time": .int(Int(time)), "total": .double(total), "used": .double(used), "available": .double(total - used),
                "read_bytes": .double(2_000_000 * busy * wave), "write_bytes": .double(60_000_000 * busy * wave),
                "read_ios": .double(20 * busy), "write_ios": .double(300 * busy), "io_ticks": .double(0.4 * busy),
            ]
        })
    }

    // MARK: - Access

    private static let roles: [(id: String, privileges: [String], comment: String)] = [
        ("Admin", ["Sys.Audit", "Sys.Modify", "Datastore.Allocate", "Datastore.Modify", "Permissions.Modify"], "Administrator"),
        ("Audit", ["Sys.Audit", "Datastore.Audit"], "Auditor"),
        ("NoAccess", [], "Disable access"),
        ("DatastoreAdmin", ["Datastore.Audit", "Datastore.Modify", "Datastore.Read", "Datastore.Verify", "Datastore.Backup", "Datastore.Prune"], "Datastore Administrator"),
        ("DatastoreAudit", ["Datastore.Audit"], "Datastore Auditor"),
        ("DatastoreBackup", ["Datastore.Backup"], "Datastore Backup (backup and restore owned backups)"),
        ("DatastorePowerUser", ["Datastore.Prune", "Datastore.Backup"], "Datastore PowerUser (backup, restore and prune owned backup)"),
        ("DatastoreReader", ["Datastore.Audit", "Datastore.Read", "Datastore.Verify"], "Datastore Reader (inspect datastore content and do restores)"),
        ("RemoteAudit", ["Remote.Audit"], "Remote Auditor"),
        ("RemoteSyncOperator", ["Remote.Audit", "Remote.Read"], "Synchronization Operator"),
    ]

    func handleAccess(_ method: HTTPMethod, parts: [String], parameters: [String: String]) -> HTTPResponse? {
        switch (method, parts) {
        case (.get, ["access", "acl"]):
            let path = parameters["path"]
            let entries = acl.filter { entry in
                guard let path else { return true }
                return parameters["exact"] == "1" ? entry.path == path : entry.path == path || entry.path.hasPrefix(path + "/")
            }
            return digested(.array(entries.map { entry in
                ["path": .string(entry.path), "ugid": .string(entry.authID), "roleid": .string(entry.role),
                 "propagate": .bool(entry.propagates), "ugid_type": "user"]
            }))
        case (.put, ["access", "acl"]):
            guard let path = parameters["path"], let role = parameters["role"], let authID = parameters["auth-id"] else {
                return fieldFailure(["auth-id": "parameter is missing"])
            }
            acl.removeAll { $0.path == path && $0.authID == authID && $0.role == role }
            if parameters["delete"] != "1" {
                acl.append((path, authID, role, parameters["propagate"] != "0"))
            }
            return success(nil)
        case (.get, ["access", "roles"]):
            return success(.array(Self.roles.map { ["roleid": .string($0.id), "privs": .array($0.privileges.map { .string($0) }), "comment": .string($0.comment)] }))
        case (.get, ["access", "users"]):
            return digested([
                ["userid": "root@pam", "email": "admin@home.arpa", "enable": true],
                ["userid": "backup@pbs", "comment": "Proxmox VE cluster homelab", "enable": true,
                 "tokens": [["tokenid": "backup@pbs!pve", "comment": "Storage pbs", "enable": true]]],
                ["userid": "anna@pbs", "firstname": "Anna", "comment": "Laptop backups", "enable": true],
                ["userid": "monitoring@pbs", "enable": true, "tokens": [["tokenid": "monitoring@pbs!zabbix", "enable": true]]],
            ])
        default:
            return nil
        }
    }

    // MARK: - Helpers

    /// Settings as the API sends them: numbers for the `keep-*` rules, booleans for switches, text otherwise.
    static func settingsJSON(_ settings: [String: String]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: settings.map { key, value in
            if key.hasPrefix("keep-"), let number = Int(value) { return (key, JSONValue.int(number)) }
            if ["verify-new", "gc-on-unmount"].contains(key) { return (key, JSONValue.bool(value == "1" || value == "true")) }
            return (key, JSONValue.string(value))
        }))
    }

    func digested(_ data: JSONValue) -> HTTPResponse {
        let body: JSONValue = ["data": data, "digest": .string(configDigest), "success": true]
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body.encoded())
    }
}
