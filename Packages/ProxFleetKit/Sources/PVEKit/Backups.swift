import Foundation
import ProxmoxCore

/// A backup archive on a storage, from `GET /nodes/{node}/storage/{storage}/content?content=backup`.
public struct BackupVolume: Decodable, Sendable, Equatable, Hashable, Identifiable {
    /// For example `local:backup/vzdump-lxc-202-2026_10_21-15_08_45.tar.zst`.
    public var volumeID: String
    public var date: Date?
    public var size: Int64?
    public var notes: String
    public var isProtected: Bool
    /// `tar.zst`, `vma.zst`…
    public var format: String?
    public var vmid: Int?
    /// `qemu` or `lxc`.
    public var subtype: String?
    public var isEncrypted: Bool

    public var id: String { volumeID }
    /// Backups on a Proxmox Backup Server, which VMs can be restored from while they already run.
    public var isOnBackupServer: Bool { format?.hasPrefix("pbs-") ?? false }
    /// The storage, from the part of the volume ID before the colon.
    public var storage: String { String(volumeID.prefix { $0 != ":" }) }
    public var fileName: String { volumeID.split(separator: "/").last.map(String.init) ?? volumeID }

    public init(volumeID: String, date: Date? = nil, size: Int64? = nil, notes: String = "", isProtected: Bool = false, format: String? = nil, vmid: Int? = nil, subtype: String? = nil) {
        self.volumeID = volumeID
        self.date = date
        self.size = size
        self.notes = notes
        self.isProtected = isProtected
        self.format = format
        self.vmid = vmid
        self.subtype = subtype
        isEncrypted = false
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        volumeID = container.lossyString(AnyCodingKey("volid")) ?? ""
        date = container.lossyDouble(AnyCodingKey("ctime")).map { Date(timeIntervalSince1970: $0) }
        size = (container.lossyDouble(AnyCodingKey("size")) ?? container.lossyDouble(AnyCodingKey("approximate-size"))).map { Int64($0) }
        notes = (container.lossyString(AnyCodingKey("notes")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        isProtected = container.lossyBool(AnyCodingKey("protected")) ?? false
        format = container.lossyString(AnyCodingKey("format"))
        vmid = container.lossyInt(AnyCodingKey("vmid"))
        subtype = container.lossyString(AnyCodingKey("subtype"))
        isEncrypted = container.lossyString(AnyCodingKey("encrypted")).map { !$0.isEmpty && $0 != "0" } ?? false
    }
}

public enum BackupMode: String, Sendable, CaseIterable, Identifiable {
    /// The guest keeps running; VMs need nothing else, containers need storage with snapshots.
    case snapshot
    /// Containers are suspended briefly; VMs are paused while the backup starts.
    case suspend
    /// The guest is shut down for the backup and started again afterwards.
    case stop

    public var id: String { rawValue }
}

public enum BackupCompression: String, Sendable, CaseIterable, Identifiable {
    case zstd
    case gzip
    case lzo
    case none = "0"

    public var id: String { rawValue }
}

/// Settings of a manual backup, like the web interface's Backup Now dialog.
public struct BackupDraft: Sendable, Equatable {
    public let guest: GuestReference
    public var storage = ""
    public var mode: BackupMode = .snapshot
    public var compression: BackupCompression = .zstd
    /// Notes for the backup; `{{guestname}}`, `{{vmid}}`, `{{node}}` and `{{cluster}}` are filled in by the server.
    public var notes = "{{guestname}}"
    public var isProtected = false
    /// Removes older backups of the guest by the storage's retention settings afterwards.
    public var prunes = false
    /// Mail with sendmail instead of the datacenter's notification targets and matchers.
    public var usesLegacySendmail = false
    public var mailto = ""
    /// False before PVE 8.1, see `useSendmailOnly()`.
    public private(set) var hasNotificationSystem = true

    public init(guest: GuestReference) {
        self.guest = guest
    }

    /// Before PVE 8.1 there are no notification targets and no `notification-mode`: backups mail with sendmail,
    /// and only when recipients are given.
    public mutating func useSendmailOnly() {
        hasNotificationSystem = false
        usesLegacySendmail = true
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if storage.isEmpty { problems["storage"] = String(localized: "Choose a storage.") }
        if usesLegacySendmail, hasNotificationSystem, mailto.trimmingCharacters(in: .whitespaces).isEmpty {
            problems["mailto"] = String(localized: "Enter at least one recipient.")
        }
        return problems
    }

    public var parameters: APIParameters {
        var parameters: APIParameters = [
            "vmid": .int(guest.vmid), "storage": .string(storage), "mode": .string(mode.rawValue), "compress": .string(compression.rawValue),
            // Without Prune, a manual backup must not remove older ones by the storage's retention settings.
            "remove": .bool(prunes),
        ]
        if hasNotificationSystem { parameters["notification-mode"] = .string(usesLegacySendmail ? "legacy-sendmail" : "notification-system") }
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parameters["notes-template"] = .string(notes) }
        if isProtected { parameters["protected"] = true }
        let recipients = mailto.trimmingCharacters(in: .whitespaces)
        if usesLegacySendmail, !recipients.isEmpty { parameters["mailto"] = .string(recipients) }
        return parameters
    }
}

/// Restoring a backup, either over the guest it came from or as a new guest.
public struct RestoreDraft: Sendable, Equatable {
    public let backup: BackupVolume
    /// The guest the backup belongs to; its node is where the restore runs.
    public let source: GuestReference
    /// Replaces the source guest instead of creating a new one. Its disks are deleted first.
    public var overwrites = true
    /// ID of the new guest when not overwriting.
    public var vmid = 0
    /// Empty to use the storages in the backup's configuration. Containers need one: Proxmox would otherwise
    /// pick `local`, which usually cannot hold container volumes.
    public var storage = ""
    public var uniqueMACAddresses = false
    public var startAfterRestore = false
    /// VMs from a Proxmox Backup Server: start right away while the disks are restored in the background.
    public var liveRestore = false
    /// Adds the restored guest to high availability.
    public var isHAManaged = false
    /// MiB/s; 0 turns off all limits, nil uses the restore limit of the storage or datacenter.
    public var bandwidthLimit: Double?
    /// Overrides of the backup's configuration, empty or nil to keep its values.
    public var name = ""
    public var cores: Int?
    /// VMs only.
    public var sockets: Int?
    public var memoryMiB: Int?
    /// Containers: true or false to change the privilege level, nil to keep the backup's.
    public var unprivileged: Bool?
    /// Whether the source guest is running, which rules out overwriting it.
    public var sourceIsRunning = false

