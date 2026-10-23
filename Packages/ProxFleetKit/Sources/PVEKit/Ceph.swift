import Foundation
import ProxmoxCore

/// Where a node stands with Ceph, read from the errors Proxmox gives before Ceph is ready.
public enum CephSetupState: Sendable, Equatable {
    /// The packages are missing on this node: install them first.
    case notInstalled
    /// Installed, but the cluster has no Ceph configuration yet: initialize it and create the first monitor.
    case notInitialized
    /// Configured, but no monitor answers yet.
    case noMonitor
    case ready

    /// The state an error of a Ceph request means, nil for other errors.
    public static func from(errorMessage message: String) -> CephSetupState? {
        if message.contains("binary not installed") { return .notInstalled }
        if message.contains("configuration not initialized") { return .notInitialized }
        if message.contains("rados_connect failed") || message.contains("got timeout") { return .noMonitor }
        return nil
    }
}

/// A Ceph release Proxmox can install, `GET /nodes/{node}/ceph/releases`.
public struct CephRelease: Decodable, Sendable, Equatable, Identifiable {
    /// The code name, like `squid`.
    public var name: String
    /// Like `19.2`.
    public var version: String
    public var isAvailable: Bool
    public var isDefault: Bool
    /// A technology preview.
    public var isUnsupported: Bool

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("release")) ?? ""
        version = container.lossyString(AnyCodingKey("version")) ?? ""
        isAvailable = container.lossyBool(AnyCodingKey("available")) ?? false
        isDefault = container.lossyBool(AnyCodingKey("is-default")) ?? false
        isUnsupported = container.lossyBool(AnyCodingKey("unsupported")) ?? false
    }

    /// `cmd-opts` of the node shell's `ceph_install` command, as the web interface sends them.
    public static func installOptions(release: String, repository: String) -> [String] {
        ["--version", release, "--repository", repository]
    }
}

/// The parts of `ceph status` the app shows. The full answer is large; the rest is ignored.
public struct CephStatus: Decodable, Sendable, Equatable {
    public struct HealthCheck: Sendable, Equatable, Identifiable {
        public var code: String
        /// `HEALTH_WARN` or `HEALTH_ERR`.
        public var severity: String
        public var summary: String
        public var details: [String]
        public var isMuted: Bool

        public var id: String { code }

        public init(code: String, severity: String, summary: String, details: [String] = [], isMuted: Bool = false) {
            self.code = code
            self.severity = severity
            self.summary = summary
            self.details = details
            self.isMuted = isMuted
        }
    }

    /// `HEALTH_OK`, `HEALTH_WARN` or `HEALTH_ERR`.
    public var health: String
    public var checks: [HealthCheck]
    public var fsid: String
    public var monitors: [String]
    public var quorum: [String]
    public var osdCount: Int
    public var osdsUp: Int
    public var osdsIn: Int
    public var placementGroups: Int
    /// Placement group states, like `active+clean`, with how many are in them.
    public var placementGroupStates: [(state: String, count: Int)]
    public var pools: Int
    public var objects: Int
    public var bytesUsed: Int64
    public var bytesTotal: Int64
    public var bytesAvailable: Int64
    /// The share of objects that lack copies, 0 when healthy.
    public var degradedRatio: Double
    public var activeManager: String?
    public var standbyManagers: [String]
    public var metadataServersUp: Int
    public var metadataServersStandby: Int

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        fsid = root.lossyString(AnyCodingKey("fsid")) ?? ""
        quorum = (try? root.decodeIfPresent([String].self, forKey: AnyCodingKey("quorum_names"))) ?? []

