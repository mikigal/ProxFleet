import Foundation
import ProxmoxCore

/// One entry of `GET /nodes/{node}/disks/list`: a disk, or a partition with `include-partitions`.
public struct NodeDisk: Decodable, Sendable, Equatable, Identifiable {
    /// For example `/dev/sda` or `/dev/nvme0n1p3`.
    public var path: String
    /// The disk a partition is on; nil for disks.
    public var parent: String?
    public var model: String?
    public var vendor: String?
    public var serial: String?
    public var size: Int64
    /// `hdd`, `ssd`, `nvme`, `usb`, `partition`…
    public var type: String
    /// `OK`, `PASSED`, `FAILED`, `UNKNOWN`…
    public var health: String?
    /// Remaining life of an SSD in percent; nil when the disk does not report it.
    public var wearout: Int?
    /// What the disk is used for: `LVM`, `ZFS`, `partitions`, `mounted`, `BIOS boot`, a file system… nil when unused.
    public var usage: String?
    public var hasGPT: Bool
    public var isMounted: Bool
    public var rpm: Int?
    public var wwn: String?

    public var id: String { path }
    public var isPartition: Bool { parent != nil }
    public var isUnused: Bool { usage == nil }
    public var name: String { path.replacingOccurrences(of: "/dev/", with: "") }

    /// Health that needs attention, as the web interface marks it.
    public var isFailing: Bool {
        guard let health = health?.uppercased() else { return false }
        return !["OK", "PASSED", "UNKNOWN", ""].contains(health)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func string(_ key: String) -> String? {
            container.lossyString(AnyCodingKey(key)).flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || trimmed == "unknown" ? nil : trimmed
            }
        }
        path = string("devpath") ?? ""
        parent = string("parent")
        model = string("model")
        vendor = string("vendor")
        serial = string("serial")
        size = Int64(container.lossyDouble(AnyCodingKey("size")) ?? 0)
        type = string("type") ?? (parent == nil ? "unknown" : "partition")
        health = string("health")
        wearout = container.lossyInt(AnyCodingKey("wearout"))
        usage = string("used")
        hasGPT = container.lossyBool(AnyCodingKey("gpt")) ?? false
        isMounted = container.lossyBool(AnyCodingKey("mounted")) ?? false
        rpm = container.lossyInt(AnyCodingKey("rpm")).flatMap { $0 > 0 ? $0 : nil }
        wwn = string("wwn")
    }

    /// Disks with their partitions right after them, ordered by path.
    public static func grouped(_ disks: [NodeDisk]) -> [(disk: NodeDisk, partitions: [NodeDisk])] {
        let partitions = Dictionary(grouping: disks.filter(\.isPartition)) { $0.parent ?? "" }
        return disks.filter { !$0.isPartition }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { disk in
                (disk: disk, partitions: (partitions[disk.path] ?? []).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
            }
    }
}

/// `GET /nodes/{node}/disks/smart`: ATA disks report attributes, others (NVMe, SAS) plain text.
public struct SMARTReport: Decodable, Sendable, Equatable {
    public struct Attribute: Decodable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var name: String
        public var value: String
        public var worst: String
        public var threshold: String
        public var raw: String
        /// `-` when fine; otherwise when it failed, e.g. `FAILING_NOW` or `In_the_past`.
        public var fail: String

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            func string(_ key: String) -> String {
                container.lossyString(AnyCodingKey(key))?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            id = Int(string("id")) ?? 0
            name = string("name").replacingOccurrences(of: "_", with: " ")
            value = string("value")
            worst = string("worst")
            threshold = string("threshold")
            raw = string("raw")
            fail = string("fail")
        }

        public var isFailing: Bool { !fail.isEmpty && fail != "-" }
    }

    public var health: String
    public var attributes: [Attribute]
    public var text: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        health = container.lossyString(AnyCodingKey("health")) ?? "UNKNOWN"
        attributes = (try? container.decodeIfPresent([Attribute].self, forKey: AnyCodingKey("attributes"))) ?? []
        text = container.lossyString(AnyCodingKey("text"))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