    public init(backup: BackupVolume, source: GuestReference) {
        self.backup = backup
        self.source = source
    }

    /// The guest the restore creates or replaces.
    public var target: GuestReference {
        GuestReference(node: source.node, vmid: overwrites ? source.vmid : vmid, kind: source.kind)
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if overwrites, sourceIsRunning { problems["force"] = String(localized: "Stop the guest before restoring over it.") }
        if !overwrites, !(100...999_999_999).contains(vmid) { problems["vmid"] = String(localized: "Use a number from 100 to 999999999.") }
        if source.kind == .container, storage.isEmpty { problems["storage"] = String(localized: "Choose a storage.") }
        if !name.isEmpty, !VMCreationDraft.isValidDNSName(name) {
            problems[source.kind == .virtualMachine ? "name" : "hostname"] = String(localized: "Use letters, digits, hyphens and dots only.")
        }
        if let cores, !(1...128).contains(cores) { problems["cores"] = String(localized: "Use 1 to 128 cores.") }
        if let sockets, !(1...4).contains(sockets) { problems["sockets"] = String(localized: "Use 1 to 4 sockets.") }
        if let memoryMiB, memoryMiB < 16 { problems["memory"] = String(localized: "Use at least 16 MiB.") }
        if let bandwidthLimit, bandwidthLimit < 0 { problems["bwlimit"] = String(localized: "Enter 0 or more.") }
        return problems
    }