        let health = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("health"))
        self.health = health?.lossyString(AnyCodingKey("status")) ?? "HEALTH_UNKNOWN"
        var checks: [HealthCheck] = []
        if let health, let list = try? health.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("checks")) {
            for key in list.allKeys {
                guard let check = try? list.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key) else { continue }
                let summary = (try? check.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("summary")))?.lossyString(AnyCodingKey("message")) ?? key.stringValue
                let details = ((try? check.decodeIfPresent([[String: String]].self, forKey: AnyCodingKey("detail"))) ?? []).compactMap { $0["message"] }
                checks.append(HealthCheck(
                    code: key.stringValue, severity: check.lossyString(AnyCodingKey("severity")) ?? "HEALTH_WARN", summary: summary, details: details,
                    isMuted: check.lossyBool(AnyCodingKey("muted")) ?? false
                ))
            }
        }
        // Errors first, then by code, so the list does not jump around.
        self.checks = checks.sorted { ($0.severity == "HEALTH_ERR" ? 0 : 1, $0.code) < ($1.severity == "HEALTH_ERR" ? 0 : 1, $1.code) }

        let monmap = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("monmap"))
        monitors = ((try? monmap?.decodeIfPresent([[String: AnyDecodable]].self, forKey: AnyCodingKey("mons"))) ?? []).compactMap { $0["name"]?.string }

        let osdmap = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("osdmap"))
        osdCount = osdmap?.lossyInt(AnyCodingKey("num_osds")) ?? 0
        osdsUp = osdmap?.lossyInt(AnyCodingKey("num_up_osds")) ?? 0
        osdsIn = osdmap?.lossyInt(AnyCodingKey("num_in_osds")) ?? 0

        let pgmap = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("pgmap"))
        placementGroups = pgmap?.lossyInt(AnyCodingKey("num_pgs")) ?? 0
        placementGroupStates = ((try? pgmap?.decodeIfPresent([[String: AnyDecodable]].self, forKey: AnyCodingKey("pgs_by_state"))) ?? [])
            .compactMap { entry in entry["state_name"]?.string.map { ($0, entry["count"]?.int ?? 0) } }
            .sorted { $0.count > $1.count }
        pools = pgmap?.lossyInt(AnyCodingKey("num_pools")) ?? 0
        objects = pgmap?.lossyInt(AnyCodingKey("num_objects")) ?? 0
        bytesUsed = Int64(pgmap?.lossyDouble(AnyCodingKey("bytes_used")) ?? 0)
        bytesTotal = Int64(pgmap?.lossyDouble(AnyCodingKey("bytes_total")) ?? 0)
        bytesAvailable = Int64(pgmap?.lossyDouble(AnyCodingKey("bytes_avail")) ?? 0)
        degradedRatio = pgmap?.lossyDouble(AnyCodingKey("degraded_ratio")) ?? 0

        let mgrmap = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("mgrmap"))
        activeManager = mgrmap?.lossyString(AnyCodingKey("active_name")).flatMap { $0.isEmpty ? nil : $0 }
        standbyManagers = ((try? mgrmap?.decodeIfPresent([[String: AnyDecodable]].self, forKey: AnyCodingKey("standbys"))) ?? []).compactMap { $0["name"]?.string }

        let fsmap = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("fsmap"))
        metadataServersUp = fsmap?.lossyInt(AnyCodingKey("up")) ?? 0
        metadataServersStandby = fsmap?.lossyInt(AnyCodingKey("up:standby")) ?? 0
    }

    public static func == (lhs: CephStatus, rhs: CephStatus) -> Bool {
        lhs.health == rhs.health && lhs.checks == rhs.checks && lhs.fsid == rhs.fsid && lhs.quorum == rhs.quorum && lhs.osdsUp == rhs.osdsUp
            && lhs.osdsIn == rhs.osdsIn && lhs.osdCount == rhs.osdCount && lhs.placementGroups == rhs.placementGroups && lhs.bytesUsed == rhs.bytesUsed
            && lhs.placementGroupStates.map(\.state) == rhs.placementGroupStates.map(\.state) && lhs.placementGroupStates.map(\.count) == rhs.placementGroupStates.map(\.count)
    }
}

/// A JSON value of unknown type, for the loosely typed parts of Ceph's answers.
struct AnyDecodable: Decodable, Sendable {
    var string: String?
    var int: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            int = value
            string = String(value)
        } else if let value = try? container.decode(Double.self) {
            int = Int(value)
            string = String(value)
        } else if let value = try? container.decode(String.self) {
            string = value
            int = Int(value)
        }
    }
}

