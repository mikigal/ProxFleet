import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Creates a VM: installation media, hardware and network in one form, with the web interface's defaults.
struct CreateVMView: View {
    let connection: ServerConnection
    let onCreated: (GuestReference) -> Void
    @State private var pools: [ResourcePool] = []
    @State private var draft: VMCreationDraft
    @State private var cpuModels: [CPUModel] = []

    init(connection: ServerConnection, onCreated: @escaping (GuestReference) -> Void) {
        self.connection = connection
        self.onCreated = onCreated
        _draft = State(initialValue: VMCreationDraft(node: NodePicker.defaultNode(connection), vmid: 0))
    }

    var body: some View {
        CreationForm(
            title: "New Virtual Machine",
            connection: connection,
            reference: GuestReference(node: draft.node, vmid: draft.vmid, kind: .virtualMachine),
            problems: draft.problems,
            makeRequest: { PVE.createVM(draft) },
            onCreated: onCreated
        ) { errors in
            Section("General") {
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
                VolumePicker(title: "ISO Image", noneTitle: "No Media", connection: connection, node: draft.node, content: "iso", selection: $draft.isoVolume)
                FieldError(message: errors["ide2"])
                OSTypePicker(connection: connection, kind: .virtualMachine, selection: Binding(get: { draft.osType }, set: { draft.applyDefaults(for: $0) }))
                if draft.isWindows {
                    VolumePicker(title: "VirtIO Drivers", noneTitle: "None", connection: connection, node: draft.node, content: "iso", selection: $draft.driversISOVolume)
                }
            } header: {
                Text("Operating System")
            } footer: {
                if draft.isWindows {
                    Text("Windows gets SATA disks and an Intel network card, which it supports without extra drivers. Add the VirtIO driver ISO to install faster VirtIO drivers.")
                } else {
                    Text("Upload ISO images in the web interface or download them to a storage with ISO content.")
                }
            }

            Section {
                Picker("Machine", selection: $draft.machine) {
                    Text("Default (i440fx)").tag("i440fx")
                    Text("q35").tag("q35")
                }
                Picker("Firmware", selection: $draft.bios) {
                    Text("SeaBIOS").tag("seabios")
                    Text("OVMF (UEFI)").tag("ovmf")
                }
                if draft.bios == "ovmf" {
                    NodeStoragePicker(title: "EFI Disk Storage", connection: connection, node: draft.node, content: "images", selection: $draft.efiStorage)
                    Toggle("Pre-Enrolled Keys", isOn: $draft.preEnrolledKeys)
                    FieldError(message: errors["efidisk0"])
                }
                Toggle("TPM", isOn: $draft.addTPM)
                if draft.addTPM {
                    NodeStoragePicker(title: "TPM Storage", connection: connection, node: draft.node, content: "images", selection: $draft.tpmStorage)
                    FieldError(message: errors["tpmstate0"])
                }
                Picker("SCSI Controller", selection: $draft.scsiController) {
                    ForEach(VMSystemDraft.scsiControllers, id: \.self) { Text($0).tag($0) }
                }
                Toggle("QEMU Guest Agent", isOn: $draft.guestAgent)
            } header: {
                Text("System")
            } footer: {
                if draft.bios == "ovmf" {
                    Text("Pre-enrolled keys turn on Secure Boot. Enable the guest agent once it is installed in the guest; it reports IP addresses and allows clean shutdowns.")
                } else {
                    Text("Enable the guest agent once it is installed in the guest; it reports IP addresses and allows clean shutdowns.")
                }
            }

            Section("Disk") {
                Picker("Bus", selection: $draft.diskBus) {
                    ForEach(DiskBus.allCases) { Text($0.title).tag($0) }
                }
                NodeStoragePicker(title: "Storage", connection: connection, node: draft.node, content: "images", selection: $draft.diskStorage)
                NumberField(title: "Size", value: $draft.diskSizeGiB, range: 1...65_536, unit: "GiB")
                FieldError(message: errors[draft.diskKey])
                Toggle("Discard", isOn: $draft.discard)
                if draft.diskBus == .scsi || draft.diskBus == .virtio {
                    Toggle("IO Thread", isOn: $draft.ioThread)
                }
                if draft.diskBus != .virtio {
                    Toggle("SSD Emulation", isOn: $draft.ssdEmulation)
                }
            }

            Section {
                NumberField(title: "Sockets", value: $draft.sockets, range: 1...16)
                FieldError(message: errors["sockets"])
                NumberField(title: "Cores", value: $draft.cores, range: 1...512)
                FieldError(message: errors["cores"])
                Picker("Type", selection: $draft.cpuType) {
                    Text("Default (kvm64)").tag("")
                    ForEach(CPUModel.pickerNames(cpuModels, including: draft.cpuType), id: \.self) { Text($0).tag($0) }
                }
                FieldError(message: errors["cpu"])
            } header: {
                Text("Processor")
            } footer: {
                Text("Total: \(Format.cores(draft.sockets * draft.cores)). “host” gives the best performance but prevents live migration to nodes with a different CPU.")
            }
            .task(id: draft.node) { cpuModels = await connection.load(PVE.cpuModels(node: draft.node)) }

            Section {
                NumberField(title: "Memory", value: $draft.memoryMiB, range: 16...4_194_304, step: 512, unit: "MiB")
                FieldError(message: errors["memory"])
                Toggle("Ballooning", isOn: $draft.ballooning)
                if draft.ballooning {
                    NumberField(title: "Minimum", value: Binding(get: { draft.minimumMemoryMiB == 0 ? draft.memoryMiB : draft.minimumMemoryMiB }, set: { draft.minimumMemoryMiB = $0 }), range: 16...max(16, draft.memoryMiB), step: 256, unit: "MiB")
                    FieldError(message: errors["balloon"])
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("With ballooning, the host can reclaim memory down to the minimum when it runs short.")
            }

            Section {
                Toggle("Network Device", isOn: $draft.hasNetwork)
                if draft.hasNetwork {
                    BridgePicker(connection: connection, node: draft.node, selection: $draft.network.bridge)
                    OptionalNumberField(title: "VLAN Tag", placeholder: "None", value: $draft.network.vlanTag)
                    Picker("Model", selection: $draft.network.model) {
                        ForEach(NetworkDeviceDraft.models, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Firewall", isOn: $draft.network.firewall)
                    FieldError(message: errors["net0"])
                }
            } header: {
                Text("Network")
            }

            Section {
                Toggle("Start at Boot", isOn: $draft.startOnBoot)
                Toggle("Start After Creation", isOn: $draft.startAfterCreation)
                    .accessibilityIdentifier("startAfterCreation")
            }
        }
    }
}