    public var parameters: APIParameters {
        var parameters: APIParameters = ["vmid": .int(target.vmid)]
        switch source.kind {
        case .virtualMachine:
            parameters["archive"] = .string(backup.volumeID)
        case .container:
            parameters["ostemplate"] = .string(backup.volumeID)
            parameters["restore"] = true
        }
        if overwrites { parameters["force"] = true }
        if !storage.isEmpty { parameters["storage"] = .string(storage) }
        if uniqueMACAddresses { parameters["unique"] = true }
        let isLive = liveRestore && source.kind == .virtualMachine && backup.isOnBackupServer
        // A live restore starts the VM by itself.
        if isLive {
            parameters["live-restore"] = true
        } else if startAfterRestore {
            parameters["start"] = true
        }
        if isHAManaged { parameters["ha-managed"] = true }
        if let bandwidthLimit { parameters["bwlimit"] = .int(Int((bandwidthLimit * 1024).rounded())) }
        if !name.isEmpty { parameters[source.kind == .virtualMachine ? "name" : "hostname"] = .string(name) }
        if let cores { parameters["cores"] = .int(cores) }
        if let sockets, source.kind == .virtualMachine { parameters["sockets"] = .int(sockets) }
        if let memoryMiB { parameters["memory"] = .int(memoryMiB) }
        if let unprivileged, source.kind == .container { parameters["unprivileged"] = .bool(unprivileged) }
        return parameters
    }
}

extension PVE {
    /// Backups on one storage; with `vmid`, only those of that guest.
    public static func backups(node: String, storage: String, vmid: Int? = nil) -> APIRequest<[BackupVolume]> {
        var parameters: APIParameters = ["content": "backup"]
        if let vmid { parameters["vmid"] = .int(vmid) }
        return APIRequest(.get, "/nodes/\(node)/storage/\(storage)/content", parameters: parameters)
    }

    /// Starts a backup. Returns the task ID.
    public static func backupNow(_ draft: BackupDraft) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(draft.guest.node)/vzdump", parameters: draft.parameters)
    }

    /// The guest configuration stored in a backup, as the text of a configuration file.
    public static func backupConfiguration(node: String, volume: String) -> APIRequest<String> {
        APIRequest(.get, "/nodes/\(node)/vzdump/extractconfig", parameters: ["volume": .string(volume)])
    }

    /// Changes notes or protection of a backup. Synchronous.
    public static func updateBackup(node: String, volume: String, notes: String? = nil, isProtected: Bool? = nil) -> APIRequest<String?> {
        var parameters = APIParameters()
        if let notes { parameters["notes"] = .string(notes.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let isProtected { parameters["protected"] = .bool(isProtected) }
        return APIRequest(.put, volumePath(node: node, volume: volume), parameters: parameters)
    }

    /// Deletes a backup. Returns a task ID; protected backups make the task fail.
    public static func deleteBackup(node: String, volume: String) -> APIRequest<String?> {
        APIRequest(.delete, volumePath(node: node, volume: volume))
    }

    /// Restores a backup over its guest or as a new guest. Returns the task ID.
    public static func restore(_ draft: RestoreDraft) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(draft.source.node)/\(draft.source.kind.rawValue)", parameters: draft.parameters)
    }

    private static func volumePath(node: String, volume: String) -> String {
        let storage = String(volume.prefix { $0 != ":" })
        return "/nodes/\(node)/storage/\(storage)/content/\(escapePath(volume))"
    }
}

extension GuestConfig {
    /// Lines of a configuration file as `extractconfig` returns it, without the internal `#qmdump#` lines.
    public static func displayLines(ofBackupConfiguration text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#qmdump#") }
    }
}
