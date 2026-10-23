import Foundation
import ProxmoxCore

public enum PowerAction: String, Sendable, CaseIterable, Identifiable {
    case start
    case shutdown
    case reboot
    case stop
    case reset
    /// Pauses the VM in memory (`qm suspend`).
    case pause
    case resume
    /// Saves memory to disk and stops the VM (`qm suspend --todisk`).
    case hibernate

    public var id: String { rawValue }

    var endpoint: String {
        switch self {
        case .pause, .hibernate: "suspend"
        default: rawValue
        }
    }

    /// Actions offered for a guest in a given state, in the order the UI shows them.
    public static func available(for kind: GuestKind, state: PowerState, isTemplate: Bool) -> [PowerAction] {
        guard !isTemplate else { return [] }
        switch (state, kind) {
        case (.stopped, _): return [.start]
        case (.running, .virtualMachine): return [.shutdown, .reboot, .pause, .hibernate, .stop, .reset]
        case (.running, .container): return [.shutdown, .reboot, .stop]
        case (.paused, _): return [.resume, .stop]
        case (.unknown, _): return []
        }
    }

    /// Actions that interrupt a running guest ask for confirmation first, as in the web interface.
    public var needsConfirmation: Bool {
        switch self {
        case .start, .resume, .pause: false
        default: true
        }
    }

    /// Stop and reset cut power without warning the guest operating system.
    public var isForceful: Bool {
        self == .stop || self == .reset
    }
}

/// `GET /nodes/{node}/tasks/{upid}/status`
public struct TaskStatus: Decodable, Sendable, Equatable {
    public var upid: String
    public var node: String
    public var type: String
    public var objectID: String?
    public var user: String
    public var isRunning: Bool
    /// `OK`, `WARNINGS: n`, or the error message once the task stopped.
    public var exitStatus: String?
    public var startTime: Date

    public var succeeded: Bool {
        guard let exitStatus else { return false }
        return exitStatus == "OK" || exitStatus.hasPrefix("WARNINGS")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        upid = container.lossyString(AnyCodingKey("upid")) ?? ""
        node = container.lossyString(AnyCodingKey("node")) ?? ""
        type = container.lossyString(AnyCodingKey("type")) ?? ""
        objectID = container.lossyString(AnyCodingKey("id"))
        user = container.lossyString(AnyCodingKey("user")) ?? ""
        isRunning = container.lossyString(AnyCodingKey("status")) == "running"
        exitStatus = container.lossyString(AnyCodingKey("exitstatus"))
        startTime = Date(timeIntervalSince1970: container.lossyDouble(AnyCodingKey("starttime")) ?? 0)
    }
}

/// One line of `GET /nodes/{node}/tasks/{upid}/log`.
public struct TaskLogLine: Decodable, Sendable, Equatable, Identifiable {
    public var number: Int
    public var text: String

    public var id: Int { number }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        number = container.lossyInt(AnyCodingKey("n")) ?? 0
        text = container.lossyString(AnyCodingKey("t")) ?? ""
    }
}

/// One entry of `GET /cluster/tasks`: recent tasks of all nodes.
public struct ClusterTask: Decodable, Sendable, Equatable, Identifiable {
    public var upid: String
    public var node: String
    public var type: String
    public var objectID: String?
    public var user: String
    public var startTime: Date
    public var endTime: Date?
    /// `OK`, `WARNINGS: n` or an error message. Nil while running.
    public var status: String?

    public var id: String { upid }
    public var isRunning: Bool { endTime == nil }
    public var succeeded: Bool { status == "OK" || status?.hasPrefix("WARNINGS") == true }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        upid = container.lossyString(AnyCodingKey("upid")) ?? ""
        node = container.lossyString(AnyCodingKey("node")) ?? ""
        type = container.lossyString(AnyCodingKey("type")) ?? ""
        objectID = container.lossyString(AnyCodingKey("id")).flatMap { $0.isEmpty ? nil : $0 }
        user = container.lossyString(AnyCodingKey("user")) ?? ""
        startTime = Date(timeIntervalSince1970: container.lossyDouble(AnyCodingKey("starttime")) ?? 0)
        endTime = container.lossyDouble(AnyCodingKey("endtime")).map { Date(timeIntervalSince1970: $0) }
        status = container.lossyString(AnyCodingKey("status"))
    }
}

