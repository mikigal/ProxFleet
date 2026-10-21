import Foundation
import ProxmoxCore

/// A change to a guest configuration: keys to set, keys to delete and pending changes to revert.
public struct GuestConfigUpdate: Sendable, Equatable {
    public var values: [String: String] = [:]
    public var deletions: Set<String> = []
    public var reverts: Set<String> = []
    /// Digest of the configuration the change is based on. The server rejects the update if it changed since.
    public var digest: String?

    public init(digest: String? = nil) {
        self.digest = digest
    }

    public var isEmpty: Bool { values.isEmpty && deletions.isEmpty && reverts.isEmpty }

    /// Sets a key, or deletes it when `value` is nil.
    public mutating func set(_ key: String, _ value: String?) {
        if let value {
            values[key] = value
            deletions.remove(key)
        } else {
            values[key] = nil
            deletions.insert(key)
        }
    }

    public mutating func set(_ key: String, _ flag: Bool) {
        set(key, flag ? "1" : "0")
    }

    var parameters: APIParameters {
        var parameters = APIParameters()
        for key in values.keys.sorted() {
            parameters[key] = .string(values[key]!)
        }
        if !deletions.isEmpty { parameters["delete"] = .string(deletions.sorted().joined(separator: ",")) }
        if !reverts.isEmpty { parameters["revert"] = .string(reverts.sorted().joined(separator: ",")) }
        if let digest { parameters["digest"] = .string(digest) }
        return parameters
    }
}

/// One entry of `GET .../pending`: a configuration key, with its pending value or deletion if any.
public struct PendingConfigItem: Decodable, Sendable, Equatable, Identifiable {
    public var key: String
    public var value: String?
    public var pending: String?
    public var isPendingDeletion: Bool

    public var id: String { key }
    /// True when the change waits for the next restart.
    public var hasPendingChange: Bool { pending != nil || isPendingDeletion }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        key = container.lossyString(AnyCodingKey("key")) ?? ""
        value = container.lossyString(AnyCodingKey("value"))
        pending = container.lossyString(AnyCodingKey("pending"))
        isPendingDeletion = (container.lossyInt(AnyCodingKey("delete")) ?? 0) > 0
    }
}

/// A storage of a node, from `GET /nodes/{node}/storage`.
public struct StorageInfo: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public var storage: String
    public var type: String
    public var content: [String]
    public var isActive: Bool
    public var isShared: Bool
    public var available: Int64?
    public var total: Int64?

    public var id: String { storage }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        storage = container.lossyString(AnyCodingKey("storage")) ?? ""
        type = container.lossyString(AnyCodingKey("type")) ?? ""
        content = container.lossyString(AnyCodingKey("content"))?.split(separator: ",").map(String.init) ?? []
        isActive = container.lossyBool(AnyCodingKey("active")) ?? false
        isShared = container.lossyBool(AnyCodingKey("shared")) ?? false
        available = container.lossyDouble(AnyCodingKey("avail")).map { Int64($0) }
        total = container.lossyDouble(AnyCodingKey("total")).map { Int64($0) }
    }
}

/// A volume on a storage, e.g. an ISO image.
public struct StorageVolume: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public var volumeID: String
    public var size: Int64?

    public var id: String { volumeID }
    /// The file name without the storage prefix: `local:iso/x.iso` → `x.iso`.
    public var fileName: String {
        volumeID.split(separator: "/").last.map(String.init) ?? volumeID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        volumeID = container.lossyString(AnyCodingKey("volid")) ?? ""
        size = container.lossyDouble(AnyCodingKey("size")).map { Int64($0) }
    }
}

/// A network interface of a node; only bridges are requested.
public struct NodeNetworkInterface: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public var name: String
    public var type: String
    public var comment: String?

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("iface")) ?? ""
        type = container.lossyString(AnyCodingKey("type")) ?? ""
        comment = container.lossyString(AnyCodingKey("comments"))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A CPU model QEMU offers on a node.
public struct CPUModel: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public var name: String
    public var vendor: String?
    public var isCustom: Bool

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        vendor = container.lossyString(AnyCodingKey("vendor"))
        isCustom = container.lossyBool(AnyCodingKey("custom")) ?? false
    }
}

extension PVE {
    /// VMs update asynchronously and return a task ID; containers update synchronously and return nothing.
    public static func updateConfig(_ guest: GuestReference, _ update: GuestConfigUpdate) -> APIRequest<String?> {
        APIRequest(guest.kind == .virtualMachine ? .post : .put, guest.path + "/config", parameters: update.parameters)
    }

    /// Grows a disk. `size` is absolute (`32G`) or relative (`+8G`). Returns a task ID.
    public static func resizeDisk(_ guest: GuestReference, disk: String, size: String) -> APIRequest<String?> {
        APIRequest(.put, guest.path + "/resize", parameters: ["disk": .string(disk), "size": .string(size)])
    }

    public static func pendingConfig(_ guest: GuestReference) -> APIRequest<[PendingConfigItem]> {
        APIRequest(.get, guest.path + "/pending")
    }

    public static func storages(node: String, content: String) -> APIRequest<[StorageInfo]> {
        APIRequest(.get, "/nodes/\(node)/storage", parameters: ["content": .string(content), "enabled": true])
    }

    public static func storageContent(node: String, storage: String, content: String) -> APIRequest<[StorageVolume]> {
        APIRequest(.get, "/nodes/\(node)/storage/\(storage)/content", parameters: ["content": .string(content)])
    }

    public static func bridges(node: String) -> APIRequest<[NodeNetworkInterface]> {
        APIRequest(.get, "/nodes/\(node)/network", parameters: ["type": "any_bridge"])
    }

    public static func cpuModels(node: String) -> APIRequest<[CPUModel]> {
        APIRequest(.get, "/nodes/\(node)/capabilities/qemu/cpu")
    }
}
