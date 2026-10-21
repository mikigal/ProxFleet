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

    /// ISO image for the installation, nil for no CD/DVD drive.
    public var isoVolume: String?
    public var osType = "l26"
    /// Windows only: a second drive with the VirtIO driver ISO.
    public var driversISOVolume: String?

    /// `i440fx` or `q35`.
    public var machine = "i440fx"
    /// `seabios` or `ovmf`.
    public var bios = "seabios"
    /// Storage for the EFI variables disk, used with OVMF.
    public var efiStorage = ""
    public var preEnrolledKeys = true
    public var addTPM = false
    public var tpmStorage = ""
    public var scsiController = "virtio-scsi-single"
    public var guestAgent = false
    /// Graphic card, empty for the default.
    public var display = ""

    public var diskBus: DiskBus = .scsi
    public var diskStorage = ""
    public var diskSizeGiB = 32
    /// Options of the system disk; the bus decides which of them apply.
    public var disk: DiskOptionsDraft = {
        var options = DiskOptionsDraft()
        options.discard = true
        options.ioThread = true
        return options
    }()

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

    public var hasNetwork = true
    public var network = NetworkDeviceDraft()

    public init(node: String, vmid: Int) {
        self.node = node
        self.vmid = vmid
    }

    public var isWindows: Bool { Self.isWindows(osType) }

    public static func isWindows(_ osType: String) -> Bool {
        osType.hasPrefix("w")
    }

    /// Adjusts hardware to suit an operating system, like the web interface does when the OS type changes.
    /// Windows gets devices it has drivers for out of the box; Windows 11 also needs UEFI and a TPM.
    public mutating func applyDefaults(for osType: String) {
        self.osType = osType
        if Self.isWindows(osType) {
            let isLegacy = ["wxp", "w2k", "w2k3", "wvista"].contains(osType)
            diskBus = isLegacy ? .ide : .sata
            network.model = isLegacy ? "e1000" : "e1000e"
            machine = isLegacy ? "i440fx" : "q35"
            let needsUEFI = osType == "win11"
            bios = needsUEFI ? "ovmf" : "seabios"
            addTPM = needsUEFI
        } else {
            diskBus = .scsi
            network.model = "virtio"
            machine = "i440fx"
            bios = "seabios"
            addTPM = false
            driversISOVolume = nil
        }
    }

    /// The key of the system disk, e.g. `scsi0`.
    public var diskKey: String { "\(diskBus.rawValue)0" }

    /// IO threads and read-only disks need SCSI or VirtIO Block.
    public var diskSupportsIOThread: Bool { diskBus == .scsi || diskBus == .virtio }
    /// VirtIO Block disks report themselves as rotational or not on their own.
    public var diskSupportsSSDEmulation: Bool { diskBus != .virtio }

    /// Problems to fix before the request can be sent, by parameter name.
    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if let message = vmidProblem(vmid) { problems["vmid"] = message }
        if !name.isEmpty, !Self.isValidDNSName(name) {
            problems["name"] = String(localized: "Use letters, digits, hyphens and dots only.")
        }
        if diskStorage.isEmpty { problems[diskKey] = String(localized: "Choose a storage.") }
        if bios == "ovmf", efiStorage.isEmpty { problems["efidisk0"] = String(localized: "Choose a storage for the EFI disk.") }
        if addTPM, tpmStorage.isEmpty { problems["tpmstate0"] = String(localized: "Choose a storage for the TPM state.") }
        return problems
    }

    public var parameters: APIParameters {
        var parameters: APIParameters = ["vmid": .int(vmid)]
        if !name.isEmpty { parameters["name"] = .string(name) }
        if !pool.isEmpty { parameters["pool"] = .string(pool) }
        if isHAManaged { parameters["ha-managed"] = true }
        parameters["ostype"] = .string(osType)

        if machine == "q35" { parameters["machine"] = "q35" }
        if bios == "ovmf" {
            parameters["bios"] = "ovmf"
            var efi = PropertyString(items: [(key: nil, value: "\(efiStorage):1")])
            efi["efitype"] = "4m"
            efi["pre-enrolled-keys"] = preEnrolledKeys ? "1" : "0"
            parameters["efidisk0"] = .string(efi.stringValue)
        }
        if addTPM {
            parameters["tpmstate0"] = .string("\(tpmStorage):1,version=v2.0")
        }
        parameters["scsihw"] = .string(scsiController)
        if guestAgent { parameters["agent"] = "1" }
        if !display.isEmpty { parameters["vga"] = .string(display) }

        var disk = disk
        disk.ioThread = disk.ioThread && diskSupportsIOThread
        disk.readOnly = disk.readOnly && diskSupportsIOThread
        disk.ssdEmulation = disk.ssdEmulation && diskSupportsSSDEmulation
        parameters[diskKey] = .string(disk.newDiskValue(storage: diskStorage, sizeGiB: diskSizeGiB))
        var bootOrder = [diskKey]
        if let isoVolume {
            parameters["ide2"] = .string(GuestConfig.cdromValue(isoVolume: isoVolume))
            bootOrder.append("ide2")
        }
        if isWindows, let driversISOVolume {
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

        if hasNetwork {
            parameters["net0"] = .string(network.stringValue)
            bootOrder.append("net0")
        }
        parameters["boot"] = .string("order=" + bootOrder.joined(separator: ";"))
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

    public var cores = 1
    /// CPU time limit in cores, 0 for none.
    public var cpuLimit: Double = 0
    /// Scheduler weight, empty for the default.
    public var cpuUnits = ""
    public var memoryMiB = 512
    public var swapMiB = 512

    public var hasNetwork = true
    public var network = ContainerNetworkDraft()
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
        return problems
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
        parameters["cores"] = .int(cores)
        if cpuLimit > 0 { parameters["cpulimit"] = .string(CPUDraft.number(cpuLimit)) }
        if !cpuUnits.trimmed.isEmpty { parameters["cpuunits"] = .string(cpuUnits.trimmed) }
        parameters["memory"] = .int(memoryMiB)
        parameters["swap"] = .int(swapMiB)
        if hasNetwork { parameters["net0"] = .string(network.stringValue) }
        let dns = ContainerDNSDraft(GuestConfig(values: ["searchdomain": searchDomain, "nameserver": nameservers])).serialized()
        for key in ["nameserver", "searchdomain"] {
            if let value = dns[key] ?? nil { parameters[key] = .string(value) }
        }
        addCommonOptions(to: &parameters, startOnBoot: startOnBoot, startup: startup, tags: tags, startAfterCreation: startAfterCreation)
        return parameters
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
