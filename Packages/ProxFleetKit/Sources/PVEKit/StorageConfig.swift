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
        case "iscsi", "iscsidirect": [values["portal"], values["target"]].compactMap { $0 }.joined(separator: " · ")
        case "zfs": [values["portal"], values["pool"]].compactMap { $0 }.joined(separator: " · ")
        case "rbd": [values["monhost"], values["pool"]].compactMap { $0 }.joined(separator: " · ")
        case "cephfs": values["monhost"] ?? values["fs-name"]
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

/// Storage types the app can create and edit, in the order of the web interface's Add menu. Others (iSCSI direct,
/// DRBD) are shown, but configured elsewhere.
public enum StorageBackend: String, CaseIterable, Sendable, Identifiable {
    case dir, lvm, lvmthin, btrfs, nfs, cifs, iscsi, cephfs, rbd
    /// ZFS over iSCSI.
    case zfs
    case zfspool, pbs, esxi

    public var id: String { rawValue }

    /// Content types the storage type supports, in the web interface's order.
    public var supportedContent: [StorageContentType] {
        switch self {
        case .dir, .nfs, .cifs, .btrfs: [.images, .rootdir, .iso, .vztmpl, .backup, .snippets, .import]
        case .cephfs: [.iso, .vztmpl, .backup, .snippets, .import]
        case .pbs: [.backup]
        case .lvm, .lvmthin, .zfspool, .rbd: [.images, .rootdir]
        case .iscsi, .zfs: [.images]
        case .esxi: [.import]
        }
    }

    /// The web interface's defaults for a new storage.
    public var defaultContent: Set<String> {
        switch self {
        case .dir, .nfs, .cifs, .btrfs: ["images", "iso", "vztmpl", "backup", "rootdir", "snippets"]
        case .cephfs, .pbs: ["backup"]
        case .lvm, .lvmthin, .zfspool: ["images", "rootdir"]
        case .rbd, .iscsi, .zfs: ["images"]
        case .esxi: ["import"]
        }
    }

    /// Whether the content types can be chosen; the others have fixed content or, for iSCSI, a LUN switch.
    public var hasContentChoice: Bool { ![.pbs, .iscsi, .zfs, .esxi].contains(self) }

    /// Network storages are the same on every node; the `shared` flag only applies to the others.
    public var isAlwaysShared: Bool { [.nfs, .cifs, .pbs, .iscsi, .cephfs, .rbd, .zfs, .esxi].contains(self) }
    public var canBeMarkedShared: Bool { self == .dir || self == .lvm }
    public var isOnNetwork: Bool { isAlwaysShared }
    /// Types whose images are files that qemu-img creates, which can be preallocated.
    public var supportsPreallocation: Bool { [.dir, .btrfs, .nfs, .cifs].contains(self) }
    /// Types that can keep snapshots of qcow2 images as a chain of volumes (a technology preview in PVE 9).
    public var supportsVolumeChainSnapshots: Bool { [.dir, .nfs, .cifs, .lvm].contains(self) }
    /// Ceph storages can use the cluster's own Ceph or an external one.
    public var isCeph: Bool { self == .cephfs || self == .rbd }
}

/// What to do with the client-side encryption key of a Proxmox Backup Server storage.
public enum PBSEncryptionMode: String, Sendable, CaseIterable, Identifiable {
    /// Keep the key as it is, or stay without one.
    case keep
    /// Back up without encryption; for an existing key this removes it.
    case none
    /// Let Proxmox generate a key, which it shows once.
    case autogenerate
    /// Use a key file of an earlier setup, as JSON.
    case upload

    public var id: String { rawValue }
}