/// A volume group, from the tree `GET /nodes/{node}/disks/lvm` returns.
public struct LVMVolumeGroup: Sendable, Equatable, Identifiable {
    public struct PhysicalVolume: Sendable, Equatable {
        public var name: String
        public var size: Int64
        public var free: Int64
    }

    public var name: String
    public var size: Int64
    public var free: Int64
    public var volumeCount: Int
    public var physicalVolumes: [PhysicalVolume]

    public var id: String { name }
}

/// `GET /nodes/{node}/disks/lvm`: `{"leaf": 0, "children": [volume groups with physical volumes as children]}`.
public struct LVMVolumeGroups: Decodable, Sendable, Equatable {
    public var groups: [LVMVolumeGroup]

    public init(from decoder: any Decoder) throws {
        let root = try decoder.singleValueContainer().decode(TreeNode.self)
        groups = root.children.map { group in
            LVMVolumeGroup(
                name: group.name, size: group.size, free: group.free, volumeCount: group.count ?? 0,
                physicalVolumes: group.children.map { LVMVolumeGroup.PhysicalVolume(name: $0.name, size: $0.size, free: $0.free) }
            )
        }
    }

    private struct TreeNode: Decodable {
        var name: String
        var size: Int64
        var free: Int64
        var count: Int?
        var children: [TreeNode]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            name = container.lossyString(AnyCodingKey("name")) ?? ""
            size = Int64(container.lossyDouble(AnyCodingKey("size")) ?? 0)
            free = Int64(container.lossyDouble(AnyCodingKey("free")) ?? 0)
            count = container.lossyInt(AnyCodingKey("lvcount"))
            children = (try? container.decodeIfPresent([TreeNode].self, forKey: AnyCodingKey("children"))) ?? []
        }
    }
}

/// One entry of `GET /nodes/{node}/disks/lvmthin`.
public struct LVMThinPool: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var volumeGroup: String
    public var size: Int64
    public var used: Int64
    public var metadataSize: Int64
    public var metadataUsed: Int64

    public var id: String { "\(volumeGroup)/\(name)" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func bytes(_ key: String) -> Int64 { Int64(container.lossyDouble(AnyCodingKey(key)) ?? 0) }
        name = container.lossyString(AnyCodingKey("lv")) ?? ""
        volumeGroup = container.lossyString(AnyCodingKey("vg")) ?? ""
        size = bytes("lv_size")
        used = bytes("used")
        metadataSize = bytes("metadata_size")
        metadataUsed = bytes("metadata_used")
    }
}

/// One entry of `GET /nodes/{node}/disks/zfs`.
public struct ZFSPool: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var size: Int64
    public var allocated: Int64
    public var free: Int64
    /// Fragmentation in percent.
    public var fragmentation: Int
    public var dedupRatio: Double
    /// `ONLINE`, `DEGRADED`, `FAULTED`…
    public var health: String

    public var id: String { name }
    public var isHealthy: Bool { health == "ONLINE" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func bytes(_ key: String) -> Int64 { Int64(container.lossyDouble(AnyCodingKey(key)) ?? 0) }
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        size = bytes("size")
        allocated = bytes("alloc")
        free = bytes("free")
        fragmentation = container.lossyInt(AnyCodingKey("frag")) ?? 0
        dedupRatio = container.lossyDouble(AnyCodingKey("dedup")) ?? 1
        health = container.lossyString(AnyCodingKey("health")) ?? "UNKNOWN"
    }
}

/// `GET /nodes/{node}/disks/zfs/{name}`: the parsed `zpool status`.
public struct ZFSPoolStatus: Decodable, Sendable, Equatable {
    /// A vdev, a section such as `logs` or `cache`, or a disk.
    public struct Device: Decodable, Sendable, Equatable, Identifiable {
        public var name: String
        public var state: String?
        public var readErrors: Int
        public var writeErrors: Int
        public var checksumErrors: Int
        public var message: String?
        public var children: [Device]

        public var id: String { name }
        public var hasErrors: Bool { readErrors + writeErrors + checksumErrors > 0 }