/// A monitor, manager or metadata server, `GET /nodes/{node}/ceph/{mon,mgr,mds}`.
public struct CephService: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case monitor = "mon"
        case manager = "mgr"
        case metadataServer = "mds"

        public var id: String { rawValue }
    }

    public var name: String
    public var host: String
    /// Like `running`, `active`, `standby`, `up:active` or `stopped`.
    public var state: String
    public var address: String?
    public var version: String?
    /// Monitors: whether it is in the quorum.
    public var inQuorum: Bool?
    /// Metadata servers: the file system it serves.
    public var fileSystem: String?

    public var id: String { name }

    public init(name: String, host: String, state: String) {
        self.name = name
        self.host = host
        self.state = state
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        host = container.lossyString(AnyCodingKey("host")) ?? ""
        state = container.lossyString(AnyCodingKey("state")) ?? "unknown"
        address = container.lossyString(AnyCodingKey("addr"))
        version = container.lossyString(AnyCodingKey("ceph_version_short"))
        inQuorum = container.lossyBool(AnyCodingKey("quorum"))
        fileSystem = container.lossyString(AnyCodingKey("fs_name"))
    }

    public var isRunning: Bool {
        !["stopped", "unknown", "down"].contains(state) && !state.hasPrefix("down")
    }
}

/// An OSD from `GET /nodes/{node}/ceph/osd`, which is a tree of the CRUSH root, hosts and OSDs.
public struct CephOSD: Sendable, Equatable, Identifiable {
    public var id: Int
    public var host: String
    public var isUp: Bool
    public var isIn: Bool
    public var deviceClass: String?
    public var percentUsed: Double
    public var bytesUsed: Int64
    public var totalSpace: Int64
    public var version: String?
    public var placementGroups: Int
    public var applyLatency: Int
    public var commitLatency: Int
    public var databaseDevice: String?
    public var walDevice: String?

    public var name: String { "osd.\(id)" }

    public init(id: Int, host: String, isUp: Bool = true, isIn: Bool = true, deviceClass: String? = "hdd", percentUsed: Double = 0, bytesUsed: Int64 = 0, totalSpace: Int64 = 0) {
        self.id = id
        self.host = host
        self.isUp = isUp
        self.isIn = isIn
        self.deviceClass = deviceClass
        self.percentUsed = percentUsed
        self.bytesUsed = bytesUsed
        self.totalSpace = totalSpace
        placementGroups = 0
        applyLatency = 0
        commitLatency = 0
    }
}

/// The OSD tree: OSDs by host, and the cluster-wide OSD flags like `noout`.
public struct CephOSDTree: Decodable, Sendable, Equatable {
    public var osds: [CephOSD]
    public var hosts: [String]
    public var flags: [String]

    public init(osds: [CephOSD], hosts: [String], flags: [String] = []) {
        self.osds = osds
        self.hosts = hosts
        self.flags = flags
    }

    private struct Node: Decodable {
        var type: String?
        var name: String?
        var id: String?
        var host: String?
        var status: String?
        var isIn: Bool?
        var deviceClass: String?
        var percentUsed: Double?
        var bytesUsed: Double?
        var totalSpace: Double?
        var version: String?
        var pgs: Int?
        var applyLatency: Int?
        var commitLatency: Int?
        var databaseDevice: String?
        var walDevice: String?
        var children: [Node]?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            type = container.lossyString(AnyCodingKey("type"))
            name = container.lossyString(AnyCodingKey("name"))
            id = container.lossyString(AnyCodingKey("id"))
            host = container.lossyString(AnyCodingKey("host"))
            status = container.lossyString(AnyCodingKey("status"))
            isIn = container.lossyBool(AnyCodingKey("in"))
            deviceClass = container.lossyString(AnyCodingKey("device_class"))
            percentUsed = container.lossyDouble(AnyCodingKey("percent_used"))
            bytesUsed = container.lossyDouble(AnyCodingKey("bytes_used"))
            totalSpace = container.lossyDouble(AnyCodingKey("total_space"))
            version = container.lossyString(AnyCodingKey("ceph_version_short"))
            pgs = container.lossyInt(AnyCodingKey("pgs"))
            applyLatency = container.lossyInt(AnyCodingKey("apply_latency_ms"))
            commitLatency = container.lossyInt(AnyCodingKey("commit_latency_ms"))
            databaseDevice = container.lossyString(AnyCodingKey("dbdev"))
            walDevice = container.lossyString(AnyCodingKey("waldev"))
            children = try? container.decodeIfPresent([Node].self, forKey: AnyCodingKey("children"))
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        flags = (container.lossyString(AnyCodingKey("flags")) ?? "").split(separator: ",").map(String.init)
        let root = try? container.decodeIfPresent(Node.self, forKey: AnyCodingKey("root"))
        var osds: [CephOSD] = []
        var hosts: [String] = []
        func visit(_ node: Node, host: String?) {
            if node.type == "host", let name = node.name { hosts.append(name) }
            if node.type == "osd", let id = node.id.flatMap(Int.init) {
                var osd = CephOSD(
                    id: id, host: node.host ?? host ?? "", isUp: node.status == "up", isIn: node.isIn ?? false, deviceClass: node.deviceClass,
                    percentUsed: node.percentUsed ?? 0, bytesUsed: Int64(node.bytesUsed ?? 0), totalSpace: Int64(node.totalSpace ?? 0)
                )
                osd.version = node.version
                osd.placementGroups = node.pgs ?? 0
                osd.applyLatency = node.applyLatency ?? 0
                osd.commitLatency = node.commitLatency ?? 0
                osd.databaseDevice = node.databaseDevice
                osd.walDevice = node.walDevice
                osds.append(osd)
            }
            for child in node.children ?? [] {
                visit(child, host: node.type == "host" ? node.name : host)
            }
        }
        if let root { visit(root, host: nil) }
        self.osds = osds.sorted { $0.id < $1.id }
        self.hosts = hosts.sorted()
    }
}