/// iSCSI target implementations a ZFS over iSCSI storage can drive.
public enum ISCSIProvider: String, Sendable, CaseIterable, Identifiable {
    case comstar, istgt, iet
    case lio = "LIO"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .comstar: "Comstar"
        case .istgt: "istgt"
        case .iet: "IET"
        case .lio: "LIO"
        }
    }

    /// The write cache option exists for Comstar and istgt only.
    public var hasWriteCache: Bool { self == .comstar || self == .istgt }
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
    /// NFS and CIFS mount options other than the NFS version, comma-separated.
    public var mountOptions = ""
    /// NFS only: `3`, `4`, `4.1` or `4.2`, empty for the default. Kept in the mount options as `vers=`.
    public var nfsVersion = ""
    public var volumeGroup = ""
    public var thinPool = ""
    /// LVM on an iSCSI LUN: the LUN's volume, e.g. `san:0.0.1.scsi-…`; empty for an existing volume group.
    public var baseVolume = ""
    /// LVM: zero-out the data of removed volumes.
    public var wipesRemovedVolumes = false
    public var pool = ""
    public var sparse = false
    public var blockSize = ""
    /// `off`, `metadata`, `falloc` or `full`; empty for the default (metadata).
    public var preallocation = ""
    /// Snapshots of qcow2 images as a chain of volumes. Set when creating, except for LVM.
    public var volumeChainSnapshots = false
    /// iSCSI and ZFS over iSCSI.
    public var portal = ""
    public var target = ""
    /// iSCSI: offer the LUNs as VM disks. Without it, the storage only serves as the base of an LVM storage.
    public var usesLUNsDirectly = true
    /// Ceph: the cluster's own Ceph instead of an external one, which needs monitors and a key.
    public var usesClusterCeph = true
    /// Ceph monitors of an external cluster, space-separated.
    public var monitors = ""
    /// External Ceph: the keyring (RBD) or secret key (CephFS). Write-only.
    public var keyring = ""
    /// RBD: map images with the kernel module.
    public var usesKRBD = false
    /// CephFS: the file system, empty for the default one.
    public var fsName = ""
    /// ZFS over iSCSI.
    public var iscsiProvider: ISCSIProvider = .comstar
    public var writeCache = true
    public var comstarTargetGroup = ""
    public var comstarHostGroup = ""
    public var lioTargetPortalGroup = ""
    /// ESXi: accept the host's certificate without checking it.
    public var skipsCertificateVerification = false
    /// PBS: the fingerprint of the stored encryption key, or a marker that one exists; nil without a key.
    public private(set) var encryptionKeyInfo: String?
    public var encryptionMode: PBSEncryptionMode = .keep
    /// The key to use with `.upload`, as the JSON of a key file.
    public var encryptionKey = ""

    public static let nfsVersions = ["3", "4", "4.1", "4.2"]
    public static let preallocationModes = ["off", "metadata", "falloc", "full"]

    public init(type: StorageBackend) {
        self.type = type
        content = type.defaultContent
        if type.isCeph { username = "admin" }
        if type == .zfs { blockSize = "4k" }
        if type == .pbs { encryptionMode = .none }
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
        var options: [String] = []
        for option in (values["options"] ?? "").split(separator: ",").map(String.init) {
            if type == .nfs, option.hasPrefix("vers=") { nfsVersion = String(option.dropFirst(5)) } else { options.append(option) }
        }
        mountOptions = options.joined(separator: ",")
        volumeGroup = values["vgname"] ?? ""
        thinPool = values["thinpool"] ?? ""
        baseVolume = values["base"] ?? ""
        wipesRemovedVolumes = values["saferemove"] == "1"
        pool = values["pool"] ?? ""
        sparse = values["sparse"] == "1"
        blockSize = values["blocksize"] ?? ""
        preallocation = values["preallocation"] ?? ""
        volumeChainSnapshots = values["snapshot-as-volume-chain"] == "1"
        portal = values["portal"] ?? ""
        target = values["target"] ?? ""
        usesLUNsDirectly = config.content.contains("images")
        monitors = values["monhost"] ?? ""
        usesClusterCeph = monitors.isEmpty
        usesKRBD = values["krbd"] == "1"
        fsName = values["fs-name"] ?? ""
        iscsiProvider = values["iscsiprovider"].flatMap(ISCSIProvider.init) ?? .comstar
        writeCache = values["nowritecache"] != "1"
        comstarTargetGroup = values["comstar_tg"] ?? ""
        comstarHostGroup = values["comstar_hg"] ?? ""
        lioTargetPortalGroup = values["lio_tpg"] ?? ""
        skipsCertificateVerification = values["skip-cert-verification"] == "1"
        encryptionKeyInfo = values["encryption-key"]
        prune = PruneOptions(values["prune-backups"])
        maxProtectedBackups = values["max-protected-backups"] ?? ""
    }

    public var prune = PruneOptions()
    public var maxProtectedBackups = ""

    public var holdsBackups: Bool { content.contains("backup") }
    public var hasEncryptionKey: Bool { encryptionKeyInfo != nil }

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
        func flag(_ key: String, _ on: Bool) { set(key, on ? "1" : nil) }
        let order = type.supportedContent.map(\.rawValue)
        switch type {
        // Without LUNs used directly, an iSCSI storage holds nothing itself.
        case .iscsi: set("content", usesLUNsDirectly ? "images" : "none")
        case .zfs: set("content", "images")
        case .esxi: set("content", "import")
        default: set("content", order.filter(content.contains).joined(separator: ","))
        }
        set("nodes", nodes.isEmpty ? nil : nodes.sorted().joined(separator: ","))
        set("disable", isEnabled ? nil : "1")
        if type.canBeMarkedShared { flag("shared", isShared) }
        if type.supportedContent.contains(.backup) {
            set("prune-backups", holdsBackups ? prune.serialized : nil)
            set("max-protected-backups", holdsBackups ? Self.text(maxProtectedBackups) : nil)
        }
        if type.supportsPreallocation { set("preallocation", Self.text(preallocation)) }
        if type.supportsVolumeChainSnapshots { flag("snapshot-as-volume-chain", volumeChainSnapshots) }
        switch type {
        case .dir, .btrfs:
            set("path", Self.text(path))
        case .nfs:
            set("server", Self.text(server))
            set("export", Self.text(export))
            var options = mountOptions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // The version picker wins over a version typed into the options.
            if let version = Self.text(nfsVersion) {
                options.removeAll { $0.hasPrefix("vers=") }
                options.append("vers=\(version)")
            }
            set("options", options.isEmpty ? nil : options.joined(separator: ","))
        case .cifs:
            set("server", Self.text(server))
            set("share", Self.text(share))
            set("subdir", Self.text(subdir))
            set("domain", Self.text(domain))
            set("username", Self.text(username))
            set("smbversion", Self.text(smbVersion))
            set("options", Self.text(mountOptions))
        case .pbs:
            set("server", Self.text(server))
            set("datastore", Self.text(datastore))
            set("username", Self.text(username))
            set("namespace", Self.text(namespace))
            set("fingerprint", Self.text(fingerprint))
            set("port", Self.text(port))
        case .lvm:
            set("vgname", Self.text(volumeGroup))
            set("base", Self.text(baseVolume))
            flag("saferemove", wipesRemovedVolumes)
        case .lvmthin:
            set("vgname", Self.text(volumeGroup))
            set("thinpool", Self.text(thinPool))
        case .zfspool:
            set("pool", Self.text(pool))
            flag("sparse", sparse)
            set("blocksize", Self.text(blockSize))
        case .iscsi:
            set("portal", Self.text(portal))
            set("target", Self.text(target))
        case .cephfs:
            set("fs-name", Self.text(fsName))
            if !usesClusterCeph {
                set("monhost", Self.text(monitors))
                set("username", Self.text(username))
            }
        case .rbd:
            set("pool", Self.text(pool))
            flag("krbd", usesKRBD)
            set("namespace", Self.text(namespace))
            if !usesClusterCeph {
                set("monhost", Self.text(monitors))
                set("username", Self.text(username))
            }
        case .zfs:
            set("portal", Self.text(portal))
            set("pool", Self.text(pool))
            set("blocksize", Self.text(blockSize))
            set("target", Self.text(target))
            set("iscsiprovider", iscsiProvider.rawValue)
            flag("sparse", sparse)
            if iscsiProvider.hasWriteCache { flag("nowritecache", !writeCache) }
            if iscsiProvider == .comstar {
                set("comstar_tg", Self.text(comstarTargetGroup))
                set("comstar_hg", Self.text(comstarHostGroup))
            }
            if iscsiProvider == .lio { set("lio_tpg", Self.text(lioTargetPortalGroup)) }
        case .esxi:
            set("server", Self.text(server))
            set("port", Self.text(port))
            set("username", Self.text(username))
            flag("skip-cert-verification", skipsCertificateVerification)
        }
        return values
    }

    /// Settings `PUT /storage/{storage}` does not take, or that the web interface fixes once the storage exists.
    static let fixedKeys: Set<String> = [
        "path", "server", "export", "share", "datastore", "vgname", "thinpool", "pool", "base", "portal", "target",
        "iscsiprovider", "fs-name", "comstar_tg", "comstar_hg", "lio_tpg",
    ]

    /// Settings that are fixed for some types only.
    private func isFixed(_ key: String) -> Bool {
        if Self.fixedKeys.contains(key) { return true }
        switch key {
        // Only LVM storages can turn volume chains on or off later, as other types may already hold qcow2 images.
        case "snapshot-as-volume-chain": return type != .lvm
        case "blocksize": return type == .zfs
        case "username": return type.isCeph
        default: return false
        }
    }

    /// Parameters of `POST /storage`.
    var creationParameters: APIParameters {
        var parameters: APIParameters = ["storage": .string(storage.trimmingCharacters(in: .whitespaces)), "type": .string(type.rawValue)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value, !value.isEmpty { parameters[key] = .string(value) }
        }
        if let password = Self.text(password) { parameters["password"] = .string(password) }
        if type.isCeph, !usesClusterCeph, let keyring = keyringValue { parameters["keyring"] = .string(keyring) }
        if type == .pbs {
            switch encryptionMode {
            case .autogenerate: parameters["encryption-key"] = "autogen"
            case .upload: parameters["encryption-key"] = .string(encryptionKey.trimmingCharacters(in: .whitespacesAndNewlines))
            case .keep, .none: break
            }
        }
        return parameters
    }

    /// Keyrings span several lines; a CephFS secret is a single word.
    private var keyringValue: String? {
        let value = keyring.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The changes against the configuration the form was opened with. Empty when nothing changed.
    public func changes(from original: StorageConfigDraft) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let old = original.serialized()
        for (key, value) in serialized() where !isFixed(key) && value != (old[key] ?? nil) {
            update.set(key, value)
        }
        if let password = Self.text(password) { update.set("password", password) }
        if type.isCeph, !usesClusterCeph, let keyring = keyringValue { update.set("keyring", keyring) }
        if type == .pbs {
            switch encryptionMode {
            case .keep: break
            case .none: if hasEncryptionKey { update.set("encryption-key", nil) }
            case .autogenerate: update.set("encryption-key", "autogen")
            case .upload: update.set("encryption-key", encryptionKey.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
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
        if content.isEmpty, type.hasContentChoice {
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
            if encryptionMode == .upload {
                let key = encryptionKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let object = (try? JSONSerialization.jsonObject(with: Data(key.utf8))) as? [String: Any]
                if object?["data"] == nil { problems["encryption-key"] = String(localized: "Paste the content of a Proxmox Backup key file.") }
            }
        case .lvm:
            require("vgname", volumeGroup, String(localized: "Choose a volume group."))
        case .lvmthin:
            require("vgname", volumeGroup, String(localized: "Choose a volume group."))
            require("thinpool", thinPool, String(localized: "Choose a thin pool."))
        case .zfspool:
            require("pool", pool, String(localized: "Choose a ZFS pool."))
        case .iscsi:
            require("portal", portal, String(localized: "Enter the portal, e.g. 192.168.1.20."))
            require("target", target, String(localized: "Enter or scan the target."))
        case .cephfs, .rbd:
            if type == .rbd { require("pool", pool, String(localized: "Enter the pool.")) }
            if !usesClusterCeph {
                require("monhost", monitors, String(localized: "Enter the monitor addresses."))
                require("username", username, String(localized: "Enter the Ceph user, e.g. admin."))
                if isNew { require("keyring", keyring, type == .rbd ? String(localized: "Paste the keyring.") : String(localized: "Paste the secret key.")) }
            }
        case .zfs:
            require("portal", portal, String(localized: "Enter the portal, e.g. 192.168.1.20."))
            require("pool", pool, String(localized: "Enter the pool."))
            require("target", target, String(localized: "Enter the target."))
            require("blocksize", blockSize, String(localized: "Enter the block size, e.g. 4k."))
        case .esxi:
            require("server", server, String(localized: "Enter the server address."))
            require("username", username, String(localized: "Enter the user, e.g. root."))
            if isNew { require("password", password, String(localized: "Enter the password.")) }
        }
        if let port = Self.text(port), !(Int(port).map { (1...65535).contains($0) } ?? false) {
            problems["port"] = String(localized: "Enter a port from 1 to 65535.")
        }
        return problems
    }
}

/// `POST /storage` and `PUT /storage/{storage}`: the storage and settings the server generated, such as a PBS
/// encryption key.
public struct StorageChangeResult: Decodable, Sendable, Equatable {
    public var storage: String?
    /// The key Proxmox generated for an encrypted PBS storage. It is shown only this once.
    public var encryptionKey: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        storage = container.lossyString(AnyCodingKey("storage"))
        let config = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("config"))
        encryptionKey = config?.lossyString(AnyCodingKey("encryption-key"))
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
        // Thin pool results carry their volume group too, so `lv` comes before `vg`; Ceph pools have a numeric `pool`.
        name = ["path", "share", "store", "target", "lv", "vg", "pool_name", "pool", "name"].lazy.compactMap { container.lossyString(AnyCodingKey($0)) }.first ?? ""
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

    public static func createStorage(_ draft: StorageConfigDraft) -> APIRequest<StorageChangeResult?> {
        APIRequest(.post, "/storage", parameters: draft.creationParameters)
    }

    public static func updateStorage(_ storage: String, _ update: GuestConfigUpdate) -> APIRequest<StorageChangeResult?> {
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

    /// iSCSI targets a portal offers.
    public static func scanISCSI(node: String, portal: String) -> APIRequest<[StorageScanResult]> {
        APIRequest(.get, "/nodes/\(node)/scan/iscsi", parameters: ["portal": .string(portal)])
    }

    /// Pools of the cluster's own Ceph; fails when Ceph is not set up.
    public static func cephPools(node: String) -> APIRequest<[StorageScanResult]> {
        APIRequest(.get, "/nodes/\(node)/ceph/pool")
    }

    /// File systems of the cluster's own Ceph.
    public static func cephFilesystems(node: String) -> APIRequest<[StorageScanResult]> {
        APIRequest(.get, "/nodes/\(node)/ceph/fs")
    }
}
