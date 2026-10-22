import Foundation
import ProxmoxCore

/// Settings of a new VM, with the defaults of the web interface's wizard. `parameters` builds the create request.
public struct VMCreationDraft: Sendable, Equatable {
    public var node: String
    public var vmid: Int
    public var name = ""
    /// Empty for no pool.
    public var pool = ""
    /// Adds the VM to high availability once it exists.
    public var isHAManaged = false
    public var startOnBoot = false
    public var startup = StartupOptions()
    public var tags: [String] = []
    public var startAfterCreation = false

    /// vCPU architecture, `x86_64` or `aarch64`; empty for the node's own.
    public var architecture = ""
    /// The node's architecture, from its kernel.
    public var hostArchitecture = "x86_64"

    /// ISO image for the installation, `cdrom` for the host's physical drive, nil for no CD/DVD drive.
    public var isoVolume: String?
    public var osType = "l26"
    /// Windows only: a second drive with the VirtIO driver ISO.
    public var driversISOVolume: String?

    /// `i440fx` or `q35`.
    public var machine = "i440fx"
    /// `seabios` or `ovmf`.
    public var bios = "seabios"
    /// OVMF without an EFI disk starts with default settings each time and cannot keep boot entries.
    public var addEFIDisk = true
    /// Storage for the EFI variables disk, used with OVMF.
    public var efiStorage = ""
    /// Image format of the EFI disk on storages with several, nil for the storage's only one.
    public var efiFormat: String?
    public var preEnrolledKeys = true
    public var addTPM = false
    public var tpmStorage = ""
    /// `v2.0` or `v1.2`; it cannot be changed later.
    public var tpmVersion = "v2.0"
    public var scsiController = "virtio-scsi-single"
    public var guestAgent = false
    /// Graphic card, empty for the default.
    public var display = ""

    /// The disks to create; the first one boots. Empty for a VM without disks.
    public var disks = [NewVMDisk()]

    /// Sockets, cores, type, flags and scheduling. Its model is empty for the Proxmox default (kvm64).
    public var cpu = CPUDraft(GuestConfig(values: ["cores": "2", "cpu": "x86-64-v2-AES"]), isVM: true)
    public var memoryMiB = 2048
    public var ballooning = true
    /// Minimum memory with ballooning, 0 for the same as `memoryMiB`.
    public var minimumMemoryMiB = 0
    /// Weight against other VMs when the host reclaims memory, empty for the default.
    public var memoryShares = ""
    /// Kernel Samepage Merging may merge identical memory pages of this VM.
    public var allowKSM = true

    /// Network devices `net0` and up; empty for a VM without network.
    public var networks = [NewNetworkDevice(NetworkDeviceDraft())]

    public init(node: String, vmid: Int) {
        self.node = node
        self.vmid = vmid
    }

    public var isWindows: Bool { Self.isWindows(osType) }

    /// The architecture the VM gets, `x86_64` or `aarch64`.
    public var effectiveArchitecture: String { architecture.isEmpty ? hostArchitecture : architecture }
    public var isARM: Bool { effectiveArchitecture == "aarch64" }

    /// The OS types the web interface offers for ARM VMs.
    public static let armOSTypes: Set<String> = ["l26", "other"]
    /// ARM VMs have no IDE bus and need a VirtIO SCSI controller.
    public static let armSCSIControllers = ["virtio-scsi-single", "virtio-scsi-pci"]

    /// Switches the vCPU architecture and adjusts the hardware to it, like the web interface.
    public mutating func setArchitecture(_ architecture: String) {
        let wasARM = isARM
        self.architecture = architecture
        adjustToArchitecture(wasARM: wasARM)
    }

    /// Sets the node's architecture once it is known; a VM with the default architecture follows it.
    public mutating func setHostArchitecture(_ architecture: String) {
        let wasARM = isARM
        hostArchitecture = architecture
        adjustToArchitecture(wasARM: wasARM)
    }

    private mutating func adjustToArchitecture(wasARM: Bool) {
        guard isARM != wasARM else { return }
        // On ARM the default model is the host's; x86 VMs get the wizard's usual one back.
        cpu.model = isARM ? "" : "x86-64-v2-AES"
        applyDefaults(for: isARM && !Self.armOSTypes.contains(osType) ? "l26" : osType)
    }

