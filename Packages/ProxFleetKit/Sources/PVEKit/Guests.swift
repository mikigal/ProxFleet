import Foundation
import ProxmoxCore

/// Identifies a guest and builds the paths of its endpoints.
public struct GuestReference: Sendable, Hashable, Codable {
    public var node: String
    public var vmid: Int
    public var kind: GuestKind

    public init(node: String, vmid: Int, kind: GuestKind) {
        self.node = node
        self.vmid = vmid
        self.kind = kind
    }

    public init(_ guest: GuestSummary) {
        self.init(node: guest.node, vmid: guest.vmid, kind: guest.kind)
    }

    /// `/nodes/{node}/qemu/{vmid}` or `/nodes/{node}/lxc/{vmid}`.
    public var path: String {
        "/nodes/\(node)/\(kind.rawValue)/\(vmid)"
    }

    /// Path used for permission checks.
    public var aclPath: String { "/vms/\(vmid)" }
}

/// `GET .../status/current`
public struct GuestStatus: Decodable, Sendable, Equatable {
    public var status: String
    /// QEMU only: `running`, `paused`, `prelaunch`, `suspended`… The `status` of a paused VM is still `running`.
    public var qmpStatus: String?
    public var name: String?
    public var cpuUsage: Double
    public var cpuCount: Int
    public var memoryUsed: Int64
    public var memoryTotal: Int64
    public var swapUsed: Int64?
    public var swapTotal: Int64?
    public var diskUsed: Int64
    public var diskTotal: Int64
    public var networkIn: Int64
    public var networkOut: Int64
    public var diskRead: Int64
    public var diskWrite: Int64
    public var uptime: TimeInterval
    public var lock: String?
    public var isHAManaged: Bool
    public var agentEnabled: Bool
    public var runningMachine: String?
    public var runningQEMU: String?
    public var tags: [String]

    public var powerState: PowerState {
        if qmpStatus == "paused" || qmpStatus == "suspended" { return .paused }
        return PowerState(status)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func int(_ key: String) -> Int64? { container.lossyDouble(AnyCodingKey(key)).map { Int64($0) } }
        status = container.lossyString(AnyCodingKey("status")) ?? "unknown"
        qmpStatus = container.lossyString(AnyCodingKey("qmpstatus"))
        name = container.lossyString(AnyCodingKey("name"))
        cpuUsage = container.lossyDouble(AnyCodingKey("cpu")) ?? 0
        cpuCount = container.lossyInt(AnyCodingKey("cpus")) ?? 0
        memoryUsed = int("mem") ?? 0
        memoryTotal = int("maxmem") ?? 0
        swapUsed = int("swap")
        swapTotal = int("maxswap")
        diskUsed = int("disk") ?? 0
        diskTotal = int("maxdisk") ?? 0
        networkIn = int("netin") ?? 0
        networkOut = int("netout") ?? 0
        diskRead = int("diskread") ?? 0
        diskWrite = int("diskwrite") ?? 0
        uptime = TimeInterval(container.lossyInt(AnyCodingKey("uptime")) ?? 0)
        lock = container.lossyString(AnyCodingKey("lock"))
        agentEnabled = container.lossyBool(AnyCodingKey("agent")) ?? false
        runningMachine = container.lossyString(AnyCodingKey("running-machine"))
        runningQEMU = container.lossyString(AnyCodingKey("running-qemu"))
        tags = GuestSummary.parseTags(container.lossyString(AnyCodingKey("tags")))
        if let ha = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("ha")) {
            isHAManaged = ha.lossyBool(AnyCodingKey("managed")) ?? false
        } else {
            isHAManaged = false
        }
    }
}

/// `GET .../rrddata`: one sample of the performance history. Fields are nil where the server has no data.
public struct RRDPoint: Decodable, Sendable, Equatable, Identifiable {
    public var time: Date
    public var cpu: Double?
    public var memoryUsed: Double?
    public var memoryTotal: Double?
    public var networkIn: Double?
    public var networkOut: Double?
    public var diskRead: Double?
    public var diskWrite: Double?
    /// Nodes only: load average and the share of time spent waiting for I/O.
    public var loadAverage: Double?
    public var ioWait: Double?
    /// Storages only: used and total bytes.
    public var storageUsed: Double?
    public var storageTotal: Double?

    public var id: Date { time }

    public init(time: Date, cpu: Double? = nil, memoryUsed: Double? = nil, memoryTotal: Double? = nil, networkIn: Double? = nil, networkOut: Double? = nil, diskRead: Double? = nil, diskWrite: Double? = nil) {
        self.time = time
        self.cpu = cpu
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.diskRead = diskRead
        self.diskWrite = diskWrite
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        time = Date(timeIntervalSince1970: container.lossyDouble(AnyCodingKey("time")) ?? 0)
        cpu = container.lossyDouble(AnyCodingKey("cpu"))
        // Guests report `mem`/`maxmem`, nodes `memused`/`memtotal`.
        memoryUsed = container.lossyDouble(AnyCodingKey("mem")) ?? container.lossyDouble(AnyCodingKey("memused"))
        memoryTotal = container.lossyDouble(AnyCodingKey("maxmem")) ?? container.lossyDouble(AnyCodingKey("memtotal"))
        networkIn = container.lossyDouble(AnyCodingKey("netin"))
        networkOut = container.lossyDouble(AnyCodingKey("netout"))
        diskRead = container.lossyDouble(AnyCodingKey("diskread"))
        diskWrite = container.lossyDouble(AnyCodingKey("diskwrite"))
        loadAverage = container.lossyDouble(AnyCodingKey("loadavg"))
        ioWait = container.lossyDouble(AnyCodingKey("iowait"))
        storageUsed = container.lossyDouble(AnyCodingKey("used"))
        storageTotal = container.lossyDouble(AnyCodingKey("total"))
    }

