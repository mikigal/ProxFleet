import Foundation
import ProxmoxCore

/// `GET /nodes/{node}/status`: hardware, usage and versions of a node.
public struct NodeStatus: Decodable, Sendable, Equatable {
    public var cpuUsage: Double
    /// Share of CPU time spent waiting for I/O.
    public var ioWait: Double
    public var cpuModel: String?
    public var sockets: Int
    public var cores: Int
    /// Logical CPUs (threads).
    public var cpuCount: Int
    public var loadAverage: [Double]
    public var memoryUsed: Int64
    public var memoryTotal: Int64
    public var swapUsed: Int64
    public var swapTotal: Int64
    public var rootUsed: Int64
    public var rootTotal: Int64
    public var uptime: TimeInterval
    /// For example `9.2.21`, from `pve-manager/9.2.21/4f6e0ac8`.
    public var pveVersion: String?
    /// For example `7.0.14-25-pve`.
    public var kernel: String?
    /// `efi` or `legacy`.
    public var bootMode: String?
    public var secureBoot: Bool

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func nested(_ key: String) -> KeyedDecodingContainer<AnyCodingKey>? {
            try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(key))
        }
        func bytes(_ object: String, _ key: String) -> Int64 {
            nested(object)?.lossyDouble(AnyCodingKey(key)).map { Int64($0) } ?? 0
        }
        cpuUsage = container.lossyDouble(AnyCodingKey("cpu")) ?? 0
        ioWait = container.lossyDouble(AnyCodingKey("wait")) ?? 0
        let cpu = nested("cpuinfo")
        cpuModel = cpu?.lossyString(AnyCodingKey("model"))
        sockets = cpu?.lossyInt(AnyCodingKey("sockets")) ?? 1
        cores = cpu?.lossyInt(AnyCodingKey("cores")) ?? 0
        cpuCount = cpu?.lossyInt(AnyCodingKey("cpus")) ?? 0
        var loads: [Double] = []
        if var list = try? container.nestedUnkeyedContainer(forKey: AnyCodingKey("loadavg")) {
            while !list.isAtEnd {
                if let text = try? list.decode(String.self), let value = Double(text) {
                    loads.append(value)
                } else if let value = try? list.decode(Double.self) {
                    loads.append(value)
                } else {
                    _ = try? list.decode(Nothing.self)
                }
            }
        }
        loadAverage = loads
        memoryUsed = bytes("memory", "used")
        memoryTotal = bytes("memory", "total")
        swapUsed = bytes("swap", "used")
        swapTotal = bytes("swap", "total")
        rootUsed = bytes("rootfs", "used")
        rootTotal = bytes("rootfs", "total")
        uptime = TimeInterval(container.lossyInt(AnyCodingKey("uptime")) ?? 0)
        let manager = container.lossyString(AnyCodingKey("pveversion"))?.split(separator: "/")
        pveVersion = manager.flatMap { $0.count > 1 ? String($0[1]) : nil }
        kernel = nested("current-kernel")?.lossyString(AnyCodingKey("release")) ?? container.lossyString(AnyCodingKey("kversion"))
        let boot = nested("boot-info")
        bootMode = boot?.lossyString(AnyCodingKey("mode"))
        secureBoot = boot?.lossyBool(AnyCodingKey("secureboot")) ?? false
    }
}

/// One entry of `GET /nodes/{node}/services`.
public struct NodeService: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    /// `running`, `dead`…
    public var state: String
    /// `enabled`, `disabled`, `masked`, `not-found`…
    public var unitState: String

    public var id: String { name }
    public var isRunning: Bool { state == "running" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("service")) ?? container.lossyString(AnyCodingKey("name")) ?? ""
        description = container.lossyString(AnyCodingKey("desc")) ?? ""
        state = container.lossyString(AnyCodingKey("state")) ?? "unknown"
        unitState = container.lossyString(AnyCodingKey("unit-state")) ?? ""
    }

    /// Stopping these cuts off the web interface and this app, as all API calls go through them.
    public var isNeededForAccess: Bool { ["pveproxy", "pvedaemon", "pve-cluster"].contains(name) }
}

public enum ServiceAction: String, Sendable, CaseIterable, Identifiable {
    case start, stop, restart, reload

