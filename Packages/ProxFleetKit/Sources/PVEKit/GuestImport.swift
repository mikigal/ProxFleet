import Foundation
import ProxmoxCore

/// `GET /nodes/{node}/storage/{storage}/import-metadata`: what an OVA, OVF or ESXi guest would become as a VM.
public struct ImportMetadata: Decodable, Sendable, Equatable {
    /// Parameters for the create call, e.g. `name`, `cores`, `memory`, `ostype`, `boot`, as text.
    public var createArguments: [String: String]
    public var disks: [Disk]
    public var networks: [Network]
    public var warnings: [ImportWarning]

    public struct Disk: Sendable, Equatable {
        /// `scsi0`, `sata1`, `efidisk0`…
        public var id: String
        /// The volume to import from, e.g. `local:import/vm.ova/disk1.vmdk`.
        public var volume: String
        public var size: Int64?
    }

    public struct Network: Sendable, Equatable {
        /// `net0`…
        public var id: String
        /// Options such as `model` and `macaddr`.
        public var options: [String: String]
    }

    public init(createArguments: [String: String], disks: [Disk], networks: [Network], warnings: [ImportWarning]) {
        self.createArguments = createArguments
        self.disks = disks
        self.networks = networks
        self.warnings = warnings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func strings(_ nested: KeyedDecodingContainer<AnyCodingKey>?) -> [String: String] {
            guard let nested else { return [:] }
            var values: [String: String] = [:]
            for key in nested.allKeys {
                if let text = nested.lossyString(key) { values[key.stringValue] = text }
            }
            return values
        }
        createArguments = strings(try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("create-args")))
        var disks: [Disk] = []
        if let nested = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("disks")) {
            for key in nested.allKeys {
                // A disk is either a volume ID or an object with `volid` and `size`.
                if let volume = nested.lossyString(key) {
                    disks.append(Disk(id: key.stringValue, volume: volume, size: nil))
                } else if let object = try? nested.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key) {
                    disks.append(Disk(id: key.stringValue, volume: object.lossyString(AnyCodingKey("volid")) ?? "",
                                      size: object.lossyDouble(AnyCodingKey("size")).map { Int64($0) }))
                }
            }
        }
        self.disks = disks.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        var networks: [Network] = []
        if let nested = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("net")) {
            for key in nested.allKeys {
                networks.append(Network(id: key.stringValue, options: strings(try? nested.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key))))
            }
        }
        self.networks = networks.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        warnings = (try? container.decode([ImportWarning].self, forKey: AnyCodingKey("warnings"))) ?? []
    }
}

/// A problem the server found while reading the guest to import.
public struct ImportWarning: Decodable, Sendable, Equatable {
    public var type: String?
    public var key: String?
    public var value: String?
    public var message: String?

    public init(type: String?, key: String? = nil, value: String? = nil, message: String? = nil) {
        self.type = type
        self.key = key
        self.value = value
        self.message = message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        type = container.lossyString(AnyCodingKey("type"))
        key = container.lossyString(AnyCodingKey("key"))
        value = container.lossyString(AnyCodingKey("value"))
        message = container.lossyString(AnyCodingKey("message"))
    }

    /// The web interface's wording for the known warning types.
    public var text: String {
        let key = key ?? "unknown"
        let value = value ?? "unknown"
        switch type {
        case "cdrom-image-ignored": return String(localized: "CD/DVD images cannot be imported. Choose an image for \(key) under CD/DVD Drives if needed.")
        case "nvme-unsupported": return String(localized: "NVMe disks are not supported; \(key) is attached as SCSI.")
        case "ovmf-with-lsi-unsupported": return String(localized: "OVMF has no LSI drivers, so the SCSI controller was set to \(value).")
        case "serial-port-socket-only": return String(localized: "The serial port \(key) becomes a socket.")
        case "guest-is-running": return String(localized: "The guest seems to run on the source host. The import may fail or be inconsistent.")
        case "efi-state-lost": return String(localized: "The EFI state cannot be imported; the boot order may need to be set up again.")
        case "ova-needs-extracting": return String(localized: "Importing an OVA needs extra space on the working storage while its disks are extracted.")
        default: return message ?? type ?? String(localized: "Unknown warning")
        }
    }
}

/// Importing an OVA, OVF or ESXi guest as a new VM, like the web interface's Import Guest dialog.
public struct GuestImportDraft: Sendable, Equatable {
    public let node: String
    /// The archive, e.g. `local:import/vm.ova`.
    public let volume: String
    public var vmid = 0
    public var name: String
    public var sockets: Int
    public var cores: Int
    public var memoryMiB: Int
    public var cpuModel = "x86-64-v2-AES"
    public var osType: String
    public var pool = ""
    /// Where disks go unless they name their own storage.
    public var defaultStorage = ""
    public var defaultFormat: String?
    /// The bridge of network devices that name none.
    public var defaultBridge = ""
    /// OVA only: where the disks are extracted first; empty for the source storage.
    public var workingStorage = ""
    /// Start the VM right away while the disks are imported in the background.
    public var liveImport = false
    public var scsiController: String
    /// Windows with UEFI: attach SCSI disks as SATA for now, so the VirtIO SCSI driver can be installed first.
    public var prepareForVirtIOSCSI: Bool
    public var uniqueMACAddresses = false
    public var disks: [Disk]
    public var networks: [Network]
    public var cdroms: [CDROM]
    public let warnings: [ImportWarning]
    /// Arguments of the source passed on unchanged, such as `bios`, `machine` or `boot`.
    private var otherArguments: [String: String]