/// The web interface's Create OSD dialog.
public struct CephOSDDraft: Sendable, Equatable {
    public var device = ""
    /// Separate DB and WAL devices, empty to keep them on the OSD disk.
    public var databaseDevice = ""
    /// GiB, empty for automatic.
    public var databaseSize = ""
    public var walDevice = ""
    public var walSize = ""
    public var encrypted = false
    /// Empty to detect it.
    public var deviceClass = ""

    public init(device: String = "") {
        self.device = device
    }

    public var parameters: APIParameters {
        var parameters: APIParameters = ["dev": .string(device)]
        if !databaseDevice.isEmpty {
            parameters["db_dev"] = .string(databaseDevice)
            if let size = Self.number(databaseSize) { parameters["db_dev_size"] = .string(size) }
        }
        if !walDevice.isEmpty {
            parameters["wal_dev"] = .string(walDevice)
            if let size = Self.number(walSize) { parameters["wal_dev_size"] = .string(size) }
        }
        if encrypted { parameters["encrypted"] = true }
        if !deviceClass.isEmpty { parameters["crush-device-class"] = .string(deviceClass) }
        return parameters
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if device.isEmpty { problems["dev"] = String(localized: "Choose a disk.") }
        if !databaseDevice.isEmpty, databaseDevice == device { problems["db_dev"] = String(localized: "Choose another disk than the OSD's.") }
        if !walDevice.isEmpty, walDevice == device { problems["wal_dev"] = String(localized: "Choose another disk than the OSD's.") }
        // Sizes only count with their own disk.
        for (key, device, value, minimum) in [("db_dev_size", databaseDevice, databaseSize, 1.0), ("wal_dev_size", walDevice, walSize, 0.5)] where !device.isEmpty {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !(Double(trimmed.replacingOccurrences(of: ",", with: ".")).map { $0 >= minimum } ?? false) {
                problems[key] = String(localized: "Enter at least \(minimum.formatted()) GiB, or leave it empty.")
            }
        }
        return problems
    }