    /// The bus of the CD/DVD drive with the installation media: IDE on x86, SCSI on ARM.
    public var cdromKey: String { isARM ? "scsi2" : "ide2" }

    public static func isWindows(_ osType: String) -> Bool {
        osType.hasPrefix("w")
    }

    /// Adjusts hardware to suit an operating system, like the web interface does when the OS type changes.
    /// Windows gets devices it has drivers for out of the box; Windows 11 also needs UEFI and a TPM.
    public mutating func applyDefaults(for osType: String) {
        self.osType = osType
        if isARM {
            machine = "virt"
            bios = "ovmf"
            addTPM = false
            driversISOVolume = nil
            if !Self.armSCSIControllers.contains(scsiController) { scsiController = "virtio-scsi-single" }
        } else if Self.isWindows(osType) {
            let isLegacy = Self.legacyWindows.contains(osType)
            machine = isLegacy ? "i440fx" : "q35"
            let needsUEFI = osType == "win11"
            bios = needsUEFI ? "ovmf" : "seabios"
            addTPM = needsUEFI
        } else {
            machine = "i440fx"
            bios = "seabios"
            addTPM = false
            driversISOVolume = nil
        }
        for index in disks.indices { disks[index].bus = defaultDiskBus }
        for index in networks.indices { networks[index].device.model = defaultNetworkModel }
    }

    /// Windows versions without drivers for SATA and the Intel E1000E card.
    private static let legacyWindows: Set<String> = ["wxp", "w2k", "w2k3", "wvista"]

    /// The bus the web interface uses for the OS type: IDE for old Windows versions, SATA for newer ones, SCSI otherwise.
    public var defaultDiskBus: DiskBus {
        guard isWindows, !isARM else { return .scsi }
        return Self.legacyWindows.contains(osType) ? .ide : .sata
    }

    /// The card the web interface uses for the OS type: Intel cards for Windows, VirtIO otherwise.
    public var defaultNetworkModel: String {
        guard isWindows else { return "virtio" }
        return Self.legacyWindows.contains(osType) ? "e1000" : "e1000e"
    }

    /// Proxmox allows `net0` to `net31`.
    public static let maximumNetworkDevices = 32

    /// Adds a network device on the bridge of the last one.
    public mutating func addNetworkDevice() {
        guard networks.count < Self.maximumNetworkDevices else { return }
        var device = NetworkDeviceDraft()
        device.model = defaultNetworkModel
        if let last = networks.last { device.bridge = last.device.bridge }
        networks.append(NewNetworkDevice(device))
    }

    /// Adds a disk on the bus and storage of the last one.
    public mutating func addDisk() {
        var disk = NewVMDisk(bus: disks.last?.bus ?? defaultDiskBus, storage: disks.last?.storage ?? "")
        disk.format = disks.last?.format
        disks.append(disk)
    }

    /// Adds a disk imported from an image on an import storage, like the web wizard's Import button.
    public mutating func addImportedDisk() {
        addDisk()
        disks[disks.count - 1].isImport = true
    }

    /// Keys of the disks in their order, e.g. `scsi0` and `scsi1`. The CD drives keep `ide2` and, with Windows drivers, `ide0`.
    /// A key past the last slot of its bus means the bus is full.
    public var diskKeys: [String] {
        var used: Set<String> = [cdromKey]
        if isWindows, driversISOVolume != nil { used.insert("ide0") }
        return disks.map { disk in
            let prefix = disk.bus.rawValue
            let key = (0..<disk.bus.slots).lazy.map { "\(prefix)\($0)" }.first { !used.contains($0) } ?? "\(prefix)\(disk.bus.slots)"
            used.insert(key)
            return key
        }
    }

