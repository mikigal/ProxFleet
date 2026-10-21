import Foundation
import ProxmoxCore

/// One entry of `GET /storage`: a storage definition of the datacenter, as stored in `storage.cfg`.
public struct StorageConfig: Decodable, Sendable, Equatable, Identifiable {
    public var storage: String
    public var type: String
    /// Every setting as text, by the names the API uses.
    public var values: [String: String]
    public var digest: String?

    public var id: String { storage }
    public var content: [String] { list("content", separator: ",") }
    /// Empty when the storage is available on all nodes.
    public var nodes: [String] { list("nodes", separator: ",") }
    public var isDisabled: Bool { values["disable"] == "1" }
    public var isShared: Bool { values["shared"] == "1" || StorageBackend(rawValue: type)?.isAlwaysShared == true }

    /// Where the data lives, for a list: a path, `server:/export`, `//server/share`, a volume group…
    public var location: String? {
        switch type {
        case "dir", "btrfs": values["path"]
        case "nfs": [values["server"], values["export"]].compactMap { $0 }.joined(separator: ":")
        case "cifs": "//" + [values["server"], values["share"]].compactMap { $0 }.joined(separator: "/")
        case "pbs": [values["server"], values["datastore"]].compactMap { $0 }.joined(separator: " · ")
        case "lvm": values["vgname"]
        case "lvmthin": [values["vgname"], values["thinpool"]].compactMap { $0 }.joined(separator: "/")
        case "zfspool": values["pool"]
        default: values["server"] ?? values["path"] ?? values["pool"]
        }
    }

    private func list(_ key: String, separator: Character) -> [String] {
        (values[key] ?? "").split(separator: separator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: String] = [:]
        for key in container.allKeys {
            if let text = container.lossyString(key) {
                values[key.stringValue] = text
            } else if let flag = container.lossyBool(key) {
                values[key.stringValue] = flag ? "1" : "0"
            }
        }
        storage = values.removeValue(forKey: "storage") ?? ""
        type = values.removeValue(forKey: "type") ?? ""
        digest = values.removeValue(forKey: "digest")
        self.values = values
    }
}

/// Storage types the app can create and edit. Others (Ceph, iSCSI, ESXi) are shown, but configured in the web interface.
public enum StorageBackend: String, CaseIterable, Sendable, Identifiable {
    case dir, nfs, cifs, pbs, lvm, lvmthin, zfspool, btrfs

    public var id: String { rawValue }

    /// Content types the storage type supports, in the web interface's order.
    public var supportedContent: [StorageContentType] {
        switch self {
        case .dir, .nfs, .cifs, .btrfs: [.images, .rootdir, .iso, .vztmpl, .backup, .snippets, .import]
        case .pbs: [.backup]
        case .lvm, .lvmthin, .zfspool: [.images, .rootdir]
        }
    }

    /// The web interface's defaults for a new storage.
    public var defaultContent: Set<String> {
        switch self {
        case .dir, .nfs, .cifs, .btrfs: ["images", "iso", "vztmpl", "backup", "rootdir", "snippets"]
        case .pbs: ["backup"]
        case .lvm, .lvmthin, .zfspool: ["images", "rootdir"]
        }
    }

    /// Network storages are the same on every node; the `shared` flag only applies to the others.
    public var isAlwaysShared: Bool { self == .nfs || self == .cifs || self == .pbs }
    public var canBeMarkedShared: Bool { self == .dir || self == .lvm }
    public var isOnNetwork: Bool { isAlwaysShared }
}

/// Backup retention (`prune-backups`): how many backups of each kind to keep. Empty fields keep none of that kind.
public struct PruneOptions: Equatable, Sendable {
    public static let keys = ["keep-last", "keep-hourly", "keep-daily", "keep-weekly", "keep-monthly", "keep-yearly"]

    public var keepAll = false
    /// Counts by key, e.g. `keep-daily` → `7`. Text so fields can be empty.
    public var counts: [String: String] = [:]

    public init() {}

