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
        case .general: ["vmid", "name", "pool", "ha-managed", "onboot", "startup", "tags"].contains(parameter)
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
        ["onboot", "startup", "tags", "vcpus", "cpulimit", "cpuunits", "affinity", "numa", "balloon", "shares", "allow-ksm"].contains(parameter)
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
        if showsAdvanced {
            StartupSection(startAtBoot: $draft.startOnBoot, startup: $draft.startup, error: errors["startup"])
            Section("Tags") {
                TagsEditor(tags: $draft.tags)
                FieldError(message: errors["tags"])
            }
        }
    }

    /// High availability needs a cluster.
    private var isCluster: Bool { (connection.snapshot?.nodes.count ?? 0) > 1 }

    @ViewBuilder
    private func operatingSystem(_ errors: [String: String]) -> some View {
        Section {
            VolumePicker(title: "ISO Image", noneTitle: "No Media", connection: connection, node: draft.node, content: "iso", selection: $draft.isoVolume, reloadID: isoReloadID)
            FieldError(message: errors["ide2"])
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
            OSTypePicker(connection: connection, kind: .virtualMachine, selection: Binding(get: { draft.osType }, set: { draft.applyDefaults(for: $0) }))
            FieldError(message: errors["ostype"])
            if draft.isWindows {
                VolumePicker(title: "VirtIO Drivers", noneTitle: "None", connection: connection, node: draft.node, content: "iso", selection: $draft.driversISOVolume)
                FieldError(message: errors["ide0"])
            }
        } header: {
            Text("Guest OS")
        } footer: {
            if draft.isWindows {
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
            Picker("Machine", selection: $draft.machine) {
                Text("Default (i440fx)").tag("i440fx")
                Text("q35").tag("q35")
            }
            Picker("SCSI Controller", selection: $draft.scsiController) {
                ForEach(VMSystemDraft.scsiControllers, id: \.self) { Text($0).tag($0) }
            }
            FieldError(message: errors["scsihw"])
            Toggle("QEMU Guest Agent", isOn: $draft.guestAgent)
        } footer: {
            Text("Enable the guest agent once it is installed in the guest; it reports IP addresses and allows clean shutdowns.")
        }
        Section {
            Picker("BIOS", selection: $draft.bios) {
                Text("SeaBIOS").tag("seabios")
                Text("OVMF (UEFI)").tag("ovmf")
            }
            if draft.bios == "ovmf" {
                NodeStoragePicker(title: "EFI Storage", connection: connection, node: draft.node, content: "images", selection: $draft.efiStorage)
                Toggle("Pre-Enrolled Keys", isOn: $draft.preEnrolledKeys)
                FieldError(message: errors["efidisk0"])
            }
        } header: {
            Text("Firmware")
        } footer: {
            if draft.bios == "ovmf" {
                Text("Pre-enrolled keys turn on Secure Boot.")
            }
        }
        Section {
            Toggle("Add TPM", isOn: $draft.addTPM)
            if draft.addTPM {
                NodeStoragePicker(title: "TPM Storage", connection: connection, node: draft.node, content: "images", selection: $draft.tpmStorage)
                FieldError(message: errors["tpmstate0"])
            }
        } header: {
            Text("TPM")
        } footer: {
            Text("A virtual TPM chip, needed by Windows 11 and for measured boot.")
        }
    }

    @ViewBuilder
    private func disks(_ errors: [String: String]) -> some View {
        Section {
            Picker("Bus", selection: $draft.diskBus) {
                ForEach(DiskBus.allCases) { Text($0.title).tag($0) }
            }
            NodeStoragePicker(title: "Storage", connection: connection, node: draft.node, content: "images", selection: $draft.diskStorage)
            NumberField(title: "Size", value: $draft.diskSizeGiB, range: 1...65_536, unit: "GiB")
            if let formats = selectedDiskStorage?.diskFormats, formats.count > 1 {
                Picker("Format", selection: $draft.diskFormat) {
                    ForEach(formats, id: \.self) { Text(Self.formatTitle($0)).tag(String?.some($0)) }
                }
            }
            FieldError(message: errors[draft.diskKey])
        } header: {
            Text(verbatim: draft.diskKey)
        }
        .task(id: draft.node) {
            diskStorages = await connection.load(PVE.storages(node: draft.node, content: "images"))
            draft.chooseDiskFormat(for: selectedDiskStorage)
        }
        .onChange(of: draft.diskStorage) { draft.chooseDiskFormat(for: selectedDiskStorage) }
        Section("Options") {
            Picker("Cache", selection: $draft.disk.cache) {
                Text("Default (No cache)").tag(String?.none)
                ForEach(DiskOptionsDraft.cacheModes, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Toggle("Discard", isOn: $draft.disk.discard)
            if draft.diskSupportsIOThread {
                Toggle("IO Thread", isOn: $draft.disk.ioThread)
            }
            if showsAdvanced {
                if draft.diskSupportsSSDEmulation {
                    Toggle("SSD Emulation", isOn: $draft.disk.ssdEmulation)
                }
                if draft.diskSupportsIOThread {
                    Toggle("Read Only", isOn: $draft.disk.readOnly)
                }
                Toggle("Include in Backups", isOn: $draft.disk.includeInBackup)
                Toggle("Replicate", isOn: $draft.disk.replicate)
                Picker("Async IO", selection: $draft.disk.asyncIO) {
                    Text("Default (io_uring)").tag(String?.none)
                    ForEach(DiskOptionsDraft.asyncIOModes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                NavigationLink {
                    DiskLimitsEditor(limits: $draft.disk.limits)
                } label: {
                    LabeledContent("Bandwidth Limits", value: draft.disk.limits.values.contains { !$0.isEmpty } ? String(localized: "Set") : String(localized: "Unlimited"))
                }
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
                Text("Default (kvm64)").tag("")
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
        .task(id: draft.node) { cpuModels = await connection.load(PVE.cpuModels(node: draft.node)) }
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

    private var selectedDiskStorage: StorageInfo? { diskStorages.first { $0.storage == draft.diskStorage } }

    private static func formatTitle(_ format: String) -> String {
        switch format {
        case "raw": String(localized: "Raw Disk Image (raw)")
        case "qcow2": String(localized: "QEMU Image (qcow2)")
        case "vmdk": String(localized: "VMware Image (vmdk)")
        default: format
        }
    }

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
        Section {
            Toggle("Network Device", isOn: $draft.hasNetwork)
        } footer: {
            if !draft.hasNetwork {
                Text("The VM is created without a network device; you can add one later.")
            }
        }
        if draft.hasNetwork {
            Section {
                BridgePicker(connection: connection, node: draft.node, selection: $draft.network.bridge)
                OptionalNumberField(title: "VLAN Tag", placeholder: "None", value: $draft.network.vlanTag)
                Picker("Model", selection: $draft.network.model) {
                    ForEach(NetworkDeviceDraft.models, id: \.self) { Text($0).tag($0) }
                }
                MACAddressField(address: $draft.network.macAddress)
                Toggle("Firewall", isOn: $draft.network.firewall)
                FieldError(message: errors["net0"])
            } footer: {
                Text("VirtIO is the fastest model; use Intel E1000 for guests without VirtIO drivers.")
            }
            if showsAdvanced {
                Section {
                    Toggle("Disconnected", isOn: $draft.network.isDisconnected)
                    RateLimitField(rate: $draft.network.rateLimit)
                    OptionalNumberField(title: "MTU", placeholder: "Same as Bridge", value: $draft.network.mtu)
                    if draft.network.model == "virtio" {
                        Picker("Multiqueue", selection: Binding(get: { draft.network.queues ?? 0 }, set: { draft.network.queues = $0 == 0 ? nil : $0 })) {
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
