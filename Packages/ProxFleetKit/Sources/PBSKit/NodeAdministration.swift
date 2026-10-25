import Foundation
import ProxmoxCore
import PVEKit

// Administration of the backup server itself. Most of its node API matches Proxmox VE's (services, updates,
// repositories, DNS, time, certificates, the journal), so the PVE requests and models are used with the node
// `localhost`; what differs is here: disks, the network's list settings, and the node's options.

// MARK: - Disks

extension BackupServerDisk {
    /// The disk and its partitions as Proxmox VE lists them, for the shared disk screens.
    public var nodeDisks: [NodeDisk] {
        let disk = NodeDisk(
            path: devicePath, model: model, vendor: vendor, serial: serial, size: size,
            type: kind.flatMap { $0 == "unknown" ? nil : $0 } ?? "unknown",
            health: health.flatMap { $0 == "unknown" ? nil : $0.uppercased() }, wearout: wearout.map { Int($0) },
            // A disk with a mounted partition, such as the system disk, is `mounted`; Proxmox VE calls that `partitions`,
            // and the disk screen then sums up what the partitions hold.
            usage: usage == "mounted" && !partitions.isEmpty ? "partitions" : Self.usageTitle(usage, fileSystem: nil), hasGPT: hasGPT
        )
        return [disk] + partitions.map { partition in
            NodeDisk(path: partition.devicePath, parent: devicePath, size: partition.size, type: "partition",
                     usage: Self.usageTitle(partition.usage, fileSystem: partition.fileSystem), isMounted: partition.isMounted)
        }
    }

    /// Usage the way Proxmox VE words it, nil when unused.
    static func usageTitle(_ usage: String?, fileSystem: String?) -> String? {
        switch usage {
        case nil, "unused": nil
        case "lvm": "LVM"
        case "zfs": "ZFS"
        case "bios": "BIOS boot"
        case "efi": "EFI"
        case "devicemapper": "Device Mapper"
        case "filesystem": fileSystem ?? "filesystem"
        case let other?: other
        }
    }
}

/// A directory mounted for a datastore, from `GET /nodes/localhost/disks/directory`.
public struct BackupServerDirectory: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var path: String
    public var device: String
    public var fileSystem: String
    public var options: String?
    /// A mount for a removable datastore, which is mounted only while needed.
    public var isRemovable: Bool

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        path = container.lossyString(AnyCodingKey("path")) ?? ""
        // The server lists the name with a leading slash (`/usb`), but deletes it by the plain name.
        let listed = container.lossyString(AnyCodingKey("name")) ?? path.split(separator: "/").last.map(String.init) ?? ""
        name = listed.hasPrefix("/") ? String(listed.dropFirst()) : listed
        device = container.lossyString(AnyCodingKey("device")) ?? ""
        fileSystem = container.lossyString(AnyCodingKey("filesystem")) ?? ""
        options = container.lossyString(AnyCodingKey("options")).flatMap { $0.isEmpty ? nil : $0 }
        isRemovable = container.lossyBool(AnyCodingKey("removable")) ?? false
    }

    /// The mount as the shared disk screens show directories.
    public var mount: DirectoryMount {
        DirectoryMount(path: path.isEmpty ? "/mnt/datastore/\(name)" : path, device: device, fileSystem: fileSystem, options: options)
    }
}

extension DiskStorageDraft {
    /// RAID levels the backup server offers; it has no dRAID.
    public static let backupServerRAIDLevels = ["single", "mirror", "raid10", "raidz", "raidz2", "raidz3"]

