import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The pages of the Create VM wizard, in the order of the web interface.
nonisolated enum VMCreationStep: CreationStep {
    case general, os, system, disks, cpu, memory, network, confirm

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .os: "OS"
        case .system: "System"
        case .disks: "Disks"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .confirm: "Confirm"
        }
    }

    func owns(_ parameter: String) -> Bool {
        switch self {
        case .general: ["vmid", "name", "pool", "ha-managed", "onboot", "startup", "tags", "arch"].contains(parameter)
        case .os: ["ostype", "ide0", "ide2"].contains(parameter)
        case .system: ["machine", "bios", "efidisk0", "tpmstate0", "scsihw", "agent", "vga"].contains(parameter)
        case .disks: Self.isDiskKey(parameter)
        case .cpu: ["sockets", "cores", "cpu", "vcpus", "cpulimit", "cpuunits", "affinity", "numa"].contains(parameter)
        case .memory: ["memory", "balloon", "shares", "allow-ksm"].contains(parameter)
        case .network: parameter.hasPrefix("net")
        case .confirm: false
        }
    }

    /// Fields behind the web interface's Advanced checkbox. Disk and network options are part of their device's value.
    func isAdvanced(_ parameter: String) -> Bool {
        ["onboot", "startup", "tags", "arch", "vcpus", "cpulimit", "cpuunits", "affinity", "numa", "balloon", "shares", "allow-ksm"].contains(parameter)
    }

    /// `scsi0`, `sata0`…; the IDE drives of the OS page hold ISO images.
    private static func isDiskKey(_ key: String) -> Bool {
        guard !["ide0", "ide2"].contains(key) else { return false }
        return DiskBus.allCases.contains { bus in key.hasPrefix(bus.rawValue) && Int(key.dropFirst(bus.rawValue.count)) != nil }
    }
}

/// Creates a VM step by step, like the web interface's wizard, starting from its defaults.
struct CreateVMView: View {
    let connection: ServerConnection
    let onCreated: (GuestReference) -> Void
    @State private var pools: [ResourcePool] = []
    @State private var draft: VMCreationDraft
    @State private var isoReloadID = 0
    @State private var cpuModels: [CPUModel] = []
    @State private var diskStorages: [StorageInfo] = []
    @AppStorage(AdvancedCreationOptions.storageKey) private var showsAdvanced = false

    init(connection: ServerConnection, onCreated: @escaping (GuestReference) -> Void) {
        self.connection = connection
        self.onCreated = onCreated
        _draft = State(initialValue: VMCreationDraft(node: NodePicker.defaultNode(connection), vmid: 0))
    }

    var body: some View {
        CreationWizard<VMCreationStep, _>(
            title: "New Virtual Machine",
            connection: connection,
            reference: GuestReference(node: draft.node, vmid: draft.vmid, kind: .virtualMachine),
            problems: draft.problems,
            makeRequest: { PVE.createVM(draft) },
            onCreated: onCreated,
            showsAdvancedOptions: $showsAdvanced
        ) { step, errors in
            switch step {
            case .general: general(errors)
            case .os: operatingSystem(errors)
            case .system: system(errors)
            case .disks: disks(errors)
            case .cpu: processor(errors)
            case .memory: memory(errors)
            case .network: network(errors)
            case .confirm: confirm
            }
        }
    }