    public init(_ text: String?) {
        let property = PropertyString(parsing: text ?? "")
        keepAll = property["keep-all"] == "1"
        for key in Self.keys {
            if let value = property[key] { counts[key] = value }
        }
    }

    /// nil when nothing is set, which means the storage keeps every backup.
    public var serialized: String? {
        if keepAll { return "keep-all=1" }
        let parts = Self.keys.compactMap { key -> String? in
            guard let value = counts[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return "\(key)=\(value)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    public var problems: [String: String] {
        let invalid = Self.keys.contains { key in
            guard let value = counts[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return false }
            return Int(value).map { $0 < 1 } ?? true
        }
        return invalid ? ["prune-backups": String(localized: "Use whole numbers of 1 or more, or leave fields empty.")] : [:]
    }
}

/// The settings of a storage as a form. Like `OptionsDraft`, the draft and the configuration it came from serialize
/// the same way, so an update sends only what changed, and `delete` for what was cleared.
public struct StorageConfigDraft: Equatable, Sendable {
    public var type: StorageBackend
    public var storage = ""
    public var content: Set<String>
    /// Empty for all nodes.
    public var nodes: Set<String> = []
    public var isEnabled = true
    public var isShared = false
    public var path = ""
    public var server = ""
    public var export = ""
    public var share = ""
    public var subdir = ""
    public var domain = ""
    public var smbVersion = ""
    public var username = ""
    /// Write-only: empty keeps the stored password.
    public var password = ""
    public var datastore = ""
    public var namespace = ""
    public var fingerprint = ""
    public var port = ""
    public var mountOptions = ""
    public var volumeGroup = ""
    public var thinPool = ""
    public var pool = ""
    public var sparse = false
    public var blockSize = ""
    public var prune = PruneOptions()
    public var maxProtectedBackups = ""

    public init(type: StorageBackend) {
        self.type = type
        content = type.defaultContent
    }

    public init?(_ config: StorageConfig) {
        guard let type = StorageBackend(rawValue: config.type) else { return nil }
        self.type = type
        let values = config.values
        storage = config.storage
        content = Set(config.content)
        nodes = Set(config.nodes)
        isEnabled = !config.isDisabled
        isShared = values["shared"] == "1"
        path = values["path"] ?? ""
        server = values["server"] ?? ""
        export = values["export"] ?? ""
        share = values["share"] ?? ""
        subdir = values["subdir"] ?? ""
        domain = values["domain"] ?? ""
        smbVersion = values["smbversion"] ?? ""
        username = values["username"] ?? ""
        datastore = values["datastore"] ?? ""
        namespace = values["namespace"] ?? ""
        fingerprint = values["fingerprint"] ?? ""
        port = values["port"] ?? ""
        mountOptions = values["options"] ?? ""
        volumeGroup = values["vgname"] ?? ""
        thinPool = values["thinpool"] ?? ""
        pool = values["pool"] ?? ""
        sparse = values["sparse"] == "1"
        blockSize = values["blocksize"] ?? ""
        prune = PruneOptions(values["prune-backups"])
        maxProtectedBackups = values["max-protected-backups"] ?? ""
    }

    public var holdsBackups: Bool { content.contains("backup") }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The settings this form manages; nil means "not set". Connection settings that cannot change after
    /// creation (path, server, pool…) are included too, but the editor shows them read-only.
    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        // updateValue keeps nil values, which mark settings to delete; assigning nil would drop the key.
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        let order = type.supportedContent.map(\.rawValue)
        set("content", order.filter(content.contains).joined(separator: ","))
        set("nodes", nodes.isEmpty ? nil : nodes.sorted().joined(separator: ","))
        set("disable", isEnabled ? nil : "1")
        if type.canBeMarkedShared { set("shared", isShared ? "1" : nil) }
        if type.supportedContent.contains(.backup) {
            set("prune-backups", holdsBackups ? prune.serialized : nil)
            set("max-protected-backups", holdsBackups ? Self.text(maxProtectedBackups) : nil)
        }
        switch type {
        case .dir, .btrfs:
            set("path", Self.text(path))
        case .nfs:
            set("server", Self.text(server))
            set("export", Self.text(export))
            set("options", Self.text(mountOptions))
        case .cifs:
            set("server", Self.text(server))
            set("share", Self.text(share))
            set("subdir", Self.text(subdir))
            set("domain", Self.text(domain))
            set("username", Self.text(username))
            set("smbversion", Self.text(smbVersion))
        case .pbs:
            set("server", Self.text(server))
            set("datastore", Self.text(datastore))
            set("username", Self.text(username))
            set("namespace", Self.text(namespace))
            set("fingerprint", Self.text(fingerprint))
            set("port", Self.text(port))
        case .lvm:
            set("vgname", Self.text(volumeGroup))
        case .lvmthin:
            set("vgname", Self.text(volumeGroup))
            set("thinpool", Self.text(thinPool))
        case .zfspool:
            set("pool", Self.text(pool))
            set("sparse", sparse ? "1" : nil)
            set("blocksize", Self.text(blockSize))
        }
        return values
    }

    /// Settings `PUT /storage/{storage}` does not take, as they are fixed once the storage exists.
    static let fixedKeys: Set<String> = ["path", "server", "export", "share", "datastore", "vgname", "thinpool", "pool"]

    /// Parameters of `POST /storage`.
    var creationParameters: APIParameters {
        var parameters: APIParameters = ["storage": .string(storage.trimmingCharacters(in: .whitespaces)), "type": .string(type.rawValue)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value, !value.isEmpty { parameters[key] = .string(value) }
        }
        if let password = Self.text(password) { parameters["password"] = .string(password) }
        return parameters
    }

    /// The changes against the configuration the form was opened with. Empty when nothing changed.
    public func changes(from original: StorageConfigDraft) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let old = original.serialized()
        for (key, value) in serialized() where !Self.fixedKeys.contains(key) && value != (old[key] ?? nil) {
            update.set(key, value)
        }
        if let password = Self.text(password) { update.set("password", password) }
        return update
    }

