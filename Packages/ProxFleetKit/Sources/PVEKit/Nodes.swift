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
    /// The node's processor architecture, `x86_64` or `aarch64`.
    public var architecture: String?
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
        architecture = nested("current-kernel")?.lossyString(AnyCodingKey("machine"))
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

    /// The Debian changelog of a package, by default of the version an update would install.
    public static func packageChangelog(node: String, package: String, version: String? = nil) -> APIRequest<String> {
        var parameters: APIParameters = ["name": .string(package)]
        if let version { parameters["version"] = .string(version) }
        return APIRequest(.get, "/nodes/\(node)/apt/changelog", parameters: parameters)
    }

    /// The node's system report, as the web interface's System Report button shows it: versions, network, storage,
    /// guests and more, for support requests. Takes a few seconds.
    public static func systemReport(node: String) -> APIRequest<String> {
        APIRequest(.get, "/nodes/\(node)/report")
    }

    /// The cluster log, newest first.
    public static func clusterLog(max: Int = 200) -> APIRequest<[ClusterLogEntry]> {
        APIRequest(.get, "/cluster/log", parameters: ["max": .int(max)])
    }

    /// Recent tasks of one node, newest first.
    public static func nodeTasks(node: String, limit: Int = 100) -> APIRequest<[ClusterTask]> {
        APIRequest(.get, "/nodes/\(node)/tasks", parameters: ["limit": .int(limit), "source": "all"])
    }
}

/// The web interface's node Bulk Actions: start, shut down or hibernate several guests of a node in one task.
public enum NodeBulkAction: String, Sendable, CaseIterable, Identifiable {
    case start
    case shutdown
    /// Suspends VMs to disk; containers cannot be hibernated.
    case hibernate

    public var id: String { rawValue }

    var endpoint: String {
        switch self {
        case .start: "startall"
        case .shutdown: "stopall"
        case .hibernate: "suspendall"
        }
    }

    var clusterEndpoint: String {
        switch self {
        case .start: "start"
        case .shutdown: "shutdown"
        case .hibernate: "suspend"
        }
    }

    /// Guests the action applies to: stopped ones to start, running ones to shut down, running VMs to hibernate.
    /// Without a node, those of every online node.
    public func eligibleGuests(on node: String?, in snapshot: ClusterSnapshot) -> [GuestSummary] {
        let online = Set(snapshot.nodes.filter(\.isOnline).map(\.name))
        return snapshot.guests
            .filter { guest in (node.map { guest.node == $0 } ?? online.contains(guest.node)) && !guest.isTemplate }
            .filter { guest in
                switch self {
                case .start: guest.state == .stopped
                case .shutdown: guest.state == .running || guest.state == .paused
                case .hibernate: guest.state == .running && guest.kind == .virtualMachine
                }
            }
            .sorted { $0.vmid < $1.vmid }
    }
}

/// Settings of a bulk action, like the web interface's Bulk Action dialog.
public struct NodeBulkActionDraft: Sendable, Equatable {
    public let action: NodeBulkAction
    public var vmids: Set<Int>
    /// Guests handled at the same time, nil for the datacenter's `max_workers` setting.
    public var maxWorkers: Int?
    /// Shutdown only: seconds to wait for each guest, nil for the default of 180.
    public var timeout: Int?
    /// Shutdown only: stop guests that did not shut down within the timeout.
    public var forceStop = true

    public init(action: NodeBulkAction, vmids: Set<Int>) {
        self.action = action
        self.vmids = vmids
    }

    public var parameters: APIParameters {
        var parameters: APIParameters = ["vms": .string(vmids.sorted().map(String.init).joined(separator: ","))]
        if let maxWorkers { parameters["max-workers"] = .int(maxWorkers) }
        switch action {
        case .start:
            // The guests were chosen by hand, so they start even without Start at Boot, as in the web interface.
            parameters["force"] = true
        case .shutdown:
            if let timeout { parameters["timeout"] = .int(timeout) }
            if !forceStop { parameters["force-stop"] = false }
        case .hibernate:
            break
        }
        return parameters
    }
}

extension PVE {
    /// Starts one task on the node that runs the action for every chosen guest. Returns its task ID.
    public static func bulkAction(node: String, _ draft: NodeBulkActionDraft) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(node)/\(draft.action.endpoint)", parameters: draft.parameters)
    }

    /// The datacenter's bulk actions (PVE 9): one task that runs the action for the chosen guests on all nodes.
    public static func clusterBulkAction(_ draft: NodeBulkActionDraft) -> APIRequest<String> {
        var parameters = APIParameters()
        for vmid in draft.vmids.sorted() { parameters.append("vms", .int(vmid)) }
        if let maxWorkers = draft.maxWorkers { parameters["max-workers"] = .int(maxWorkers) }
        switch draft.action {
        case .start:
            break
        case .shutdown:
            if let timeout = draft.timeout { parameters["timeout"] = .int(timeout) }
            if !draft.forceStop { parameters["force-stop"] = false }
        case .hibernate:
            parameters["to-disk"] = true
        }
        return APIRequest(.post, "/cluster/bulk-action/guest/\(draft.action.clusterEndpoint)", parameters: parameters)
    }
}

/// An entry of `GET /cluster/log`: a message of a node's daemons, such as tasks starting and ending.
public struct ClusterLogEntry: Decodable, Sendable, Equatable, Identifiable {
    /// `uid:node`, unique across the cluster.
    public var id: String
    public var date: Date
    public var node: String
    public var tag: String
    public var user: String?
    public var message: String
    /// Syslog priority: 0 emergency … 3 error, 4 warning, 6 info, 7 debug.
    public var priority: Int

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        node = container.lossyString(AnyCodingKey("node")) ?? ""
        id = container.lossyString(AnyCodingKey("id")) ?? "\(container.lossyString(AnyCodingKey("uid")) ?? UUID().uuidString):\(node)"
        date = Date(timeIntervalSince1970: TimeInterval(container.lossyInt(AnyCodingKey("time")) ?? 0))
        tag = container.lossyString(AnyCodingKey("tag")) ?? ""
        user = container.lossyString(AnyCodingKey("user"))
        message = container.lossyString(AnyCodingKey("msg")) ?? ""
        priority = container.lossyInt(AnyCodingKey("pri")) ?? 6
    }

    /// The task ID of "starting task …" and "end task … OK" messages.
    public var upid: String? {
        guard let range = message.range(of: "UPID:") else { return nil }
        return String(message[range.lowerBound...].prefix { !$0.isWhitespace })
    }
}
