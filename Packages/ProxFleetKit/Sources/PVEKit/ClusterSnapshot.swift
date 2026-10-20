import Foundation
import ProxmoxCore

/// Everything the app shows about one server at a point in time. A standalone node is treated as a cluster
/// with a single node, so screens never need two code paths.
public struct ClusterSnapshot: Sendable, Equatable {
    public enum Topology: Sendable, Equatable {
        case standalone
        case cluster(name: String, quorate: Bool)
    }

    public var topology: Topology
    public var nodes: [NodeSummary]
    public var guests: [GuestSummary]
    public var storages: [StorageSummary]
    public var fetchedAt: Date

    public init(topology: Topology, nodes: [NodeSummary], guests: [GuestSummary], storages: [StorageSummary], fetchedAt: Date) {
        self.topology = topology
        self.nodes = nodes
        self.guests = guests
        self.storages = storages
        self.fetchedAt = fetchedAt
    }

    public var clusterName: String? {
        if case .cluster(let name, _) = topology { return name }
        return nil
    }

    public var virtualMachines: [GuestSummary] { guests.filter { $0.kind == .virtualMachine } }
    public var containers: [GuestSummary] { guests.filter { $0.kind == .container } }

    public init(status: [ClusterStatusEntry], resources: [ClusterResource], fetchedAt: Date) {
        let clusterEntry = status.first { $0.kind == .cluster }
        topology = clusterEntry.map { .cluster(name: $0.name, quorate: $0.quorate ?? false) } ?? .standalone

        let statusByNode = Dictionary(status.filter { $0.kind == .node }.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        nodes = resources
            .filter { $0.type == .node }
            .compactMap { NodeSummary(resource: $0, status: $0.node.flatMap { statusByNode[$0] }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guests = resources
            .compactMap(GuestSummary.init(resource:))
            .sorted { $0.vmid < $1.vmid }
        storages = resources
            .compactMap(StorageSummary.init(resource:))
            .sorted { ($0.node, $0.name) < ($1.node, $1.name) }
        self.fetchedAt = fetchedAt
    }
}

public enum PowerState: Sendable, Equatable {
    case running
    case stopped
    case paused
    case unknown

    init(_ status: String?) {
        switch status {
        case "running", "online": self = .running
        case "stopped", "offline": self = .stopped
        case "paused", "suspended": self = .paused
        default: self = .unknown
        }
    }
}

public struct NodeSummary: Sendable, Equatable, Identifiable {
    public var name: String
    public var isOnline: Bool
    public var ip: String?
    public var isLocal: Bool
    /// 0...1
    public var cpuUsage: Double
    public var cpuCount: Int
    public var memoryUsed: Int64
    public var memoryTotal: Int64
    public var uptime: TimeInterval

    public var id: String { name }

    public init(name: String, isOnline: Bool, ip: String? = nil, isLocal: Bool = false, cpuUsage: Double = 0, cpuCount: Int = 0, memoryUsed: Int64 = 0, memoryTotal: Int64 = 0, uptime: TimeInterval = 0) {
        self.name = name
        self.isOnline = isOnline
        self.ip = ip
        self.isLocal = isLocal
        self.cpuUsage = cpuUsage
        self.cpuCount = cpuCount
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.uptime = uptime
    }

    init?(resource: ClusterResource, status: ClusterStatusEntry?) {
        guard let name = resource.node else { return nil }
        self.init(
            name: name,
            isOnline: status?.online ?? (resource.status == "online"),
            ip: status?.ip,
            isLocal: status?.isLocal ?? false,
            cpuUsage: resource.cpu ?? 0,
            cpuCount: resource.maxCPU ?? 0,
            memoryUsed: resource.memory ?? 0,
            memoryTotal: resource.maxMemory ?? 0,
            uptime: TimeInterval(resource.uptime ?? 0)
        )
    }
}

public enum GuestKind: String, Sendable, Equatable, Hashable, Codable {
    case virtualMachine = "qemu"
    case container = "lxc"
}

public struct GuestSummary: Sendable, Equatable, Identifiable {
    /// VMIDs are unique within a cluster, so `vmid` alone identifies a guest on one server.
    public var vmid: Int
    public var kind: GuestKind
    public var name: String
    public var node: String
    public var state: PowerState
    public var isTemplate: Bool
    public var tags: [String]
    public var lock: String?
    public var haState: String?
    public var pool: String?
    /// 0...1 of the assigned cores.
    public var cpuUsage: Double
    public var cpuCount: Int
    public var memoryUsed: Int64
    public var memoryTotal: Int64
    public var diskTotal: Int64
    public var uptime: TimeInterval

    public var id: Int { vmid }

    public init(vmid: Int, kind: GuestKind, name: String, node: String, state: PowerState, isTemplate: Bool = false, tags: [String] = [], lock: String? = nil, haState: String? = nil, pool: String? = nil, cpuUsage: Double = 0, cpuCount: Int = 0, memoryUsed: Int64 = 0, memoryTotal: Int64 = 0, diskTotal: Int64 = 0, uptime: TimeInterval = 0) {
        self.vmid = vmid
        self.kind = kind
        self.name = name
        self.node = node
        self.state = state
        self.isTemplate = isTemplate
        self.tags = tags
        self.lock = lock
        self.haState = haState
        self.pool = pool
        self.cpuUsage = cpuUsage
        self.cpuCount = cpuCount
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.diskTotal = diskTotal
        self.uptime = uptime
    }

    init?(resource: ClusterResource) {
        let kind: GuestKind
        switch resource.type {
        case .qemu: kind = .virtualMachine
        case .lxc: kind = .container
        default: return nil
        }
        guard let vmid = resource.vmid, let node = resource.node else { return nil }
        self.init(
            vmid: vmid,
            kind: kind,
            name: resource.name ?? String(vmid),
            node: node,
            state: PowerState(resource.status),
            isTemplate: resource.isTemplate ?? false,
            tags: Self.parseTags(resource.tags),
            lock: resource.lock,
            haState: resource.haState,
            pool: resource.pool,
            cpuUsage: resource.cpu ?? 0,
            cpuCount: resource.maxCPU ?? 0,
            memoryUsed: resource.memory ?? 0,
            memoryTotal: resource.maxMemory ?? 0,
            diskTotal: resource.maxDisk ?? 0,
            uptime: TimeInterval(resource.uptime ?? 0)
        )
    }

    /// Tags are stored as one string separated by `;`, `,` or spaces.
    static func parseTags(_ text: String?) -> [String] {
        guard let text else { return [] }
        return text.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " }).map(String.init)
    }
}

public struct StorageSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var node: String
    public var isAvailable: Bool
    public var pluginType: String?
    public var isShared: Bool
    public var content: [String]
    public var used: Int64
    public var total: Int64

    public init(id: String, name: String, node: String, isAvailable: Bool, pluginType: String? = nil, isShared: Bool = false, content: [String] = [], used: Int64 = 0, total: Int64 = 0) {
        self.id = id
        self.name = name
        self.node = node
        self.isAvailable = isAvailable
        self.pluginType = pluginType
        self.isShared = isShared
        self.content = content
        self.used = used
        self.total = total
    }

    init?(resource: ClusterResource) {
        guard resource.type == .storage, let name = resource.storage, let node = resource.node else { return nil }
        self.init(
            id: resource.id,
            name: name,
            node: node,
            isAvailable: resource.status == "available",
            pluginType: resource.pluginType,
            isShared: resource.isShared ?? false,
            content: resource.content?.split(separator: ",").map(String.init) ?? [],
            used: resource.disk ?? 0,
            total: resource.maxDisk ?? 0
        )
    }
}

extension ProxmoxSession {
    /// Loads cluster status and resources in parallel and combines them.
    public func fetchClusterSnapshot() async throws -> ClusterSnapshot {
        async let status = send(PVE.clusterStatus())
        async let resources = send(PVE.clusterResources())
        return try await ClusterSnapshot(status: status, resources: resources, fetchedAt: Date())
    }
}