/// Short names for task types, like the web interface shows them.
public enum TaskDescription {
    public static func title(type: String, objectID: String?) -> String {
        let name = names[type] ?? type
        guard let objectID, !objectID.isEmpty else { return name }
        // Backups (`vzdump`) cover VMs and containers alike, so the web interface writes "VM/CT".
        let prefix = type == "vzdump" ? "VM/CT " : type.hasPrefix("qm") ? "VM " : type.hasPrefix("vz") || type.hasPrefix("pct") ? "CT " : ""
        return "\(prefix)\(objectID) – \(name)"
    }

    static let names: [String: String] = [
        "qmstart": "Start", "qmstop": "Stop", "qmshutdown": "Shutdown", "qmreboot": "Reboot", "qmreset": "Reset",
        "qmpause": "Pause", "qmresume": "Resume", "qmsuspend": "Hibernate", "qmcreate": "Create", "qmclone": "Clone",
        "qmdestroy": "Destroy", "qmigrate": "Migrate", "qmconfig": "Configure", "qmtemplate": "Convert to Template",
        "qmrestore": "Restore", "qmsnapshot": "Snapshot", "qmrollback": "Rollback", "qmdelsnapshot": "Delete Snapshot",
        "qmmove": "Move Disk", "qmresize": "Resize Disk",
        "vzstart": "Start", "vzstop": "Stop", "vzshutdown": "Shutdown", "vzreboot": "Reboot", "vzcreate": "Create",
        "vzdestroy": "Destroy", "vzmigrate": "Migrate", "vzsuspend": "Suspend", "vzresume": "Resume",
        "vztemplate": "Convert to Template", "vzclone": "Clone", "vzrestore": "Restore", "vzsnapshot": "Snapshot", "vzrollback": "Rollback",
        "vzdelsnapshot": "Delete Snapshot", "vzdump": "Backup", "vncproxy": "Console", "vncshell": "Shell",
        "termproxy": "Console", "spiceproxy": "SPICE Console", "aptupdate": "Update Package Database",
        "imgcopy": "Copy Image", "imgdel": "Delete Volume", "download": "Download", "startall": "Bulk Start", "stopall": "Bulk Shutdown", "suspendall": "Bulk Hibernate",
        "migrateall": "Bulk Migrate", "bulk-start": "Bulk Start", "bulk-shutdown": "Bulk Shutdown", "bulk-suspend": "Bulk Suspend", "bulk-migrate": "Bulk Migrate", "reloadnetworkall": "Apply SDN",
        "srvreload": "Reload Service", "srvrestart": "Restart Service", "srvstart": "Start Service", "srvstop": "Stop Service",
        "diskinit": "Initialize Disk with GPT", "wipedisk": "Wipe Disk", "zfscreate": "Create ZFS Pool", "zfsremove": "Remove ZFS Pool",
        "lvmcreate": "Create LVM Volume Group", "lvmremove": "Remove LVM Volume Group", "lvmthincreate": "Create LVM Thin Pool",
        "lvmthinremove": "Remove LVM Thin Pool", "dircreate": "Create Directory", "dirremove": "Remove Directory",
    ]
}

extension PVE {
    public static func taskStatus(node: String, upid: String) -> APIRequest<TaskStatus> {
        APIRequest(.get, "/nodes/\(node)/tasks/\(escapePath(upid))/status")
    }

    public static func taskLog(node: String, upid: String, start: Int = 0, limit: Int = 500) -> APIRequest<[TaskLogLine]> {
        APIRequest(.get, "/nodes/\(node)/tasks/\(escapePath(upid))/log", parameters: ["start": .int(start), "limit": .int(limit)])
    }

    /// Stops a running task. Needs `Sys.Modify` on `/nodes/{node}` unless the user started the task.
    public static func stopTask(node: String, upid: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/nodes/\(node)/tasks/\(escapePath(upid))")
    }

    public static func clusterTasks() -> APIRequest<[ClusterTask]> {
        APIRequest(.get, "/cluster/tasks")
    }

    static func escapePath(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? segment
    }
}