    /// Problems to fix before the request can be sent, by parameter name.
    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if let message = vmidProblem(vmid) { problems["vmid"] = message }
        if !name.isEmpty, !Self.isValidDNSName(name) {
            problems["name"] = String(localized: "Use letters, digits, hyphens and dots only.")
        }
        for (disk, key) in zip(disks, diskKeys) {
            if key == "\(disk.bus.rawValue)\(disk.bus.slots)" {
                problems[key] = String(localized: "\(disk.bus.title) has no free slot left. Choose another bus.")
            } else if disk.storage.isEmpty {
                problems[key] = String(localized: "Choose a storage.")
            } else if disk.isImport, disk.importSource.isEmpty {
                problems[key] = String(localized: "Choose an image to import.")
            } else if isARM, disk.bus == .ide {
                problems[key] = String(localized: "ARM VMs have no IDE bus. Choose another bus.")
            }
        }
        if isARM, !Self.armSCSIControllers.contains(scsiController) {
            problems["scsihw"] = String(localized: "ARM VMs need a VirtIO SCSI controller.")
        }
        if bios == "ovmf", addEFIDisk, efiStorage.isEmpty { problems["efidisk0"] = String(localized: "Choose a storage for the EFI disk.") }
        if addTPM, tpmStorage.isEmpty { problems["tpmstate0"] = String(localized: "Choose a storage for the TPM state.") }
        return problems
    }

    public var parameters: APIParameters {
        var parameters: APIParameters = ["vmid": .int(vmid)]
        if !name.isEmpty { parameters["name"] = .string(name) }
        if !pool.isEmpty { parameters["pool"] = .string(pool) }
        if isHAManaged { parameters["ha-managed"] = true }
        parameters["ostype"] = .string(osType)
        if !architecture.isEmpty { parameters["arch"] = .string(architecture) }

        if machine == "q35" { parameters["machine"] = "q35" }
        if bios == "ovmf" {
            parameters["bios"] = "ovmf"
            if addEFIDisk {
                var efi = PropertyString(items: [(key: nil, value: "\(efiStorage):1")])
                if let efiFormat { efi["format"] = efiFormat }
                efi["efitype"] = "4m"
                efi["pre-enrolled-keys"] = preEnrolledKeys ? "1" : "0"
                parameters["efidisk0"] = .string(efi.stringValue)
            }
        }
        if addTPM {
            parameters["tpmstate0"] = .string(GuestConfig.tpmStateValue(storage: tpmStorage, version: tpmVersion))
        }
        parameters["scsihw"] = .string(scsiController)
        if guestAgent { parameters["agent"] = "1" }
        if !display.isEmpty { parameters["vga"] = .string(display) }

        let diskKeys = diskKeys
        for (disk, key) in zip(disks, diskKeys) {
            parameters[key] = .string(disk.value)
        }
        var bootOrder = Array(diskKeys.prefix(1))
        if let isoVolume {
            parameters[cdromKey] = .string(GuestConfig.cdromValue(isoVolume: isoVolume))
            bootOrder.append(cdromKey)
        }
        if isWindows, !isARM, let driversISOVolume {
            parameters["ide0"] = .string(GuestConfig.cdromValue(isoVolume: driversISOVolume))
        }

        let cpuValues = cpu.serialized()
        for key in ["sockets", "cores", "vcpus", "cpu", "cpulimit", "cpuunits", "affinity", "numa"] {
            if key == "cores" {
                parameters["cores"] = .int(cpu.cores)
            } else if let value = cpuValues[key] ?? nil {
                parameters[key] = .string(value)
            }
        }
        parameters["memory"] = .int(memoryMiB)
        if !ballooning {
            parameters["balloon"] = 0
        } else {
            if minimumMemoryMiB > 0, minimumMemoryMiB < memoryMiB {
                parameters["balloon"] = .int(minimumMemoryMiB)
            }
            if !memoryShares.trimmed.isEmpty { parameters["shares"] = .string(memoryShares.trimmed) }
        }
        if !allowKSM { parameters["allow-ksm"] = false }

        for (index, network) in networks.enumerated() {
            parameters["net\(index)"] = .string(network.device.stringValue)
        }
        if !networks.isEmpty { bootOrder.append("net0") }
        // Proxmox rejects an empty order; without boot devices the default is left alone.
        if !bootOrder.isEmpty { parameters["boot"] = .string("order=" + bootOrder.joined(separator: ";")) }
        addCommonOptions(to: &parameters, startOnBoot: startOnBoot, startup: startup, tags: tags, startAfterCreation: startAfterCreation)
        return parameters
    }

    /// Letters, digits, hyphens and dots, as Proxmox requires for VM names and container host names.
    static func isValidDNSName(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

/// A disk the VM wizard creates, with the options of the web interface's Disks tab.
public struct NewVMDisk: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public var bus: DiskBus
    public var storage: String
    public var sizeGiB = 32
    /// Image format such as `qcow2`, nil for the storage's default.
    public var format: String?
    /// The disk is a copy of an existing image instead of an empty one; the size comes from the image.
    public var isImport = false
    /// The image to import, e.g. `local:import/debian.qcow2`; empty while none is chosen.
    public var importSource = ""
    /// The bus decides which of these apply.
    public var options: DiskOptionsDraft

    public init(bus: DiskBus = .scsi, storage: String = "") {
        self.bus = bus
        self.storage = storage
        options = DiskOptionsDraft()
        options.discard = true
        options.ioThread = true
    }

    /// IO threads and read-only disks need SCSI or VirtIO Block.
    public var supportsIOThread: Bool { bus == .scsi || bus == .virtio }
    /// VirtIO Block disks report themselves as rotational or not on their own.
    public var supportsSSDEmulation: Bool { bus != .virtio }

    /// Picks the format the web interface picks for a storage: qcow2 where it can, otherwise raw.
    /// Storages with a single format get no explicit one.
    public mutating func chooseFormat(for storage: StorageInfo?) {
        format = storage?.preferredDiskFormat
    }

    /// The disk's parameter value, e.g. `local-lvm:32,discard=on,iothread=1`.
    public var value: String {
        var options = options
        options.ioThread = options.ioThread && supportsIOThread
        options.readOnly = options.readOnly && supportsIOThread
        options.ssdEmulation = options.ssdEmulation && supportsSSDEmulation
        // Imports allocate a disk of the image's size, given as 0.
        var value = PropertyString(parsing: options.newDiskValue(storage: storage, sizeGiB: isImport ? 0 : sizeGiB))
        if let format { value.items.insert((key: "format", value: format), at: 1) }
        if isImport { value.items.insert((key: "import-from", value: importSource), at: 1) }
        return value.stringValue
    }
}