        /// Disks are listed by full path (`zpool status -P`), e.g. `/dev/disk/by-id/ata-…-part1`; this is the last part.
        public var displayName: String {
            name.hasPrefix("/") ? (name.split(separator: "/").last.map(String.init) ?? name) : name
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            name = container.lossyString(AnyCodingKey("name")) ?? ""
            state = container.lossyString(AnyCodingKey("state"))
            readErrors = container.lossyInt(AnyCodingKey("read")) ?? 0
            writeErrors = container.lossyInt(AnyCodingKey("write")) ?? 0
            checksumErrors = container.lossyInt(AnyCodingKey("cksum")) ?? 0
            message = container.lossyString(AnyCodingKey("msg"))?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            children = (try? container.decodeIfPresent([Device].self, forKey: AnyCodingKey("children"))) ?? []
        }

        /// The tree flattened for a list, with the depth of each device.
        public func flattened(depth: Int = 0) -> [(device: Device, depth: Int)] {
            [(device: self, depth: depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
        }
    }

    public var name: String
    public var state: String
    public var status: String?
    public var action: String?
    public var scan: String?
    public var errors: String?
    public var devices: [Device]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func text(_ key: String) -> String? {
            container.lossyString(AnyCodingKey(key))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        name = text("name") ?? ""
        state = text("state") ?? "UNKNOWN"
        status = text("status")
        action = text("action")
        scan = text("scan")
        errors = text("errors")
        devices = (try? container.decodeIfPresent([Device].self, forKey: AnyCodingKey("children"))) ?? []
    }
}

/// One entry of `GET /nodes/{node}/disks/directory`: a file system mounted by a systemd unit under `/mnt/pve`.
public struct DirectoryMount: Decodable, Sendable, Equatable, Identifiable {
    public var path: String
    public var device: String
    public var fileSystem: String
    public var options: String?

    public var id: String { path }
    /// `/mnt/pve/backup` → `backup`, the name the delete call takes.
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        path = container.lossyString(AnyCodingKey("path")) ?? ""
        device = container.lossyString(AnyCodingKey("device")) ?? ""
        fileSystem = container.lossyString(AnyCodingKey("type")) ?? ""
        options = container.lossyString(AnyCodingKey("options"))
    }
}

/// Storage that can be created on unused disks, as in the web interface's Disks panels.
public enum DiskStorageKind: String, CaseIterable, Sendable, Identifiable {
    case lvm, lvmThin = "lvmthin", zfs, directory

    public var id: String { rawValue }

    /// ZFS takes several disks; the others one.
    public var takesSeveralDisks: Bool { self == .zfs }
}

/// The form for creating an LVM volume group, LVM thin pool, ZFS pool or directory.
public struct DiskStorageDraft: Equatable, Sendable {
    public var kind: DiskStorageKind
    public var name = ""
    public var devices: [String] = []
    /// Also add it as a storage in the datacenter, so guests can use it.
    public var addStorage = true
    public var raidLevel = "single"
    public var compression = "on"
    public var ashift = 12
    public var fileSystem = "ext4"
    /// Sizes of the chosen disks, by path, so a mirror or RAIDZ of different sizes is caught before `zpool` refuses it.
    public var deviceSizes: [String: Int64] = [:]

    public static let raidLevels = ["single", "mirror", "raid10", "raidz", "raidz2", "raidz3"]
    public static let compressions = ["on", "off", "lz4", "zstd", "gzip", "lzjb", "zle"]

    public init(kind: DiskStorageKind) {
        self.kind = kind
    }

    /// Disks each RAID level needs at least.
    public static func minimumDisks(for raidLevel: String) -> Int {
        switch raidLevel {
        case "mirror": 2
        case "raid10": 4
        case "raidz": 3
        case "raidz2": 4
        case "raidz3": 5
        default: 1
        }
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            problems["name"] = String(localized: "Enter a name.")
        } else if !(name.first?.isLetter ?? false) || name.contains(where: { !($0.isLetter || $0.isNumber || "-_.".contains($0)) }) {
            problems["name"] = String(localized: "Start with a letter; use letters, digits, and - _ . only.")
        }
        let key = kind.takesSeveralDisks ? "devices" : "device"
        if devices.isEmpty {
            problems[key] = String(localized: "Choose a disk.")
        } else if kind == .zfs, devices.count < Self.minimumDisks(for: raidLevel) {
            problems[key] = String(localized: "\(raidLevel) needs at least \(Self.minimumDisks(for: raidLevel)) disks.")
        } else if kind == .zfs, raidLevel == "raid10", !devices.count.isMultiple(of: 2) {
            problems[key] = String(localized: "raid10 needs an even number of disks.")
        } else if kind == .zfs, raidLevel != "single", Set(devices.compactMap { deviceSizes[$0] }).count > 1 {
            problems[key] = String(localized: "\(raidLevel) needs disks of the same size.")
        }
        return problems
    }