    @ViewBuilder
    private func general(_ errors: [String: String]) -> some View {
        Section {
            NodePicker(connection: connection, selection: $draft.node)
            GuestIDField(connection: connection, vmid: $draft.vmid, error: errors["vmid"])
            LabeledContent("Name") {
                TextField("Optional", text: $draft.name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("name")
            }
            FieldError(message: errors["name"])
            if isCluster {
                Toggle("Add to HA", isOn: $draft.isHAManaged)
                FieldError(message: errors["ha-managed"])
            }
            PoolPicker(pools: pools, selection: $draft.pool)
        } footer: {
            if isCluster {
                Text("High availability starts the VM on another node when its node fails.")
            }
        }
        .task { pools = await connection.load(PVE.pools()) }
        .task(id: draft.node) {
            if let status = try? await connection.send(PVE.nodeStatus(draft.node)), let architecture = status.architecture {
                draft.setHostArchitecture(architecture)
            }
        }
        if showsAdvanced {
            StartupSection(startAtBoot: $draft.startOnBoot, startup: $draft.startup, error: errors["startup"])
            Section {
                Picker("Architecture", selection: Binding(get: { draft.architecture }, set: { draft.setArchitecture($0) })) {
                    Text("Default (\(Self.architectureTitle(draft.hostArchitecture)))").tag("")
                    Text(Self.architectureTitle("x86_64")).tag("x86_64")
                    Text(Self.architectureTitle("aarch64")).tag("aarch64")
                }
                .accessibilityIdentifier("architecture")
                FieldError(message: errors["arch"])
            } footer: {
                if draft.effectiveArchitecture != draft.hostArchitecture {
                    Text("The vCPU architecture. The node cannot run this one natively, so the VM is emulated and much slower.")
                } else {
                    Text("The vCPU architecture; by default the node's own.")
                }
            }
            Section("Tags") {
                TagsEditor(tags: $draft.tags)
                FieldError(message: errors["tags"])
            }
        }
    }

    static func architectureTitle(_ architecture: String) -> String {
        architecture == "aarch64" ? String(localized: "ARM 64-bit") : String(localized: "x86 64-bit")
    }

    /// High availability needs a cluster.
    private var isCluster: Bool { (connection.snapshot?.nodes.count ?? 0) > 1 }

    @ViewBuilder
    private func operatingSystem(_ errors: [String: String]) -> some View {
        Section {
            VolumePicker(title: "CD/DVD", noneTitle: "No Media", connection: connection, node: draft.node, content: "iso", selection: $draft.isoVolume, reloadID: isoReloadID, offersPhysicalDrive: true)
            FieldError(message: errors[draft.cdromKey])
            NavigationLink("Download from URL") {
                ISODownloadView(connection: connection, node: draft.node) { volume in
                    isoReloadID += 1
                    draft.isoVolume = volume
                }
            }
            .accessibilityIdentifier("iso.download")
        } header: {
            Text("Installation Media")
        } footer: {
            Text("The node downloads the image itself and selects it here when done.")
        }
        Section {
            OSTypePicker(connection: connection, kind: .virtualMachine, selection: Binding(get: { draft.osType }, set: { draft.applyDefaults(for: $0) }), allowed: draft.isARM ? VMCreationDraft.armOSTypes : nil)
            FieldError(message: errors["ostype"])
            if draft.isWindows, !draft.isARM {
                VolumePicker(title: "VirtIO Drivers", noneTitle: "None", connection: connection, node: draft.node, content: "iso", selection: $draft.driversISOVolume)
                FieldError(message: errors["ide0"])
            }
        } header: {
            Text("Guest OS")
        } footer: {
            if draft.isWindows, !draft.isARM {
                Text("Windows gets SATA disks and an Intel network card, which it supports without extra drivers. Add the VirtIO driver ISO to install faster VirtIO drivers.")
            } else {
                Text("The OS type sets hardware defaults on the next pages.")
            }
        }
    }

    @ViewBuilder
    private func system(_ errors: [String: String]) -> some View {
        Section {
            Picker("Graphic Card", selection: $draft.display) {
                ForEach(VMSystemDraft.displays, id: \.id) { Text($0.title).tag($0.id) }
            }
            FieldError(message: errors["vga"])
            if draft.isARM {
                LabeledContent("Machine", value: String(localized: "Default (virt)"))
            } else {
                Picker("Machine", selection: $draft.machine) {
                    Text("Default (i440fx)").tag("i440fx")
                    Text("q35").tag("q35")
                }
            }
            Picker("SCSI Controller", selection: $draft.scsiController) {
                ForEach(draft.isARM ? VMCreationDraft.armSCSIControllers : VMSystemDraft.scsiControllers, id: \.self) { Text($0).tag($0) }
            }
            FieldError(message: errors["scsihw"])
            Toggle("QEMU Guest Agent", isOn: $draft.guestAgent)
        } footer: {
            Text("Enable the guest agent once it is installed in the guest; it reports IP addresses and allows clean shutdowns.")
        }
        Section {
            if draft.isARM {
                LabeledContent("BIOS", value: "OVMF (UEFI)")
            } else {
                Picker("BIOS", selection: $draft.bios) {
                    Text("SeaBIOS").tag("seabios")
                    Text("OVMF (UEFI)").tag("ovmf")
                }
            }
            if draft.bios == "ovmf" {
                Toggle("Add EFI Disk", isOn: $draft.addEFIDisk)
                    .accessibilityIdentifier("efi.add")
                if draft.addEFIDisk {
                    NodeStoragePicker(title: "EFI Storage", connection: connection, node: draft.node, content: "images", selection: $draft.efiStorage, format: $draft.efiFormat)
                    Toggle("Pre-Enrolled Keys", isOn: $draft.preEnrolledKeys)
                }
                FieldError(message: errors["efidisk0"])
            }
        } header: {
            Text("Firmware")
        } footer: {
            if draft.bios == "ovmf" {
                Text(draft.addEFIDisk
                    ? "The EFI disk keeps UEFI settings such as boot entries. Pre-enrolled keys turn on Secure Boot."
                    : "Without an EFI disk, UEFI settings such as boot entries are lost at every start.")
            }
        }
        Section {
            Toggle("Add TPM", isOn: $draft.addTPM)
            if draft.addTPM {
                NodeStoragePicker(title: "TPM Storage", connection: connection, node: draft.node, content: "images", selection: $draft.tpmStorage)
                Picker("Version", selection: $draft.tpmVersion) {
                    Text("v2.0").tag("v2.0")
                    Text("v1.2").tag("v1.2")
                }
                .accessibilityIdentifier("tpm.version")
                FieldError(message: errors["tpmstate0"])
            }
        } header: {
            Text("TPM")
        } footer: {
            Text("A virtual TPM chip, needed by Windows 11 and for measured boot. Its version cannot be changed later.")
        }
    }

    @ViewBuilder
    private func disks(_ errors: [String: String]) -> some View {
        let keys = draft.diskKeys
        ForEach($draft.disks) { $disk in
            let key = draft.disks.firstIndex { $0.id == disk.id }.map { keys[$0] } ?? ""
            NewDiskSections(
                disk: $disk, key: key, error: errors[key], connection: connection, node: draft.node,
                storages: diskStorages, showsAdvanced: showsAdvanced, buses: draft.isARM ? DiskBus.allCases.filter { $0 != .ide } : DiskBus.allCases,
                onRemove: { withAnimation { draft.disks.removeAll { $0.id == disk.id } } }
            )
        }
        Section {
            Button("Add Disk") {
                withAnimation { draft.addDisk() }
            }
            .accessibilityIdentifier("disk.add")
            Button("Import Disk") {
                withAnimation { draft.addImportedDisk() }
            }
            .accessibilityIdentifier("disk.import")
        } footer: {
            if draft.disks.isEmpty {
                Text("The VM is created without a disk. It boots from the installation media or the network.")
            } else {
                Text("Import copies a disk image (qcow2, vmdk or raw) from a storage with import content, e.g. a cloud image.")
            }
        }
        .task(id: draft.node) {
            diskStorages = await connection.load(PVE.storages(node: draft.node, content: "images"))
            for index in draft.disks.indices {
                draft.disks[index].chooseFormat(for: diskStorages.first { $0.storage == draft.disks[index].storage })
            }
        }
    }

    @ViewBuilder
    private func processor(_ errors: [String: String]) -> some View {
        Section {
            NumberField(title: "Sockets", value: $draft.cpu.sockets, range: 1...16)
            FieldError(message: errors["sockets"])
            NumberField(title: "Cores", value: $draft.cpu.cores, range: 1...512)
            FieldError(message: errors["cores"])
            if showsAdvanced {
                Picker("vCPUs at Start", selection: $draft.cpu.vcpus) {
                    Text("All").tag(0)
                    ForEach(1...max(1, totalCores), id: \.self) { Text("\($0)").tag($0) }
                }
                FieldError(message: errors["vcpus"])
            }
        } footer: {
            if showsAdvanced {
                Text("Total: \(Format.cores(totalCores)). With CPU hotplug, fewer vCPUs can be active at start.")
            } else {
                Text("Total: \(Format.cores(totalCores)).")
            }
        }
        .onChange(of: totalCores) {
            if draft.cpu.vcpus > totalCores { draft.cpu.vcpus = 0 }
        }
        Section {
            Picker("Type", selection: $draft.cpu.model) {
                Text(draft.isARM ? "Default (host)" : "Default (kvm64)").tag("")
                ForEach(CPUModel.pickerNames(cpuModels, including: draft.cpu.model), id: \.self) { Text($0).tag($0) }
            }
            FieldError(message: errors["cpu"])
            if showsAdvanced {
                NavigationLink {
                    CPUFlagsEditor(flags: $draft.cpu.flags)
                } label: {
                    LabeledContent("Extra CPU Flags", value: draft.cpu.flags.isEmpty ? String(localized: "None") : "\(draft.cpu.flags.count)")
                }
                Toggle("NUMA", isOn: $draft.cpu.numa)
                FieldError(message: errors["numa"])
            }
        } footer: {
            Text("“host” gives the best performance but prevents live migration to nodes with a different CPU.")
        }
        .task(id: "\(draft.node)/\(draft.effectiveArchitecture)") {
            cpuModels = await connection.load(PVE.cpuModels(node: draft.node, architecture: draft.architecture.isEmpty ? nil : draft.architecture))
        }
        if showsAdvanced {
            Section {
                LabeledContent("CPU Limit") {
                    TextField("Unlimited", value: Binding(get: { draft.cpu.limit > 0 ? draft.cpu.limit : nil }, set: { draft.cpu.limit = $0 ?? 0 }), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                FieldError(message: errors["cpulimit"])
                LabeledContent("CPU Units") {
                    TextField("100", text: $draft.cpu.units)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                FieldError(message: errors["cpuunits"])
                LabeledContent("CPU Affinity") {
                    TextField("All Cores", text: $draft.cpu.affinity)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
                FieldError(message: errors["affinity"])
            } header: {
                Text("Scheduling")
            } footer: {
                Text("Limit is in cores. Units weigh this VM against others when the host is busy. Affinity pins the VM to host cores, e.g. 0-3,8.")
            }
        }
    }

    private var totalCores: Int { draft.cpu.sockets * draft.cpu.cores }


    @ViewBuilder
    private func memory(_ errors: [String: String]) -> some View {
        Section {
            NumberField(title: "Memory", value: $draft.memoryMiB, range: 16...4_194_304, step: 512, unit: "MiB")
            FieldError(message: errors["memory"])
        }
        if showsAdvanced {
            Section {
                Toggle("Ballooning Device", isOn: $draft.ballooning)
                if draft.ballooning {
                    NumberField(title: "Minimum", value: Binding(get: { draft.minimumMemoryMiB == 0 ? draft.memoryMiB : draft.minimumMemoryMiB }, set: { draft.minimumMemoryMiB = $0 }), range: 16...max(16, draft.memoryMiB), step: 256, unit: "MiB")
                    FieldError(message: errors["balloon"])
                    LabeledContent("Shares") {
                        TextField("1000", text: $draft.memoryShares)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    FieldError(message: errors["shares"])
                }
            } footer: {
                Text("With ballooning, the host can reclaim memory down to the minimum when it runs short. Shares weigh this VM against others when memory is reclaimed.")
            }
            Section {
                Toggle("Allow KSM", isOn: $draft.allowKSM)
                FieldError(message: errors["allow-ksm"])
            } footer: {
                Text("Kernel Samepage Merging saves host memory by merging identical memory pages of guests.")
            }
        }
    }

    @ViewBuilder
    private func network(_ errors: [String: String]) -> some View {
        ForEach($draft.networks) { $network in
            let key = draft.networks.firstIndex { $0.id == network.id }.map { "net\($0)" } ?? ""
            Section {
                BridgePicker(connection: connection, node: draft.node, selection: $network.device.bridge)
                OptionalNumberField(title: "VLAN Tag", placeholder: "None", value: $network.device.vlanTag)
                Picker("Model", selection: $network.device.model) {
                    ForEach(NetworkDeviceDraft.models, id: \.self) { Text($0).tag($0) }
                }
                MACAddressField(address: $network.device.macAddress)
                Toggle("Firewall", isOn: $network.device.firewall)
                FieldError(message: errors[key])
                Button("Remove Network Device", role: .destructive) {
                    withAnimation { draft.networks.removeAll { $0.id == network.id } }
                }
                .accessibilityIdentifier("network.remove.\(key)")
            } header: {
                Text(verbatim: key)
            }
            if showsAdvanced {
                Section {
                    Toggle("Disconnected", isOn: $network.device.isDisconnected)
                    RateLimitField(rate: $network.device.rateLimit)
                    OptionalNumberField(title: "MTU", placeholder: "Same as Bridge", value: $network.device.mtu)
                    if network.device.model == "virtio" {
                        Picker("Multiqueue", selection: Binding(get: { network.device.queues ?? 0 }, set: { network.device.queues = $0 == 0 ? nil : $0 })) {
                            Text("Off").tag(0)
                            ForEach([2, 4, 8, 16, 32, 64], id: \.self) { Text("\($0) Queues").tag($0) }
                        }
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Rate limit in MB/s. Multiqueue lets several vCPUs handle network traffic; match it to the vCPU count.")
                }
            }
        }
        Section {
            Button("Add Network Device") {
                withAnimation { draft.addNetworkDevice() }
            }
            .disabled(draft.networks.count >= VMCreationDraft.maximumNetworkDevices)
            .accessibilityIdentifier("network.add")
        } footer: {
            if draft.networks.isEmpty {
                Text("The VM is created without a network device; you can add one later.")
            } else {
                Text("VirtIO is the fastest model; use Intel E1000 for guests without VirtIO drivers.")
            }
        }
    }

    @ViewBuilder
    private var confirm: some View {
        Section {
            Toggle("Start After Creation", isOn: $draft.startAfterCreation)
                .accessibilityIdentifier("startAfterCreation")
        }
        CreationSummary(parameters: draft.parameters)
    }
}

/// One new disk: bus, storage, size and format, then its options. Used by the VM wizard and Add Hard Disk.
struct NewDiskSections: View {
    @Binding var disk: NewVMDisk
    /// `scsi0`, `sata1`…
    let key: String
    let error: String?
    let connection: ServerConnection
    let node: String
    /// The node's storages for disk images, with their formats.
    let storages: [StorageInfo]
    let showsAdvanced: Bool
    /// ARM VMs have no IDE bus.
    var buses = DiskBus.allCases
    /// Device numbers free on each bus, to choose one as the web interface's Bus/Device field does; nil hides the choice.
    var freeSlots: ((DiskBus) -> [Int])?
    @Binding var slot: Int
    var onRemove: (() -> Void)?

    init(disk: Binding<NewVMDisk>, key: String, error: String?, connection: ServerConnection, node: String, storages: [StorageInfo], showsAdvanced: Bool, buses: [DiskBus] = DiskBus.allCases, freeSlots: ((DiskBus) -> [Int])? = nil, slot: Binding<Int> = .constant(0), onRemove: (() -> Void)? = nil) {
        _disk = disk
        self.key = key
        self.error = error
        self.connection = connection
        self.node = node
        self.storages = storages
        self.showsAdvanced = showsAdvanced
        self.buses = buses
        self.freeSlots = freeSlots
        _slot = slot
        self.onRemove = onRemove
    }

    var body: some View {
        Section {
            Picker("Bus", selection: $disk.bus) {
                ForEach(buses) { Text($0.title).tag($0) }
                if !buses.contains(disk.bus) { Text(disk.bus.title).tag(disk.bus) }
            }
            if let freeSlots {
                Picker("Device", selection: $slot) {
                    ForEach(freeSlots(disk.bus), id: \.self) { Text(String($0)).tag($0) }
                }
                .accessibilityIdentifier("disk.slot")
            }
            if disk.isImport {
                VolumePicker(
                    title: "Image", connection: connection, node: node, content: "import", selection: importSource,
                    filter: { ["qcow2", "vmdk", "raw"].contains($0.format ?? "") }
                )
                .accessibilityIdentifier("disk.importSource")
            }
            NodeStoragePicker(title: disk.isImport ? "Target Storage" : "Storage", connection: connection, node: node, content: "images", selection: $disk.storage)
            if !disk.isImport {
                NumberField(title: "Size", value: $disk.sizeGiB, range: 1...65_536, unit: "GiB")
            }
            if let formats = storage?.diskFormats, formats.count > 1 {
                DiskFormatPicker(formats: formats, selection: $disk.format)
            }
            FieldError(message: error)
        } header: {
            Text(verbatim: disk.isImport ? String(localized: "\(key) – Import") : key)
        } footer: {
            if disk.isImport {
                Text("The disk gets the size of the image.")
            }
        }
        .onChange(of: disk.storage) { disk.chooseFormat(for: storage) }
        Section {
            Picker("Cache", selection: $disk.options.cache) {
                Text("Default (No cache)").tag(String?.none)
                ForEach(DiskOptionsDraft.cacheModes, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Toggle("Discard", isOn: $disk.options.discard)
            if disk.supportsIOThread {
                Toggle("IO Thread", isOn: $disk.options.ioThread)
            }
            if showsAdvanced {
                if disk.supportsSSDEmulation {
                    Toggle("SSD Emulation", isOn: $disk.options.ssdEmulation)
                }
                if disk.supportsIOThread {
                    Toggle("Read Only", isOn: $disk.options.readOnly)
                }
                Toggle("Include in Backups", isOn: $disk.options.includeInBackup)
                Toggle("Replicate", isOn: $disk.options.replicate)
                Picker("Async IO", selection: $disk.options.asyncIO) {
                    Text("Default (io_uring)").tag(String?.none)
                    ForEach(DiskOptionsDraft.asyncIOModes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                NavigationLink {
                    DiskLimitsEditor(limits: $disk.options.limits)
                } label: {
                    LabeledContent("Bandwidth Limits", value: disk.options.limits.values.contains { !$0.isEmpty } ? String(localized: "Set") : String(localized: "Unlimited"))
                }
            }
            if let onRemove {
                Button("Remove Disk", role: .destructive, action: onRemove)
                    .accessibilityIdentifier("disk.remove.\(key)")
            }
        } header: {
            Text("Options")
        }
    }

    private var storage: StorageInfo? { storages.first { $0.storage == disk.storage } }

    private var importSource: Binding<String?> {
        Binding(get: { disk.importSource.isEmpty ? nil : disk.importSource }, set: { disk.importSource = $0 ?? "" })
    }
}