    private static func number(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A pool from `GET /nodes/{node}/ceph/pool`.
public struct CephPool: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var number: Int
    public var size: Int
    public var minSize: Int
    public var placementGroups: Int
    /// What the autoscaler would set.
    public var placementGroupsTarget: Int?
    public var placementGroupsMinimum: Int?
    /// `on`, `warn` or `off`.
    public var autoscaleMode: String
    public var crushRule: String
    public var percentUsed: Double
    public var bytesUsed: Int64
    /// Like `rbd` or `cephfs`.
    public var applications: [String]
    /// `replicated` or `erasure`.
    public var type: String
    public var targetSizeRatio: Double?
    public var targetSize: Int64?

    public var id: String { name }

    public init(name: String, size: Int = 3, minSize: Int = 2, placementGroups: Int = 32, autoscaleMode: String = "on", crushRule: String = "replicated_rule", applications: [String] = ["rbd"]) {
        self.name = name
        number = 0
        self.size = size
        self.minSize = minSize
        self.placementGroups = placementGroups
        self.autoscaleMode = autoscaleMode
        self.crushRule = crushRule
        percentUsed = 0
        bytesUsed = 0
        self.applications = applications
        type = "replicated"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("pool_name")) ?? ""
        number = container.lossyInt(AnyCodingKey("pool")) ?? 0
        size = container.lossyInt(AnyCodingKey("size")) ?? 3
        minSize = container.lossyInt(AnyCodingKey("min_size")) ?? 2
        placementGroups = container.lossyInt(AnyCodingKey("pg_num")) ?? 0
        placementGroupsTarget = container.lossyInt(AnyCodingKey("pg_num_final"))
        placementGroupsMinimum = container.lossyInt(AnyCodingKey("pg_num_min"))
        autoscaleMode = container.lossyString(AnyCodingKey("pg_autoscale_mode")) ?? "on"
        crushRule = container.lossyString(AnyCodingKey("crush_rule_name")) ?? ""
        // Ceph reports a fraction, despite the name.
        percentUsed = (container.lossyDouble(AnyCodingKey("percent_used")) ?? 0) * 100
        bytesUsed = Int64(container.lossyDouble(AnyCodingKey("bytes_used")) ?? 0)
        applications = ((try? container.decodeIfPresent([String: [String: String]].self, forKey: AnyCodingKey("application_metadata"))) ?? [:]).keys.sorted()
        type = container.lossyString(AnyCodingKey("type")) ?? "replicated"
        targetSizeRatio = container.lossyDouble(AnyCodingKey("target_size_ratio"))
        targetSize = container.lossyDouble(AnyCodingKey("target_size")).map { Int64($0) }
    }
}

/// The web interface's Create and Edit Pool dialog.
public struct CephPoolDraft: Sendable, Equatable {
    public var name = ""
    public var size = 3
    public var minSize = 2
    public var crushRule = "replicated_rule"
    public var placementGroups = "128"
    public var placementGroupsMinimum = ""
    public var autoscaleMode = "on"
    /// Share of the cluster the pool is expected to use, which guides the autoscaler.
    public var targetSizeRatio = ""
    /// Expected size in GiB; the ratio takes precedence.
    public var targetSizeGiB = ""
    /// Creation only.
    public var application = "rbd"
    /// Creation only: add the pool as storage of the datacenter.
    public var addStorage = true

    public init() {}

    public init(_ pool: CephPool) {
        name = pool.name
        size = pool.size
        minSize = pool.minSize
        crushRule = pool.crushRule
        placementGroups = String(pool.placementGroups)
        placementGroupsMinimum = pool.placementGroupsMinimum.map(String.init) ?? ""
        autoscaleMode = pool.autoscaleMode
        targetSizeRatio = pool.targetSizeRatio.map { $0.formatted(.number.grouping(.never)) } ?? ""
        targetSizeGiB = pool.targetSize.map { String($0 / 1_073_741_824) } ?? ""
        application = pool.applications.first ?? "rbd"
        addStorage = false
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Settings that can change after creation.
    func serialized() -> [String: String?] {
        [
            "size": String(size),
            "min_size": String(minSize),
            "crush_rule": crushRule,
            "pg_num": Self.text(placementGroups),
            "pg_num_min": Self.text(placementGroupsMinimum),
            "pg_autoscale_mode": autoscaleMode,
            "target_size_ratio": Self.text(targetSizeRatio),
            "target_size": Self.text(targetSizeGiB).map { "\($0)G" },
        ]
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["name": .string(name.trimmingCharacters(in: .whitespaces))]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        parameters["application"] = .string(application)
        parameters["add_storages"] = .bool(addStorage)
        return parameters
    }

    /// Changed settings. Cleared values cannot be deleted, so they are not sent.
    public func changes(from original: CephPoolDraft) -> APIParameters {
        var parameters = APIParameters()
        let old = original.serialized()
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) where value != (old[key] ?? nil) {
            if let value { parameters[key] = .string(value) }
        }
        return parameters
    }

    /// A min_size of 1 risks losing data; the web interface warns about it.
    public var warnsAboutMinSize: Bool { minSize == 1 }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.contains(where: { $0.isWhitespace || $0 == "/" }) {
            problems["name"] = String(localized: "Enter a name without spaces or slashes.")
        }
        if !(1...7).contains(size) { problems["size"] = String(localized: "Use 1 to 7 replicas.") }
        if !(1...size).contains(minSize) { problems["min_size"] = String(localized: "Use at least 1 and at most the size.") }
        if let pgs = Self.text(placementGroups), !(Int(pgs).map { (1...32768).contains($0) } ?? false) {
            problems["pg_num"] = String(localized: "Use 1 to 32768 placement groups.")
        }
        if let ratio = Self.text(targetSizeRatio), !(Double(ratio).map { $0 >= 0 } ?? false) {
            problems["target_size_ratio"] = String(localized: "Enter a number of at least 0.")
        }
        if let size = Self.text(targetSizeGiB), !(Double(size).map { $0 >= 0 } ?? false) {
            problems["target_size"] = String(localized: "Enter a size in GiB.")
        }
        return problems
    }
}