/// Settings of a new container. `parameters` builds the create request.
public struct ContainerCreationDraft: Sendable, Equatable {
    public var node: String
    public var vmid: Int
    public var hostname = ""
    /// Empty for no pool.
    public var pool = ""
    public var unprivileged = true
    /// Lets the container run nested containers and newer systemd versions; the web interface enables it by default.
    public var nesting = true
    public var password = ""
    public var passwordConfirmation = ""
    /// One key per line.
    public var sshPublicKeys = ""
    /// Adds the container to high availability once it exists.
    public var isHAManaged = false
    public var startOnBoot = false
    public var startup = StartupOptions()
    public var tags: [String] = []
    public var startAfterCreation = false

    /// Volume ID of the template, e.g. `local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst`.
    public var template: String?

    public var rootStorage = ""
    public var rootSizeGiB = 8
    /// ACLs, quotas, replication and mount options of the root file system.
    public var rootFS = MountPointDraft.newRootFS()
    /// Further volumes, `mp0` and up.
    public var mountPoints: [NewMountPoint] = []

    public var cores = 1
    /// CPU time limit in cores, 0 for none.
    public var cpuLimit: Double = 0
    /// Scheduler weight, empty for the default.
    public var cpuUnits = ""
    public var memoryMiB = 512
    public var swapMiB = 512

    /// Interfaces `net0` and up; empty for a container without network.
    public var networks = [NewNetworkDevice(ContainerNetworkDraft())]
    public var searchDomain = ""
    /// Space-separated addresses, empty for the host's settings.
    public var nameservers = ""

    public init(node: String, vmid: Int) {
        self.node = node
        self.vmid = vmid
    }

    public static let minimumPasswordLength = 5

