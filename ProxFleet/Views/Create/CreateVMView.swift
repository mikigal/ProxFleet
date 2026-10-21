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
        case .general: ["vmid", "name", "pool", "onboot"].contains(parameter)
        case .os: ["ostype", "ide0", "ide2"].contains(parameter)
        case .system: ["machine", "bios", "efidisk0", "tpmstate0", "scsihw", "agent"].contains(parameter)
        case .disks: Self.isDiskKey(parameter)
        case .cpu: ["sockets", "cores", "cpu"].contains(parameter)
        case .memory: ["memory", "balloon"].contains(parameter)
        case .network: parameter.hasPrefix("net")
        case .confirm: false
        }
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
            onCreated: onCreated
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
            PoolPicker(pools: pools, selection: $draft.pool)
        }
        .task { pools = await connection.load(PVE.pools()) }
        Section {
            Toggle("Start at Boot", isOn: $draft.startOnBoot)
        } footer: {
            Text("Starts the VM when the node boots.")
        }
    }

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
            Text("The node downloads the image itself and selects it here when done. Uploads from this device are on the storage screen.")
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
            FieldError(message: errors[draft.diskKey])
        } header: {
            Text(verbatim: draft.diskKey)
        }
        Section("Options") {
            Toggle("Discard", isOn: $draft.discard)
            if draft.diskBus == .scsi || draft.diskBus == .virtio {
                Toggle("IO Thread", isOn: $draft.ioThread)
            }
            if draft.diskBus != .virtio {
                Toggle("SSD Emulation", isOn: $draft.ssdEmulation)
            }
        }
    }

    @ViewBuilder
    private func processor(_ errors: [String: String]) -> some View {
        Section {
            NumberField(title: "Sockets", value: $draft.sockets, range: 1...16)
            FieldError(message: errors["sockets"])
            NumberField(title: "Cores", value: $draft.cores, range: 1...512)
            FieldError(message: errors["cores"])
        } footer: {
            Text("Total: \(Format.cores(draft.sockets * draft.cores)).")
        }
        Section {
            Picker("Type", selection: $draft.cpuType) {
                Text("Default (kvm64)").tag("")
                ForEach(CPUModel.pickerNames(cpuModels, including: draft.cpuType), id: \.self) { Text($0).tag($0) }
            }
            FieldError(message: errors["cpu"])
        } footer: {
            Text("“host” gives the best performance but prevents live migration to nodes with a different CPU.")
        }
        .task(id: draft.node) { cpuModels = await connection.load(PVE.cpuModels(node: draft.node)) }
    }

    @ViewBuilder
    private func memory(_ errors: [String: String]) -> some View {
        Section {
            NumberField(title: "Memory", value: $draft.memoryMiB, range: 16...4_194_304, step: 512, unit: "MiB")
            FieldError(message: errors["memory"])
        }
        Section {
            Toggle("Ballooning", isOn: $draft.ballooning)
            if draft.ballooning {
                NumberField(title: "Minimum", value: Binding(get: { draft.minimumMemoryMiB == 0 ? draft.memoryMiB : draft.minimumMemoryMiB }, set: { draft.minimumMemoryMiB = $0 }), range: 16...max(16, draft.memoryMiB), step: 256, unit: "MiB")
                FieldError(message: errors["balloon"])
            }
        } footer: {
            Text("With ballooning, the host can reclaim memory down to the minimum when it runs short.")
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
                Toggle("Firewall", isOn: $draft.network.firewall)
                FieldError(message: errors["net0"])
            } footer: {
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