/// A Ceph file system, `GET /nodes/{node}/ceph/fs`.
public struct CephFileSystem: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var metadataPool: String
    public var dataPools: [String]

    public var id: String { name }

    public init(name: String, metadataPool: String, dataPools: [String]) {
        self.name = name
        self.metadataPool = metadataPool
        self.dataPools = dataPools
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        metadataPool = container.lossyString(AnyCodingKey("metadata_pool")) ?? ""
        dataPools = (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("data_pools"))) ?? []
    }
}

/// A cluster-wide OSD flag, `GET /cluster/ceph/flags`.
public struct CephFlag: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    public var isSet: Bool

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        description = container.lossyString(AnyCodingKey("description")) ?? ""
        isSet = container.lossyBool(AnyCodingKey("value")) ?? false
    }
}

/// An entry of the monitors' configuration database, `GET /nodes/{node}/ceph/cfg/db`.
public struct CephConfigEntry: Decodable, Sendable, Equatable, Identifiable {
    public var section: String
    public var name: String
    public var value: String
    public var level: String

    public var id: String { "\(section)/\(name)" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        section = container.lossyString(AnyCodingKey("section")) ?? ""
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        value = container.lossyString(AnyCodingKey("value")) ?? ""
        level = container.lossyString(AnyCodingKey("level")) ?? ""
    }
}

/// `GET /nodes/{node}/ceph/cmd-safety`: whether stopping or destroying a service would take data offline.
public struct CephSafetyCheck: Decodable, Sendable, Equatable {
    public var isSafe: Bool
    public var status: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        isSafe = container.lossyBool(AnyCodingKey("safe")) ?? true
        status = container.lossyString(AnyCodingKey("status"))
    }
}

extension PVE {
    public static func cephReleases(node: String) -> APIRequest<[CephRelease]> {
        APIRequest(.get, "/nodes/\(node)/ceph/releases")
    }

    /// Creates the cluster's Ceph configuration. `network` is the public network, like `10.0.0.0/24`.
    public static func initializeCeph(node: String, network: String, clusterNetwork: String?, size: Int?, minSize: Int?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["network": .string(network)]
        if let clusterNetwork, !clusterNetwork.isEmpty { parameters["cluster-network"] = .string(clusterNetwork) }
        if let size { parameters["size"] = .int(size) }
        if let minSize { parameters["min_size"] = .int(minSize) }
        return APIRequest(.post, "/nodes/\(node)/ceph/init", parameters: parameters)
    }

    public static func cephStatus(node: String) -> APIRequest<CephStatus> {
        APIRequest(.get, "/nodes/\(node)/ceph/status")
    }

    public static func cephServices(_ kind: CephService.Kind, node: String) -> APIRequest<[CephService]> {
        APIRequest(.get, "/nodes/\(node)/ceph/\(kind.rawValue)")
    }

    /// Creates a monitor, manager or metadata server on the node, named after it. Returns a task ID.
    public static func createCephService(_ kind: CephService.Kind, node: String, id: String? = nil, hotStandby: Bool = false) -> APIRequest<String> {
        var parameters = APIParameters()
        if kind == .metadataServer, hotStandby { parameters["hotstandby"] = true }
        return APIRequest(.post, "/nodes/\(node)/ceph/\(kind.rawValue)/\(escapePath(id ?? node))", parameters: parameters)
    }

    /// Destroys a service on its host. Returns a task ID.
    public static func destroyCephService(_ kind: CephService.Kind, node: String, id: String) -> APIRequest<String> {
        APIRequest(.delete, "/nodes/\(node)/ceph/\(kind.rawValue)/\(escapePath(id))")
    }