    /// Problems the app can see itself, by parameter name as the server reports them.
    public func problems(isNew: Bool) -> [String: String] {
        var problems = prune.problems
        if isNew {
            let id = storage.trimmingCharacters(in: .whitespaces)
            if id.isEmpty {
                problems["storage"] = String(localized: "Enter an ID.")
            } else if !(id.first?.isLetter ?? false) || id.contains(where: { !($0.isLetter || $0.isNumber || "-_.".contains($0)) }) {
                problems["storage"] = String(localized: "Start with a letter; use letters, digits, and - _ . only.")
            }
        }
        if content.isEmpty, type != .pbs {
            problems["content"] = String(localized: "Choose at least one content type.")
        }
        func require(_ key: String, _ value: String, _ message: String) {
            if Self.text(value) == nil { problems[key] = message }
        }
        switch type {
        case .dir, .btrfs:
            require("path", path, String(localized: "Enter the directory path."))
            if let path = Self.text(path), !path.hasPrefix("/") { problems["path"] = String(localized: "Use an absolute path, starting with /.") }
        case .nfs:
            require("server", server, String(localized: "Enter the server address."))
            require("export", export, String(localized: "Enter or scan the export path."))
        case .cifs:
            require("server", server, String(localized: "Enter the server address."))
            require("share", share, String(localized: "Enter or scan the share."))
        case .pbs:
            require("server", server, String(localized: "Enter the server address."))
            require("datastore", datastore, String(localized: "Enter or scan the datastore."))
            require("username", username, String(localized: "Enter a user, e.g. backup@pbs."))
            if isNew { require("password", password, String(localized: "Enter the password or API token secret.")) }
            if let fingerprint = Self.text(fingerprint),
               fingerprint.split(separator: ":").count != 32 || !fingerprint.allSatisfy({ $0.isHexDigit || $0 == ":" }) {
                problems["fingerprint"] = String(localized: "A fingerprint is 32 hexadecimal pairs separated by colons.")
            }
        case .lvm:
            require("vgname", volumeGroup, String(localized: "Choose a volume group."))
        case .lvmthin:
            require("vgname", volumeGroup, String(localized: "Choose a volume group."))
            require("thinpool", thinPool, String(localized: "Choose a thin pool."))
        case .zfspool:
            require("pool", pool, String(localized: "Choose a ZFS pool."))
        }
        if let port = Self.text(port), !(Int(port).map { (1...65535).contains($0) } ?? false) {
            problems["port"] = String(localized: "Enter a port from 1 to 65535.")
        }
        return problems
    }
}