    /// Problems to fix before the request can be sent, by parameter name.
    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if let message = vmidProblem(vmid) { problems["vmid"] = message }
        if !hostname.isEmpty, !VMCreationDraft.isValidDNSName(hostname) {
            problems["hostname"] = String(localized: "Use letters, digits, hyphens and dots only.")
        }
        if password.isEmpty, sshKeyLines.isEmpty {
            problems["password"] = String(localized: "Set a password or add an SSH key.")
        } else if !password.isEmpty, password.count < Self.minimumPasswordLength {
            problems["password"] = String(localized: "Use at least \(Self.minimumPasswordLength) characters.")
        } else if password != passwordConfirmation {
            problems["password"] = String(localized: "The passwords do not match.")
        }
        if template == nil { problems["ostemplate"] = String(localized: "Choose a template.") }
        if rootStorage.isEmpty { problems["rootfs"] = String(localized: "Choose a storage.") }
        for (index, mountPoint) in mountPoints.enumerated() {
            let path = mountPoint.options.path.trimmingCharacters(in: .whitespaces)
            if !path.hasPrefix("/") || path == "/" {
                problems["mp\(index)"] = String(localized: "Enter a path in the container, e.g. /data.")
            } else if mountPoints.prefix(index).contains(where: { $0.options.path.trimmingCharacters(in: .whitespaces) == path }) {
                problems["mp\(index)"] = String(localized: "Another mount point uses this path.")
            } else if mountPoint.storage.isEmpty {
                problems["mp\(index)"] = String(localized: "Choose a storage.")
            }
        }
        for (index, network) in networks.enumerated() {
            let name = network.device.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                problems["net\(index)"] = String(localized: "Enter an interface name, e.g. eth1.")
            } else if networks.prefix(index).contains(where: { $0.device.name.trimmingCharacters(in: .whitespaces) == name }) {
                problems["net\(index)"] = String(localized: "Another interface uses this name.")
            }
        }
        return problems
    }

    /// Proxmox allows `net0` to `net31`.
    public static let maximumNetworkDevices = 32

    /// Adds an interface with the next free name, on the bridge of the last one.
    public mutating func addNetworkDevice() {
        guard networks.count < Self.maximumNetworkDevices else { return }
        let used = Set(networks.map(\.device.name))
        var device = ContainerNetworkDraft(name: (0...).lazy.map { "eth\($0)" }.first { !used.contains($0) }!)
        if let last = networks.last { device.bridge = last.device.bridge }
        networks.append(NewNetworkDevice(device))
    }

    /// Proxmox allows `mp0` to `mp255`.
    public static let maximumMountPoints = 256

    /// Adds a mount point on the storage of the root disk.
    public mutating func addMountPoint() {
        guard mountPoints.count < Self.maximumMountPoints else { return }
        mountPoints.append(NewMountPoint(storage: mountPoints.last?.storage ?? rootStorage))
    }

    private var sshKeyLines: [String] {
        sshPublicKeys.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public var parameters: APIParameters {
        var parameters: APIParameters = ["vmid": .int(vmid)]
        if let template { parameters["ostemplate"] = .string(template) }
        if !hostname.isEmpty { parameters["hostname"] = .string(hostname) }
        if !pool.isEmpty { parameters["pool"] = .string(pool) }
        if isHAManaged { parameters["ha-managed"] = true }
        parameters["unprivileged"] = .bool(unprivileged)
        if nesting { parameters["features"] = "nesting=1" }
        if !password.isEmpty { parameters["password"] = .string(password) }
        if !sshKeyLines.isEmpty { parameters["ssh-public-keys"] = .string(sshKeyLines.joined(separator: "\n")) }
        parameters["rootfs"] = .string(rootFS.newVolumeValue(storage: rootStorage, sizeGiB: rootSizeGiB))
        for (index, mountPoint) in mountPoints.enumerated() {
            parameters["mp\(index)"] = .string(mountPoint.value)
        }
        parameters["cores"] = .int(cores)
        if cpuLimit > 0 { parameters["cpulimit"] = .string(CPUDraft.number(cpuLimit)) }
        if !cpuUnits.trimmed.isEmpty { parameters["cpuunits"] = .string(cpuUnits.trimmed) }
        parameters["memory"] = .int(memoryMiB)
        parameters["swap"] = .int(swapMiB)
        for (index, network) in networks.enumerated() {
            parameters["net\(index)"] = .string(network.device.stringValue)
        }
        let dns = ContainerDNSDraft(GuestConfig(values: ["searchdomain": searchDomain, "nameserver": nameservers])).serialized()
        for key in ["nameserver", "searchdomain"] {
            if let value = dns[key] ?? nil { parameters[key] = .string(value) }
        }
        addCommonOptions(to: &parameters, startOnBoot: startOnBoot, startup: startup, tags: tags, startAfterCreation: startAfterCreation)
        return parameters
    }
}

/// A network device a creation wizard adds; the identity tells the devices in the list apart.
public struct NewNetworkDevice<Device: Sendable & Equatable>: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public var device: Device

    public init(_ device: Device) {
        self.device = device
    }
}