    public struct Disk: Sendable, Equatable, Identifiable {
        public var id: String
        public var source: String
        public var size: Int64?
        public var isEnabled = true
        /// Empty for the default storage.
        public var storage = ""
        public var format: String?
    }

    public struct Network: Sendable, Equatable, Identifiable {
        public var id: String
        public var isEnabled = true
        public var model: String
        public var macAddress: String?
        /// Empty for the default bridge.
        public var bridge = ""
        public var vlanTag: Int?
        fileprivate var others: [(key: String, value: String)]

        public static func == (lhs: Network, rhs: Network) -> Bool {
            lhs.id == rhs.id && lhs.isEnabled == rhs.isEnabled && lhs.model == rhs.model && lhs.macAddress == rhs.macAddress
                && lhs.bridge == rhs.bridge && lhs.vlanTag == rhs.vlanTag && lhs.others.elementsEqual(rhs.others) { $0 == $1 }
        }
    }

    public struct CDROM: Sendable, Equatable, Identifiable {
        public var id: String
        public var isEnabled = true
        /// An ISO image, nil for an empty drive.
        public var isoVolume: String?
        /// Added for the VirtIO driver ISO of Windows guests; shown for Windows only.
        public var isForDrivers = false
    }

    public init(metadata: ImportMetadata, node: String, volume: String) {
        self.node = node
        self.volume = volume
        var arguments = metadata.createArguments
        name = arguments.removeValue(forKey: "name") ?? ""
        sockets = arguments.removeValue(forKey: "sockets").flatMap { Int($0) } ?? 1
        cores = arguments.removeValue(forKey: "cores").flatMap { Int($0) } ?? 1
        memoryMiB = arguments.removeValue(forKey: "memory").flatMap { Int($0) } ?? 512
        if let cpu = arguments.removeValue(forKey: "cpu") { cpuModel = PropertyString(parsing: cpu).defaultValue ?? cpu }
        osType = arguments.removeValue(forKey: "ostype") ?? "l26"
        let sourceController = arguments.removeValue(forKey: "scsihw") ?? ""
        disks = metadata.disks.map { Disk(id: $0.id, source: $0.volume, size: $0.size) }
        networks = metadata.networks.map { network in
            var others = network.options.filter { !["model", "macaddr", "bridge", "tag"].contains($0.key) }.map { (key: $0.key, value: $0.value) }
            others.sort { $0.key < $1.key }
            return Network(id: network.id, model: network.options["model"] ?? "virtio", macAddress: network.options["macaddr"],
                           vlanTag: network.options["tag"].flatMap { Int($0) }, others: others)
        }
        var cdroms: [CDROM] = []
        for (key, value) in arguments where value.contains("media=cdrom") {
            cdroms.append(CDROM(id: key))
            arguments[key] = nil
        }
        warnings = metadata.warnings
        otherArguments = arguments
        let isWindows = osType.hasPrefix("w")
        prepareForVirtIOSCSI = isWindows && (arguments["bios"] ?? "").contains("ovmf")
        scsiController = prepareForVirtIOSCSI ? "virtio-scsi-single" : sourceController
        // Windows needs a drive for the VirtIO driver ISO; the web interface adds one when the guest has none.
        if cdroms.isEmpty, let slot = Self.driverDriveSlot(used: Set(arguments.keys).union(disks.map(\.id))) {
            cdroms.append(CDROM(id: slot, isForDrivers: true))
        }
        self.cdroms = cdroms.sorted { $0.id < $1.id }
    }

    /// ide0 and ide2 work for ISO images with every machine type; after that, the next SATA slot.
    private static func driverDriveSlot(used: Set<String>) -> String? {
        let maxIDE = used.compactMap { $0.hasPrefix("ide") ? Int($0.dropFirst(3)) : nil }.max() ?? -1
        if maxIDE < 0 { return "ide0" }
        if maxIDE < 2 { return "ide2" }
        let maxSATA = used.compactMap { $0.hasPrefix("sata") ? Int($0.dropFirst(4)) : nil }.max() ?? -1
        return maxSATA < DiskBus.sata.slots - 1 ? "sata\(maxSATA + 1)" : nil
    }

    public var isWindows: Bool { osType.hasPrefix("w") }
    /// OVA archives are extracted before their disks are imported.
    public var needsExtracting: Bool { warnings.contains { $0.type == "ova-needs-extracting" } }

    /// The CD/DVD drives that apply: the driver drive only for Windows.
    public var visibleCDROMs: [CDROM] { cdroms.filter { !$0.isForDrivers || isWindows } }