/// Results of the `scan` endpoints, which list what a server or the node offers for a new storage.
public struct StorageScanResult: Decodable, Sendable, Equatable, Identifiable, Hashable {
    /// The value to use: an NFS export, SMB share, PBS datastore, volume group, thin pool or ZFS pool.
    public var name: String
    public var detail: String?

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        // Thin pool results carry their volume group too, so `lv` comes before `vg`.
        name = ["path", "share", "store", "lv", "vg", "pool"].lazy.compactMap { container.lossyString(AnyCodingKey($0)) }.first ?? ""
        let size = container.lossyDouble(AnyCodingKey("size")) ?? container.lossyDouble(AnyCodingKey("lv_size"))
        detail = container.lossyString(AnyCodingKey("description"))?.nilIfEmpty
            ?? container.lossyString(AnyCodingKey("comment"))?.nilIfEmpty
            ?? container.lossyString(AnyCodingKey("options"))?.nilIfEmpty
            ?? size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .binary) }
    }
}

extension PVE {
    public static func storageConfigs() -> APIRequest<[StorageConfig]> {
        APIRequest(.get, "/storage")
    }

    public static func storageConfig(_ storage: String) -> APIRequest<StorageConfig> {
        APIRequest(.get, "/storage/\(escapePath(storage))")
    }

    public static func createStorage(_ draft: StorageConfigDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/storage", parameters: draft.creationParameters)
    }

    public static func updateStorage(_ storage: String, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/storage/\(escapePath(storage))", parameters: update.parameters)
    }

    /// Removes the storage definition. The data on it stays.
    public static func deleteStorage(_ storage: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/storage/\(escapePath(storage))")
    }

    public static func scanNFS(node: String, server: String) -> APIRequest<[StorageScanResult]> {
        APIRequest(.get, "/nodes/\(node)/scan/nfs", parameters: ["server": .string(server)])
    }

    public static func scanCIFS(node: String, server: String, username: String?, password: String?, domain: String?) -> APIRequest<[StorageScanResult]> {
        var parameters: APIParameters = ["server": .string(server)]
        if let username, !username.isEmpty { parameters["username"] = .string(username) }
        if let password, !password.isEmpty { parameters["password"] = .string(password) }
        if let domain, !domain.isEmpty { parameters["domain"] = .string(domain) }
        return APIRequest(.get, "/nodes/\(node)/scan/cifs", parameters: parameters)
    }

    public static func scanPBS(node: String, server: String, username: String, password: String, fingerprint: String?, port: Int?) -> APIRequest<[StorageScanResult]> {
        var parameters: APIParameters = ["server": .string(server), "username": .string(username), "password": .string(password)]
        if let fingerprint, !fingerprint.isEmpty { parameters["fingerprint"] = .string(fingerprint) }
        if let port { parameters["port"] = .int(port) }
        return APIRequest(.get, "/nodes/\(node)/scan/pbs", parameters: parameters)
    }

    public static func scanVolumeGroups(node: String) -> APIRequest<[StorageScanResult]> {
        APIRequest(.get, "/nodes/\(node)/scan/lvm")
    }

    public static func scanThinPools(node: String, volumeGroup: String) -> APIRequest<[StorageScanResult]> {
        APIRequest(.get, "/nodes/\(node)/scan/lvmthin", parameters: ["vg": .string(volumeGroup)])
    }

    public static func scanZFSPools(node: String) -> APIRequest<[StorageScanResult]> {
        APIRequest(.get, "/nodes/\(node)/scan/zfs")
    }
}