/// A volume the container wizard creates besides the root disk.
public struct NewMountPoint: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public var storage: String
    public var sizeGiB = 8
    /// Path, backup, read-only and mount options. New mount points are backed up, as in the web interface.
    public var options: MountPointDraft

    public init(storage: String = "") {
        self.storage = storage
        options = MountPointDraft(GuestDisk(key: "mp0", value: ""))
        options.includeInBackup = true
    }

    /// The mount point's parameter value, e.g. `local-lvm:8,mp=/data,backup=1`.
    public var value: String {
        var options = options
        options.path = options.path.trimmingCharacters(in: .whitespaces)
        return options.newVolumeValue(storage: storage, sizeGiB: sizeGiB)
    }
}

/// Start at boot, start order, tags and starting right away, the same for VMs and containers.
private func addCommonOptions(to parameters: inout APIParameters, startOnBoot: Bool, startup: StartupOptions, tags: [String], startAfterCreation: Bool) {
    if startOnBoot { parameters["onboot"] = true }
    if let startup = startup.serialized { parameters["startup"] = .string(startup) }
    if !tags.isEmpty { parameters["tags"] = .string(tags.joined(separator: ";")) }
    if startAfterCreation { parameters["start"] = true }
}

/// Proxmox accepts guest IDs from 100 to 999999999.
private func vmidProblem(_ vmid: Int) -> String? {
    (100...999_999_999).contains(vmid) ? nil : String(localized: "Use a number from 100 to 999999999.")
}

/// A guest ID, which the server sends as a string or a number.
public struct GuestID: Decodable, Sendable, Equatable {
    public var value: Int

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = number
        } else if let text = try? container.decode(String.self), let number = Int(text) {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a guest ID")
        }
    }
}

/// `GET /pools`
public struct ResourcePool: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var comment: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = container.lossyString(AnyCodingKey("poolid")) ?? ""
        comment = container.lossyString(AnyCodingKey("comment"))
    }
}

/// A container template the node can download, from `GET /nodes/{node}/aplinfo`.
public struct ApplianceTemplate: Decodable, Sendable, Equatable, Identifiable, Hashable {
    /// File name, e.g. `debian-13-standard_13.1-2_amd64.tar.zst`.
    public var template: String
    /// `system` for plain distributions, `turnkeylinux` for TurnKey appliances.
    public var section: String
    public var package: String
    public var headline: String
    public var summary: String?
    public var os: String?
    public var version: String?
    public var architecture: String?

    public var id: String { template }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        template = container.lossyString(AnyCodingKey("template")) ?? ""
        section = container.lossyString(AnyCodingKey("section")) ?? ""
        package = container.lossyString(AnyCodingKey("package")) ?? template
        headline = container.lossyString(AnyCodingKey("headline")) ?? package
        summary = container.lossyString(AnyCodingKey("description")).flatMap { $0.isEmpty ? nil : $0 }
        os = container.lossyString(AnyCodingKey("os"))
        version = container.lossyString(AnyCodingKey("version"))
        architecture = container.lossyString(AnyCodingKey("architecture"))
    }
}

extension PVE {
    /// The lowest free guest ID.
    public static func nextVMID() -> APIRequest<GuestID> {
        APIRequest(.get, "/cluster/nextid")
    }

    /// Succeeds when the ID is free; otherwise fails with a `vmid` field error.
    public static func checkVMID(_ vmid: Int) -> APIRequest<GuestID> {
        APIRequest(.get, "/cluster/nextid", parameters: ["vmid": .int(vmid)])
    }

    /// Creates a VM. Returns the task ID.
    public static func createVM(_ draft: VMCreationDraft) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(draft.node)/qemu", parameters: draft.parameters)
    }

    /// Creates a container from a template. Returns the task ID.
    public static func createContainer(_ draft: ContainerCreationDraft) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(draft.node)/lxc", parameters: draft.parameters)
    }

    public static func pools() -> APIRequest<[ResourcePool]> {
        APIRequest(.get, "/pools")
    }

    public static func applianceTemplates(node: String) -> APIRequest<[ApplianceTemplate]> {
        APIRequest(.get, "/nodes/\(node)/aplinfo")
    }

    /// Downloads a container template to a storage. Returns the task ID.
    public static func downloadTemplate(node: String, storage: String, template: String) -> APIRequest<String> {
        APIRequest(.post, "/nodes/\(node)/aplinfo", parameters: ["storage": .string(storage), "template": .string(template)])
    }
}