    var parameters: APIParameters {
        var parameters: APIParameters = ["name": .string(name.trimmingCharacters(in: .whitespaces))]
        if kind.takesSeveralDisks {
            parameters["devices"] = .string(devices.joined(separator: ","))
            parameters["raidlevel"] = .string(devices.count == 1 ? "single" : raidLevel)
            parameters["compression"] = .string(compression)
            parameters["ashift"] = .int(ashift)
        } else {
            parameters["device"] = .string(devices.first ?? "")
        }
        if kind == .directory { parameters["filesystem"] = .string(fileSystem) }
        parameters["add_storage"] = .bool(addStorage)
        return parameters
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension PVE {
    public static func disks(node: String, includePartitions: Bool = true) -> APIRequest<[NodeDisk]> {
        APIRequest(.get, "/nodes/\(node)/disks/list", parameters: ["include-partitions": .bool(includePartitions)])
    }

    public static func smart(node: String, disk: String) -> APIRequest<SMARTReport> {
        APIRequest(.get, "/nodes/\(node)/disks/smart", parameters: ["disk": .string(disk)])
    }

    /// Writes an empty GPT partition table. Returns a task ID.
    public static func initializeGPT(node: String, disk: String) -> APIRequest<String?> {
        APIRequest(.post, "/nodes/\(node)/disks/initgpt", parameters: ["disk": .string(disk)])
    }

    /// Removes partition tables and file system signatures from a disk or partition. Returns a task ID.
    public static func wipeDisk(node: String, disk: String) -> APIRequest<String?> {
        APIRequest(.put, "/nodes/\(node)/disks/wipedisk", parameters: ["disk": .string(disk)])
    }

    public static func volumeGroups(node: String) -> APIRequest<LVMVolumeGroups> {
        APIRequest(.get, "/nodes/\(node)/disks/lvm")
    }

    public static func thinPools(node: String) -> APIRequest<[LVMThinPool]> {
        APIRequest(.get, "/nodes/\(node)/disks/lvmthin")
    }

    public static func zfsPools(node: String) -> APIRequest<[ZFSPool]> {
        APIRequest(.get, "/nodes/\(node)/disks/zfs")
    }

    public static func zfsPoolStatus(node: String, name: String) -> APIRequest<ZFSPoolStatus> {
        APIRequest(.get, "/nodes/\(node)/disks/zfs/\(escapePath(name))")
    }

    public static func directoryMounts(node: String) -> APIRequest<[DirectoryMount]> {
        APIRequest(.get, "/nodes/\(node)/disks/directory")
    }

    /// Creates an LVM volume group, thin pool, ZFS pool or directory. Returns a task ID.
    public static func createDiskStorage(node: String, _ draft: DiskStorageDraft) -> APIRequest<String?> {
        APIRequest(.post, "/nodes/\(node)/disks/\(draft.kind.rawValue)", parameters: draft.parameters)
    }

    /// Removes an LVM volume group, ZFS pool or directory mount. `cleanupConfig` also removes the storage
    /// configured on it, `wipeDisks` the signatures on its disks. Returns a task ID.
    public static func deleteDiskStorage(node: String, kind: DiskStorageKind, name: String, volumeGroup: String? = nil, cleanupConfig: Bool, wipeDisks: Bool) -> APIRequest<String?> {
        var parameters: APIParameters = ["cleanup-config": .bool(cleanupConfig), "cleanup-disks": .bool(wipeDisks)]
        if let volumeGroup { parameters["volume-group"] = .string(volumeGroup) }
        return APIRequest(.delete, "/nodes/\(node)/disks/\(kind.rawValue)/\(escapePath(name))", parameters: parameters)
    }
}