    /// Problems for a directory or ZFS pool on the backup server, whose name is also the datastore's.
    public func backupServerProblems(existingDatastores: [String]) -> [String: String] {
        var problems = self.problems
        let name = name.trimmingCharacters(in: .whitespaces)
        problems["name"] = nil
        if name.count < 3 || name.count > 32 || name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\-]*/) == nil {
            problems["name"] = String(localized: "Use 3 to 32 letters, digits, dots, dashes or underscores.")
        } else if addStorage, existingDatastores.contains(name) {
            problems["name"] = String(localized: "A datastore with this name exists already.")
        }
        return problems
    }

    /// Parameters of `POST /nodes/localhost/disks/{directory,zfs}`: disks by name, not path.
    public func backupServerParameters(removable: Bool) -> APIParameters {
        let names = devices.map { $0.hasPrefix("/dev/") ? String($0.dropFirst("/dev/".count)) : $0 }
        var parameters: APIParameters = ["name": .string(name.trimmingCharacters(in: .whitespaces))]
        if kind == .zfs {
            parameters["devices"] = .string(names.joined(separator: ","))
            parameters["raidlevel"] = .string(names.count == 1 ? "single" : raidLevel)
            parameters["compression"] = .string(compression)
            parameters["ashift"] = .int(ashift)
        } else {
            parameters["disk"] = .string(names.first ?? "")
            parameters["filesystem"] = .string(fileSystem)
        }
        parameters["add-datastore"] = .bool(addStorage)
        if kind == .directory, addStorage, removable { parameters["removable-datastore"] = true }
        return parameters
    }
}

extension PBS {
    /// Disks with SMART health, flattened as Proxmox VE lists them.
    public static func nodeDisks() -> APIRequest<[BackupServerDisk]> {
        disks(includePartitions: true, skipSMART: false)
    }

    public static func directories() -> APIRequest<[BackupServerDirectory]> {
        APIRequest(.get, "/nodes/\(node)/disks/directory")
    }

    public static func zfsPools() -> APIRequest<[ZFSPool]> {
        APIRequest(.get, "/nodes/\(node)/disks/zfs")
    }

    public static func zfsPoolStatus(_ name: String) -> APIRequest<ZFSPoolStatus> {
        APIRequest(.get, "/nodes/\(node)/disks/zfs/\(escapePath(name))")
    }

    /// Creates a directory or ZFS pool, optionally with a datastore on it. Returns a task ID.
    public static func createDiskStorage(_ draft: DiskStorageDraft, removable: Bool = false) -> APIRequest<String?> {
        APIRequest(.post, "/nodes/\(node)/disks/\(draft.kind == .zfs ? "zfs" : "directory")", parameters: draft.backupServerParameters(removable: removable))
    }

    /// Unmounts a directory and removes its mount unit; the data stays. Returns a task ID.
    public static func deleteDirectory(_ name: String) -> APIRequest<String?> {
        APIRequest(.delete, "/nodes/\(node)/disks/directory/\(escapePath(name))")
    }

    /// The device name the disk calls take: `sdb`, not `/dev/sdb`.
    public static func diskName(_ path: String) -> String {
        path.hasPrefix("/dev/") ? String(path.dropFirst("/dev/".count)) : path
    }
}

// MARK: - Network

extension PBS {
    /// Interface settings as the backup server takes them: member lists comma-separated and each cleared setting as
    /// its own `delete`. VLAN IDs of bridges are not supported there.
    static func networkParameters(_ parameters: APIParameters) -> APIParameters {
        var converted = APIParameters()
        for item in parameters.items where item.name != "bridge_vids" {
            switch (item.name, item.value) {
            case ("bridge_ports", .string(let list)), ("slaves", .string(let list)):
                converted.append(item.name, .string(list.split(separator: " ").joined(separator: ",")))
            case ("delete", .string(let keys)):
                for key in keys.split(separator: ",") where key != "bridge_vids" { converted.append("delete", .string(String(key))) }
            default:
                converted.append(item.name, item.value)
            }
        }
        return converted
    }

    public static func createInterface(_ draft: NetworkInterfaceDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/nodes/\(node)/network", parameters: networkParameters(draft.creationParameters))
    }

    public static func updateInterface(_ name: String, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/nodes/\(node)/network/\(escapePath(name))", parameters: networkParameters(update.parameters))
    }
}

// MARK: - Certificates

