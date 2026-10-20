import Foundation
import ProxmoxCore

/// `GET /version`
public struct PVEVersion: Decodable, Sendable, Equatable {
    public var version: String
    public var release: String?
    public var repositoryID: String?

    public init(version: String, release: String? = nil, repositoryID: String? = nil) {
        self.version = version
        self.release = release
        self.repositoryID = repositoryID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        version = container.lossyString(AnyCodingKey("version")) ?? "unknown"
        release = container.lossyString(AnyCodingKey("release"))
        repositoryID = container.lossyString(AnyCodingKey("repoid"))
    }
}

/// One entry of `GET /cluster/status`: either the cluster itself or one of its nodes.
public struct ClusterStatusEntry: Decodable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case cluster
        case node
        case other(String)
    }

    public var kind: Kind
    public var id: String
    public var name: String
    // Cluster entries
    public var quorate: Bool?
    public var nodeCount: Int?
    public var configVersion: Int?
    // Node entries
    public var ip: String?
    public var online: Bool?
    public var isLocal: Bool?
    public var nodeID: Int?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        switch container.lossyString(AnyCodingKey("type")) {
        case "cluster": kind = .cluster
        case "node": kind = .node
        case let other: kind = .other(other ?? "")
        }
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        id = container.lossyString(AnyCodingKey("id")) ?? name
        quorate = container.lossyBool(AnyCodingKey("quorate"))
        nodeCount = container.lossyInt(AnyCodingKey("nodes"))
        configVersion = container.lossyInt(AnyCodingKey("version"))
        ip = container.lossyString(AnyCodingKey("ip"))
        online = container.lossyBool(AnyCodingKey("online"))
        isLocal = container.lossyBool(AnyCodingKey("local"))
        nodeID = container.lossyInt(AnyCodingKey("nodeid"))
    }
}

public enum ResourceType: Sendable, Equatable, Hashable {
    case node
    case qemu
    case lxc
    case storage
    case pool
    case sdn
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "node": self = .node
        case "qemu": self = .qemu
        case "lxc": self = .lxc
        case "storage": self = .storage
        case "pool": self = .pool
        case "sdn": self = .sdn
        default: self = .other(rawValue)
        }
    }
}

/// One entry of `GET /cluster/resources`, the endpoint the web UI polls for its resource tree.
public struct ClusterResource: Decodable, Sendable, Equatable {
    public var id: String
    public var type: ResourceType
    public var node: String?
    public var status: String?
    public var name: String?
    public var vmid: Int?
    public var cpu: Double?
    public var maxCPU: Int?
    public var memory: Int64?
    public var maxMemory: Int64?
    public var disk: Int64?
    public var maxDisk: Int64?
    public var uptime: Int?
    public var isTemplate: Bool?
    public var tags: String?
    public var pool: String?
    public var lock: String?
    public var haState: String?
    public var storage: String?
    public var pluginType: String?
    public var isShared: Bool?
    public var content: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let id = container.lossyString(AnyCodingKey("id")) else {
            throw ProxmoxError.invalidResponse("resource without id")
        }
        self.id = id
        type = ResourceType(rawValue: container.lossyString(AnyCodingKey("type")) ?? "")
        node = container.lossyString(AnyCodingKey("node"))
        status = container.lossyString(AnyCodingKey("status"))
        name = container.lossyString(AnyCodingKey("name"))
        vmid = container.lossyInt(AnyCodingKey("vmid"))
        cpu = container.lossyDouble(AnyCodingKey("cpu"))
        maxCPU = container.lossyInt(AnyCodingKey("maxcpu"))
        memory = container.lossyDouble(AnyCodingKey("mem")).map { Int64($0) }
        maxMemory = container.lossyDouble(AnyCodingKey("maxmem")).map { Int64($0) }
        disk = container.lossyDouble(AnyCodingKey("disk")).map { Int64($0) }
        maxDisk = container.lossyDouble(AnyCodingKey("maxdisk")).map { Int64($0) }
        uptime = container.lossyInt(AnyCodingKey("uptime"))
        isTemplate = container.lossyBool(AnyCodingKey("template"))
        tags = container.lossyString(AnyCodingKey("tags"))
        pool = container.lossyString(AnyCodingKey("pool"))
        lock = container.lossyString(AnyCodingKey("lock"))
        haState = container.lossyString(AnyCodingKey("hastate"))
        storage = container.lossyString(AnyCodingKey("storage"))
        pluginType = container.lossyString(AnyCodingKey("plugintype"))
        isShared = container.lossyBool(AnyCodingKey("shared"))
        content = container.lossyString(AnyCodingKey("content"))
    }
}

/// Proxmox VE endpoints.
public enum PVE {
    public static func version() -> APIRequest<PVEVersion> {
        APIRequest(.get, "/version")
    }

    public static func clusterStatus() -> APIRequest<[ClusterStatusEntry]> {
        APIRequest(.get, "/cluster/status")
    }

    public static func clusterResources() -> APIRequest<[ClusterResource]> {
        APIRequest(.get, "/cluster/resources")
    }
}