    /// Where each disk is attached: with VirtIO SCSI preparation, SCSI disks move to SATA slots after the used ones.
    public var diskSlots: [String: String] {
        guard prepareForVirtIOSCSI, isWindows else { return [:] }
        var used = Set(otherArguments.keys).union(disks.filter { !$0.id.hasPrefix("scsi") }.map(\.id))
        for cdrom in visibleCDROMs where cdrom.isEnabled { used.insert(cdrom.id) }
        let maxSATA = used.compactMap { $0.hasPrefix("sata") ? Int($0.dropFirst(4)) : nil }.max() ?? -1
        var slots: [String: String] = [:]
        for disk in disks where disk.id.hasPrefix("scsi") {
            guard let offset = Int(disk.id.dropFirst(4)), maxSATA + 1 + offset < DiskBus.sata.slots else { continue }
            slots[disk.id] = "sata\(maxSATA + 1 + offset)"
        }
        return slots
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if !(100...999_999_999).contains(vmid) { problems["vmid"] = String(localized: "Use a number from 100 to 999999999.") }
        if !name.isEmpty, !VMCreationDraft.isValidDNSName(name) { problems["name"] = String(localized: "Use letters, digits, hyphens and dots only.") }
        if disks.contains(where: { $0.isEnabled && $0.storage.isEmpty }), defaultStorage.isEmpty {
            problems["storage"] = String(localized: "Choose a storage for the disks.")
        }
        if networks.contains(where: { $0.isEnabled && $0.bridge.isEmpty }), defaultBridge.isEmpty {
            problems["bridge"] = String(localized: "Choose a bridge for the network devices.")
        }
        return problems
    }

    /// Parameters of `POST /nodes/{node}/qemu`.
    public var parameters: APIParameters {
        var config = otherArguments
        config["vmid"] = String(vmid)
        if !name.isEmpty { config["name"] = name }
        config["sockets"] = String(sockets)
        config["cores"] = String(cores)
        config["memory"] = String(memoryMiB)
        if !cpuModel.isEmpty { config["cpu"] = cpuModel }
        config["ostype"] = osType
        if !pool.isEmpty { config["pool"] = pool }
        if !scsiController.isEmpty { config["scsihw"] = scsiController }
        if needsExtracting, !workingStorage.isEmpty { config["import-working-storage"] = workingStorage }
        if liveImport { config["live-restore"] = "1" }

        let slots = diskSlots
        var bootOrder = PropertyString(parsing: config["boot"] ?? "")["order"]?.split(separator: ";").map(String.init)
        for disk in disks {
            let slot = slots[disk.id] ?? disk.id
            guard disk.isEnabled else {
                bootOrder?.removeAll { $0 == disk.id }
                continue
            }
            bootOrder = bootOrder?.map { $0 == disk.id ? slot : $0 }
            let storage = disk.storage.isEmpty ? defaultStorage : disk.storage
            let format = disk.storage.isEmpty ? defaultFormat : disk.format
            var value = PropertyString(items: [(key: nil, value: "\(storage):0")])
            if slot == "efidisk0" {
                value["efitype"] = "4m"
            } else {
                value["import-from"] = disk.source
            }
            if let format { value["format"] = format }
            config[slot] = value.stringValue
        }
        for network in networks {
            guard network.isEnabled else {
                bootOrder?.removeAll { $0 == network.id }
                continue
            }
            var value = PropertyString(items: [])
            if let mac = network.macAddress, !uniqueMACAddresses {
                value.items.append((key: network.model, value: mac))
            } else {
                value["model"] = network.model
            }
            value["bridge"] = network.bridge.isEmpty ? defaultBridge : network.bridge
            if let tag = network.vlanTag { value["tag"] = String(tag) }
            value.items += network.others.map { (key: Optional($0.key), value: $0.value) }
            config[network.id] = value.stringValue
        }
        for cdrom in visibleCDROMs where cdrom.isEnabled {
            config[cdrom.id] = GuestConfig.cdromValue(isoVolume: cdrom.isoVolume)
        }
        if let bootOrder {
            var boot = PropertyString(parsing: config["boot"] ?? "")
            boot["order"] = bootOrder.isEmpty ? nil : bootOrder.joined(separator: ";")
            config["boot"] = boot.items.isEmpty ? nil : boot.stringValue
        }

        var parameters: APIParameters = ["vmid": .int(vmid)]
        for (key, value) in config.sorted(by: { $0.key < $1.key }) where key != "vmid" {
            parameters[key] = .string(value)
        }
        return parameters
    }
}

extension PVE {
    /// How a guest archive or ESXi guest would be imported. `volume` is the full volume ID, e.g. `local:import/vm.ova`.
    public static func importMetadata(node: String, volume: String) -> APIRequest<ImportMetadata> {
        let storage = String(volume.prefix { $0 != ":" })
        // The endpoint wants the volume without its storage.
        let name = String(volume.dropFirst(storage.count + 1))
        return APIRequest(.get, "/nodes/\(node)/storage/\(escapePath(storage))/import-metadata", parameters: ["volume": .string(name)])
    }

    /// Creates a VM from an imported guest. Returns the task ID.
    public static func importGuest(_ draft: GuestImportDraft) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(draft.node)/qemu", parameters: draft.parameters)
    }
}