extension PBS {
    /// Uploads a custom certificate; the proxy reloads with it. Returns the new certificates.
    public static func uploadCertificate(_ draft: CustomCertificateDraft) -> APIRequest<[NodeCertificate]> {
        APIRequest(.post, "/nodes/\(node)/certificates/custom", parameters: draft.parameters)
    }

    /// Removes the custom certificate; the server makes a new self-signed one, with a new fingerprint.
    public static func deleteCustomCertificate() -> APIRequest<Nothing> {
        APIRequest(.delete, "/nodes/\(node)/certificates/custom")
    }
}

// MARK: - Options

/// The server's own options, from `GET /nodes/localhost/config`: proxy, mail sender, language, task log retention,
/// consent banner and TLS ciphers. ACME settings are kept as they are.
public struct BackupServerNodeOptions: Decodable, Sendable, Equatable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: String] = [:]
        for key in container.allKeys {
            if let text = container.lossyString(key) { values[key.stringValue] = text }
        }
        self.values = values
    }
}

public struct BackupServerNodeOptionsDraft: BackupServerDraft, Sendable {
    /// Languages of the web interface, as its language selector offers them.
    public static let languages = ["ar", "ca", "da", "de", "en", "es", "eu", "fa", "fr", "gl", "he", "hu", "it", "ja", "kr", "nb", "nl",
                                   "nn", "pl", "pt_BR", "ru", "sl", "sv", "tr", "zh_CN", "zh_TW"]

    public var httpProxy = ""
    public var emailFrom = ""
    /// Empty for the browser's language.
    public var defaultLanguage = ""
    public var description = ""
    /// Days task logs are kept; nil keeps them forever.
    public var taskLogMaxDays: Int?
    public var consentText = ""
    public var ciphersTLS12 = ""
    public var ciphersTLS13 = ""

    public init() {}

    public init(_ options: BackupServerNodeOptions) {
        let values = options.values
        httpProxy = values["http-proxy"] ?? ""
        emailFrom = values["email-from"] ?? ""
        defaultLanguage = values["default-lang"] ?? ""
        // The server adds a trailing newline.
        description = (values["description"] ?? "").trimmingCharacters(in: .newlines)
        taskLogMaxDays = values["task-log-max-days"].flatMap(Int.init)
        consentText = values["consent-text"] ?? ""
        ciphersTLS12 = values["ciphers-tls-1.2"] ?? ""
        ciphersTLS13 = values["ciphers-tls-1.3"] ?? ""
    }

    public func serialized() -> [String: String?] {
        func text(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return [
            "http-proxy": text(httpProxy), "email-from": text(emailFrom), "default-lang": text(defaultLanguage),
            "description": text(description), "task-log-max-days": taskLogMaxDays.map(String.init), "consent-text": text(consentText),
            "ciphers-tls-1.2": text(ciphersTLS12), "ciphers-tls-1.3": text(ciphersTLS13),
        ]
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        let proxy = httpProxy.trimmingCharacters(in: .whitespaces)
        if !proxy.isEmpty, proxy.wholeMatch(of: /(https?:\/\/)?[^\s:\/]+(:\d+)?\/?/) == nil {
            problems["http-proxy"] = String(localized: "Enter a host and port, e.g. http://proxy.lan:3128.")
        }
        let email = emailFrom.trimmingCharacters(in: .whitespaces)
        if !email.isEmpty, email.wholeMatch(of: /[^\s@]+@[^\s@]+/) == nil {
            problems["email-from"] = String(localized: "Enter an email address.")
        }
        if let days = taskLogMaxDays, days < 0 { problems["task-log-max-days"] = String(localized: "Enter 0 or more days.") }
        return problems
    }
}

extension PBS {
    public static func nodeOptions() -> APIRequest<Digested<BackupServerNodeOptions>> {
        APIRequest(.get, "/nodes/\(node)/config")
    }

    public static func updateNodeOptions(_ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/nodes/\(node)/config", parameters: update.parameters)
    }
}
