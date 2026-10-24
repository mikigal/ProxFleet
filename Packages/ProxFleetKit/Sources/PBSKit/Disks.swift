import Foundation
import ProxmoxCore

/// A disk of the backup server with its partitions, from `GET /nodes/localhost/disks/list`. Unlike Proxmox VE, the
/// partitions come nested under their disk.
public struct BackupServerDisk: Decodable, Sendable, Equatable, Identifiable {
    public struct Partition: Decodable, Sendable, Equatable, Identifiable {
        public var name: String
        public var devicePath: String
        public var size: Int64
        /// `filesystem`, `lvm`, `zfs`, `bios`, `efi`, `mounted`…
        public var usage: String?
        public var fileSystem: String?
        /// The file system's UUID, which removable datastores are found by.
        public var uuid: String?
        public var isMounted: Bool

        public var id: String { devicePath }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            name = container.lossyString(AnyCodingKey("name")) ?? ""
            devicePath = container.lossyString(AnyCodingKey("devpath")) ?? ""
            size = container.int64("size") ?? 0
            usage = container.lossyString(AnyCodingKey("used"))
            fileSystem = container.lossyString(AnyCodingKey("filesystem"))
            uuid = container.lossyString(AnyCodingKey("uuid"))
            isMounted = container.lossyBool(AnyCodingKey("mounted")) ?? false
        }
    }

    public var name: String
    public var devicePath: String
    public var model: String?
    public var vendor: String?
    public var serial: String?
    public var size: Int64
    /// `hdd`, `ssd`, `usb` or `unknown`.
    public var kind: String?
    /// `unused`, `mounted`, `partitions`, `zfs`, `lvm`, `filesystem`…
    public var usage: String?
    public var health: String?
    public var wearout: Double?
    public var hasGPT: Bool
    public var partitions: [Partition]

    public var id: String { devicePath }
    public var isUnused: Bool { usage == "unused" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        devicePath = container.lossyString(AnyCodingKey("devpath")) ?? ""
        model = container.lossyString(AnyCodingKey("model"))
        vendor = container.lossyString(AnyCodingKey("vendor"))
        serial = container.lossyString(AnyCodingKey("serial"))
        size = container.int64("size") ?? 0
        kind = container.lossyString(AnyCodingKey("disk-type"))
        usage = container.lossyString(AnyCodingKey("used"))
        health = container.lossyString(AnyCodingKey("status"))
        wearout = container.lossyDouble(AnyCodingKey("wearout"))
        hasGPT = container.lossyBool(AnyCodingKey("gpt")) ?? false
        partitions = (try? container.decodeIfPresent([Partition].self, forKey: AnyCodingKey("partitions"))) ?? []
    }

    /// Partitions with a file system and UUID, which can hold a removable datastore, as the web interface offers them.
    public var datastorePartitions: [Partition] {
        partitions.filter { $0.usage == "filesystem" && $0.uuid != nil }
    }
}

extension PBS {
    public static func disks(includePartitions: Bool = true, skipSMART: Bool = true) -> APIRequest<[BackupServerDisk]> {
        var parameters = APIParameters()
        if includePartitions { parameters["include-partitions"] = true }
        if skipSMART { parameters["skipsmart"] = true }
        return APIRequest(.get, "/nodes/\(node)/disks/list", parameters: parameters)
    }
}