    /// Starts, stops or restarts a daemon like `mon.pve1` or `osd.3` on its host. Returns a task ID.
    public static func cephServiceAction(_ action: String, node: String, service: String) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(node)/ceph/\(action)", parameters: ["service": .string(service)])
    }

    public static func cephSafety(node: String, service: String, id: String, action: String) -> APIRequest<CephSafetyCheck> {
        APIRequest(.get, "/nodes/\(node)/ceph/cmd-safety", parameters: ["service": .string(service), "id": .string(id), "action": .string(action)])
    }

    public static func cephOSDs(node: String) -> APIRequest<CephOSDTree> {
        APIRequest(.get, "/nodes/\(node)/ceph/osd")
    }

    public static func createCephOSD(node: String, _ draft: CephOSDDraft) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(node)/ceph/osd", parameters: draft.parameters)
    }

    /// Removes an OSD that is out and stopped; `cleanup` also wipes its disks.
    public static func destroyCephOSD(node: String, id: Int, cleanup: Bool) -> APIRequest<String> {
        APIRequest(.delete, "/nodes/\(node)/ceph/osd/\(id)", parameters: cleanup ? ["cleanup": true] : [:])
    }

    /// Marks the OSD in or out of the data distribution.
    public static func setCephOSD(node: String, id: Int, in isIn: Bool) -> APIRequest<Nothing> {
        APIRequest(.post, "/nodes/\(node)/ceph/osd/\(id)/\(isIn ? "in" : "out")")
    }

    public static func scrubCephOSD(node: String, id: Int, deep: Bool) -> APIRequest<Nothing> {
        APIRequest(.post, "/nodes/\(node)/ceph/osd/\(id)/scrub", parameters: deep ? ["deep": true] : [:])
    }

    public static func cephFlags() -> APIRequest<[CephFlag]> {
        APIRequest(.get, "/cluster/ceph/flags")
    }

    /// Sets or clears several flags at once. Returns a task ID.
    public static func setCephFlags(_ flags: [String: Bool]) -> APIRequest<String> {
        var parameters = APIParameters()
        for (name, value) in flags.sorted(by: { $0.key < $1.key }) { parameters[name] = .bool(value) }
        return APIRequest(.put, "/cluster/ceph/flags", parameters: parameters)
    }

    public static func cephPoolList(node: String) -> APIRequest<[CephPool]> {
        APIRequest(.get, "/nodes/\(node)/ceph/pool")
    }

    public static func createCephPool(node: String, _ draft: CephPoolDraft) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(node)/ceph/pool", parameters: draft.creationParameters)
    }

    public static func updateCephPool(node: String, name: String, _ parameters: APIParameters) -> APIRequest<String?> {
        APIRequest(.put, "/nodes/\(node)/ceph/pool/\(escapePath(name))", parameters: parameters)
    }

    /// Destroys a pool and its data; `removeStorages` also removes the storage entries using it.
    public static func destroyCephPool(node: String, name: String, removeStorages: Bool) -> APIRequest<String> {
        APIRequest(.delete, "/nodes/\(node)/ceph/pool/\(escapePath(name))", parameters: removeStorages ? ["remove_storages": true] : [:])
    }

    public static func cephRules(node: String) -> APIRequest<[[String: String]]> {
        APIRequest(.get, "/nodes/\(node)/ceph/rules")
    }

    public static func cephFileSystems(node: String) -> APIRequest<[CephFileSystem]> {
        APIRequest(.get, "/nodes/\(node)/ceph/fs")
    }

    /// Creates a file system with its data and metadata pools. Needs a metadata server.
    public static func createCephFileSystem(node: String, name: String, placementGroups: Int, addStorage: Bool) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(node)/ceph/fs/\(escapePath(name))", parameters: ["pg_num": .int(placementGroups), "add-storage": .bool(addStorage)])
    }

    public static func cephConfigFile(node: String) -> APIRequest<String> {
        APIRequest(.get, "/nodes/\(node)/ceph/cfg/raw")
    }

    public static func cephConfigDatabase(node: String) -> APIRequest<[CephConfigEntry]> {
        APIRequest(.get, "/nodes/\(node)/ceph/cfg/db")
    }

    public static func cephCrushMap(node: String) -> APIRequest<String> {
        APIRequest(.get, "/nodes/\(node)/ceph/crush")
    }

    /// The cluster log, oldest first.
    public static func cephLog(node: String, limit: Int = 500) -> APIRequest<[TaskLogLine]> {
        APIRequest(.get, "/nodes/\(node)/ceph/log", parameters: ["limit": .int(limit)])
    }
}