    public var id: String { rawValue }

    /// Actions that make sense for a service in its current state.
    public static func available(for service: NodeService) -> [ServiceAction] {
        service.isRunning ? [.restart, .reload, .stop] : [.start]
    }
}

/// A package with an update, from `GET /nodes/{node}/apt/update`, or an installed package from `apt/versions`.
public struct PackageVersion: Decodable, Sendable, Equatable, Identifiable {
    public var package: String
    public var title: String?
    /// Installed version; for `apt/versions` the same as `version` when nothing is pending.
    public var oldVersion: String?
    public var version: String
    public var origin: String?
    public var priority: String?
    /// `apt/versions` only: the kernel the node runs, on the kernel package.
    public var runningKernel: String?

    public var id: String { package }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        package = container.lossyString(AnyCodingKey("Package")) ?? ""
        title = container.lossyString(AnyCodingKey("Title"))
        oldVersion = container.lossyString(AnyCodingKey("OldVersion"))
        version = container.lossyString(AnyCodingKey("Version")) ?? ""
        origin = container.lossyString(AnyCodingKey("Origin"))
        priority = container.lossyString(AnyCodingKey("Priority"))
        runningKernel = container.lossyString(AnyCodingKey("RunningKernel"))
    }
}

public enum NodePowerCommand: String, Sendable {
    case reboot, shutdown
}

public enum NodeJournal {
    /// Log lines from `GET /nodes/{node}/journal`, without the cursor lines it adds at the start and end.
    public static func lines(_ entries: [String]) -> [String] {
        entries.filter { !($0.hasPrefix("s=") && $0.contains(";i=") && !$0.contains(" ")) }
    }
}

extension PVE {
    public static func nodeStatus(_ node: String) -> APIRequest<NodeStatus> {
        APIRequest(.get, "/nodes/\(node)/status")
    }

    public static func nodeRRD(_ node: String, timeframe: RRDTimeframe) -> APIRequest<[RRDPoint]> {
        APIRequest(.get, "/nodes/\(node)/rrddata", parameters: ["timeframe": .string(timeframe.rawValue), "cf": "AVERAGE"])
    }

    /// Reboots or shuts down a node. Answers right away; the node goes offline shortly after.
    public static func nodePower(_ node: String, _ command: NodePowerCommand) -> APIRequest<String?> {
        APIRequest(.post, "/nodes/\(node)/status", parameters: ["command": .string(command.rawValue)])
    }

    public static func services(node: String) -> APIRequest<[NodeService]> {
        APIRequest(.get, "/nodes/\(node)/services")
    }

    /// Starts, stops, restarts or reloads a service. Returns a task ID.
    public static func serviceAction(node: String, service: String, _ action: ServiceAction) -> APIRequest<String?> {
        APIRequest(.post, "/nodes/\(node)/services/\(escapePath(service))/\(action.rawValue)")
    }

    /// Packages with updates, as of the last refresh of the package index.
    public static func packageUpdates(node: String) -> APIRequest<[PackageVersion]> {
        APIRequest(.get, "/nodes/\(node)/apt/update")
    }

    /// Refreshes the package index (`apt update`). Returns a task ID.
    public static func refreshPackageIndex(node: String) -> APIRequest<String?> {
        APIRequest(.post, "/nodes/\(node)/apt/update")
    }

    /// Versions of the Proxmox VE packages installed on the node.
    public static func packageVersions(node: String) -> APIRequest<[PackageVersion]> {
        APIRequest(.get, "/nodes/\(node)/apt/versions")
    }

    /// The latest entries of the system journal, oldest first. Filter them with `NodeJournal.lines`.
    public static func journal(node: String, lastEntries: Int = 500) -> APIRequest<[String]> {
        APIRequest(.get, "/nodes/\(node)/journal", parameters: ["lastentries": .int(lastEntries)])
    }

    /// Recent tasks of one node, newest first.
    public static func nodeTasks(node: String, limit: Int = 100) -> APIRequest<[ClusterTask]> {
        APIRequest(.get, "/nodes/\(node)/tasks", parameters: ["limit": .int(limit), "source": "all"])
    }
}