    /// The first samples of a new guest carry only a timestamp.
    public var hasData: Bool { cpu != nil || memoryUsed != nil || networkIn != nil }
}

public enum RRDTimeframe: String, Sendable, CaseIterable, Identifiable {
    case hour, day, week, month, year
    public var id: String { rawValue }
}

/// A network interface reported by the QEMU guest agent or by a container.
public struct GuestNetworkInterface: Sendable, Equatable, Identifiable {
    public var name: String
    public var macAddress: String?
    public var addresses: [String]

    public var id: String { name }

    public init(name: String, macAddress: String? = nil, addresses: [String]) {
        self.name = name
        self.macAddress = macAddress
        self.addresses = addresses
    }

    /// Loopback and link-local addresses are left out, as they are of no use to the user.
    var isUseful: Bool {
        name != "lo" && !addresses.isEmpty
    }
}

struct RawInterface: Decodable, Sendable {
    var name: String
    var hardwareAddress: String?
    var addresses: [String]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? "?"
        hardwareAddress = container.lossyString(AnyCodingKey("hardware-address")) ?? container.lossyString(AnyCodingKey("hwaddr"))
        var addresses: [String] = []
        if var list = try? container.nestedUnkeyedContainer(forKey: AnyCodingKey("ip-addresses")) {
            while !list.isAtEnd {
                guard let entry = try? list.nestedContainer(keyedBy: AnyCodingKey.self) else {
                    _ = try? list.decode(Nothing.self)
                    continue
                }
                if let address = entry.lossyString(AnyCodingKey("ip-address")), !address.hasPrefix("fe80"), address != "127.0.0.1", address != "::1" {
                    if let prefix = entry.lossyString(AnyCodingKey("prefix")) {
                        addresses.append("\(address)/\(prefix)")
                    } else {
                        addresses.append(address)
                    }
                }
            }
        }
        self.addresses = addresses
    }
}

struct AgentResult<T: Decodable & Sendable>: Decodable, Sendable {
    var result: T
}

extension PVE {
    public static func guestStatus(_ guest: GuestReference) -> APIRequest<GuestStatus> {
        APIRequest(.get, guest.path + "/status/current")
    }

    /// The configuration in effect. Without `current`, Proxmox returns pending values instead.
    public static func guestConfig(_ guest: GuestReference) -> APIRequest<GuestConfig> {
        APIRequest(.get, guest.path + "/config", parameters: ["current": true])
    }

    public static func guestRRD(_ guest: GuestReference, timeframe: RRDTimeframe) -> APIRequest<[RRDPoint]> {
        APIRequest(.get, guest.path + "/rrddata", parameters: ["timeframe": .string(timeframe.rawValue), "cf": "AVERAGE"])
    }

    /// Starts a power action. Returns the task ID.
    public static func powerAction(_ action: PowerAction, on guest: GuestReference) -> APIRequest<String> {
        var parameters = APIParameters()
        if action == .hibernate { parameters["todisk"] = true }
        return APIRequest(.post, guest.path + "/status/" + action.endpoint, parameters: parameters)
    }

    /// Privileges the current user has on a path, e.g. `/vms/100`.
    public static func permissions(path: String) -> APIRequest<[String: [String: PrivilegeGrant]]> {
        APIRequest(.get, "/access/permissions", parameters: ["path": .string(path)])
    }
}

/// One privilege in `GET /access/permissions`: `1` or `0` on Proxmox VE, `true` or `false` on Proxmox Backup Server.
public struct PrivilegeGrant: Decodable, Sendable, Equatable {
    public var isGranted: Bool

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            isGranted = flag
        } else {
            isGranted = (try? container.decode(Int.self)).map { $0 != 0 } ?? false
        }
    }
}

extension ProxmoxSession {
    /// IP addresses of a guest: from the QEMU guest agent, or from the container runtime.
    /// Returns nil when they are unavailable, for example when the agent is not running.
    public func guestInterfaces(_ guest: GuestReference) async -> [GuestNetworkInterface]? {
        let raw: [RawInterface]?
        switch guest.kind {
        case .virtualMachine:
            raw = try? await send(APIRequest<AgentResult<[RawInterface]>>(.get, guest.path + "/agent/network-get-interfaces")).result
        case .container:
            raw = try? await send(APIRequest<[RawInterface]>(.get, guest.path + "/interfaces"))
        }
        return raw?.map { GuestNetworkInterface(name: $0.name, macAddress: $0.hardwareAddress, addresses: $0.addresses) }.filter(\.isUseful)
    }

    /// Privileges the current user has on a path.
    public func privileges(on path: String) async throws -> Set<String> {
        let result = try await send(PVE.permissions(path: path))
        return Set((result[path] ?? [:]).filter(\.value.isGranted).keys)
    }
}
