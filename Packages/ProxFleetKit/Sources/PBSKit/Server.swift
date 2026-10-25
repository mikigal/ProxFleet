import Foundation
import ProxmoxCore
import PVEKit

/// Which tasks `GET /nodes/localhost/tasks` returns.
public struct BackupServerTaskFilter: Sendable, Equatable {
    public enum Status: String, Sendable, CaseIterable {
        case ok, warning, error, unknown
    }

    public var limit = 50
    public var start = 0
    public var since: Date?
    /// Only tasks that are still running.
    public var runningOnly = false
    /// Only failed tasks.
    public var errorsOnly = false
    public var statuses: [Status] = []
    /// A task type such as `garbage_collection`.
    public var type: String?
    /// Only tasks of this datastore.
    public var store: String?
    public var user: String?

    public init(limit: Int = 50) {
        self.limit = limit
    }

    var parameters: APIParameters {
        var parameters: APIParameters = ["limit": .int(limit)]
        if start > 0 { parameters["start"] = .int(start) }
        if let since { parameters["since"] = .int(Int(since.timeIntervalSince1970)) }
        if runningOnly { parameters["running"] = true }
        if errorsOnly { parameters["errors"] = true }
        for status in statuses { parameters.append("statusfilter", .string(status.rawValue)) }
        if let type { parameters["typefilter"] = .string(type) }
        if let store { parameters["store"] = .string(store) }
        if let user { parameters["userfilter"] = .string(user) }
        return parameters
    }
}

extension PBS {
    /// CPU, memory, root disk and versions. Same shape as on Proxmox VE, apart from `root` for the root disk.
    public static func nodeStatus() -> APIRequest<NodeStatus> {
        APIRequest(.get, "/nodes/\(node)/status")
    }

    /// Server history; Proxmox Backup Server calls it `rrd`, Proxmox VE `rrddata`.
    public static func nodeRRD(timeframe: RRDTimeframe) -> APIRequest<[RRDPoint]> {
        APIRequest(.get, "/nodes/\(node)/rrd", parameters: ["timeframe": .string(timeframe.rawValue), "cf": "AVERAGE"])
    }

    /// The server's tasks, newest first. Tasks of the API and proxy daemons are mixed; filters narrow them down.
    public static func tasks(_ filter: BackupServerTaskFilter = BackupServerTaskFilter()) -> APIRequest<[ClusterTask]> {
        APIRequest(.get, "/nodes/\(node)/tasks", parameters: filter.parameters)
    }

    public static func taskStatus(upid: String) -> APIRequest<TaskStatus> {
        PVE.taskStatus(node: node, upid: upid)
    }

    public static func taskLog(upid: String, start: Int = 0, limit: Int = 500) -> APIRequest<[TaskLogLine]> {
        PVE.taskLog(node: node, upid: upid, start: start, limit: limit)
    }

    /// The name of the server itself, which tasks carry in their UPIDs.
    public static func nodes() -> APIRequest<[BackupServerNode]> {
        APIRequest(.get, "/nodes")
    }
}

/// An entry of `GET /nodes`, which has one entry: the server.
public struct BackupServerNode: Decodable, Sendable, Equatable {
    public var name: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("node")) ?? ""
    }
}
