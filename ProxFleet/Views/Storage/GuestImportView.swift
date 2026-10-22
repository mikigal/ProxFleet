import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Imports an OVA, OVF or ESXi guest as a new VM, like the web interface's Import Guest dialog. Loads what the server
/// recognised first, then shows the form.
struct GuestImportView: View {
    let connection: ServerConnection
    let node: String
    /// For example `local:import/appliance.ova` or `esxi:ha-datacenter/datastore1/vm/vm.vmx`.
    let volume: String
    let onCreated: (GuestReference) -> Void
    @State private var draft: GuestImportDraft?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let draft = Binding($draft) {
                GuestImportForm(connection: connection, draft: draft, onCreated: onCreated)
            } else if let errorMessage {
                ContentUnavailableView("Cannot Read the Guest", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("Reading \(volume.split(separator: "/").last.map(String.init) ?? volume)…")
            }
        }
        .navigationTitle("Import Guest")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let metadata = try await connection.send(PVE.importMetadata(node: node, volume: volume))
                draft = GuestImportDraft(metadata: metadata, node: node, volume: volume)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct GuestImportForm: View {
    let connection: ServerConnection
    @Binding var draft: GuestImportDraft
    let onCreated: (GuestReference) -> Void
    @State private var pools: [ResourcePool] = []
    @State private var cpuModels: [CPUModel] = []
    @State private var storages: [StorageInfo] = []
    @State private var showsAdvanced = false

    private var node: String { draft.node }

    var body: some View {
        CreationWizard<SinglePageStep, _>(
            title: "Import Guest",
            connection: connection,
            reference: GuestReference(node: node, vmid: draft.vmid, kind: .virtualMachine),
            problems: draft.problems,
            makeRequest: { PVE.importGuest(draft) },
            onCreated: onCreated,
            actionTitle: "Import",
            workingTitle: "Importing VM \(String(draft.vmid))…",
            showsAdvancedOptions: $showsAdvanced
        ) { _, errors in
            if !draft.warnings.isEmpty {
                Section {
                    ForEach(Array(draft.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning.text, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                LabeledContent("Source", value: draft.volume.split(separator: "/").last.map(String.init) ?? draft.volume)
                GuestIDField(connection: connection, vmid: $draft.vmid, error: errors["vmid"])
                LabeledContent("Name") {
                    TextField("Optional", text: $draft.name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                FieldError(message: errors["name"])
                PoolPicker(pools: pools, selection: $draft.pool)
                OSTypePicker(connection: connection, kind: .virtualMachine, selection: $draft.osType)
            }
            .task { pools = await connection.load(PVE.pools()) }
            Section {
                NumberField(title: "Sockets", value: $draft.sockets, range: 1...16)
                NumberField(title: "Cores", value: $draft.cores, range: 1...512)
                Picker("CPU Type", selection: $draft.cpuModel) {
                    Text("Default (kvm64)").tag("")
                    ForEach(CPUModel.pickerNames(cpuModels, including: draft.cpuModel), id: \.self) { Text($0).tag($0) }
                }
                NumberField(title: "Memory", value: $draft.memoryMiB, range: 16...4_194_304, step: 512, unit: "MiB")
            }
            .task { cpuModels = await connection.load(PVE.cpuModels(node: node)) }
            Section {
                NodeStoragePicker(title: "Default Storage", connection: connection, node: node, content: "images", selection: $draft.defaultStorage, format: $draft.defaultFormat)
                FieldError(message: errors["storage"])
                if draft.needsExtracting {
                    NodeStoragePicker(title: "Working Storage", connection: connection, node: node, content: "images", selection: $draft.workingStorage, defaultTitle: "Source Storage")
                    FieldError(message: errors["import-working-storage"])
                }
                BridgePicker(connection: connection, node: node, selection: $draft.defaultBridge)
                FieldError(message: errors["bridge"])
                Toggle("Live Import", isOn: $draft.liveImport)
            } header: {
                Text("Target")
            } footer: {
                if draft.liveImport {
                    Text("The VM starts right away and the disks are imported in the background. If anything goes wrong during the import, data the VM writes meanwhile may be lost.")
                } else if draft.needsExtracting {
                    Text("The working storage must hold disk images as files, e.g. a directory storage; the archive is extracted there first.")
                }
            }
            .task(id: node) { storages = await connection.load(PVE.storages(node: node, content: "images")).filter(\.isActive) }
            if showsAdvanced {
                advancedSections(errors)
            }
        }
    }

    @ViewBuilder
    private func advancedSections(_ errors: [String: String]) -> some View {
        Section {
            Picker("SCSI Controller", selection: $draft.scsiController) {
                Text("Default (LSI 53C895A)").tag("")
                ForEach(VMSystemDraft.scsiControllers, id: \.self) { Text($0).tag($0) }
            }
            if draft.isWindows {
                Toggle("Prepare for VirtIO SCSI", isOn: $draft.prepareForVirtIOSCSI)
                    .onChange(of: draft.prepareForVirtIOSCSI) { _, on in if on { draft.scsiController = "virtio-scsi-single" } }
            }
        } footer: {
            if draft.isWindows {
                Text("Preparing for VirtIO SCSI attaches SCSI disks as SATA, so Windows boots before its VirtIO drivers are installed.")
            }
        }
        if !draft.disks.isEmpty {
            Section("Disks") {
                let slots = draft.diskSlots
                ForEach($draft.disks) { $disk in
                    Toggle(isOn: $disk.isEnabled) {
                        VStack(alignment: .leading) {
                            Text(slots[disk.id].map { "\(disk.id) → \($0)" } ?? disk.id)
                            Text([disk.source.split(separator: "/").last.map(String.init), disk.size.map(Format.bytes)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if disk.isEnabled {
                        Picker("Storage for \(disk.id)", selection: $disk.storage) {
                            Text("Default Storage").tag("")
                            ForEach(storages) { Text(NodeStoragePicker.label($0)).tag($0.storage) }
                        }
                        .onChange(of: disk.storage) { _, storage in disk.format = storages.first { $0.storage == storage }?.preferredDiskFormat }
                        if let formats = storages.first(where: { $0.storage == disk.storage })?.diskFormats, formats.count > 1 {
                            DiskFormatPicker(formats: formats, selection: $disk.format)
                        }
                    }
                }
            }
        }
        if !draft.visibleCDROMs.isEmpty {
            Section {
                ForEach($draft.cdroms) { $cdrom in
                    if !cdrom.isForDrivers || draft.isWindows {
                        Toggle(cdrom.id, isOn: $cdrom.isEnabled)
                        if cdrom.isEnabled {
                            VolumePicker(title: "Image", noneTitle: "None", connection: connection, node: node, content: "iso", selection: $cdrom.isoVolume)
                        }
                    }
                }
            } header: {
                Text("CD/DVD Drives")
            } footer: {
                if draft.cdroms.contains(where: \.isForDrivers) {
                    Text("Attach the VirtIO driver ISO for Windows here.")
                }
            }
        }
        if !draft.networks.isEmpty {
            Section {
                ForEach($draft.networks) { $network in
                    Toggle(isOn: $network.isEnabled) {
                        VStack(alignment: .leading) {
                            Text(network.id)
                            Text(draft.uniqueMACAddresses || network.macAddress == nil ? String(localized: "New MAC address") : network.macAddress ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if network.isEnabled {
                        Picker("Model", selection: $network.model) {
                            ForEach(Set(NetworkDeviceDraft.models + [network.model]).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                        BridgePickerWithDefault(connection: connection, node: node, selection: $network.bridge)
                        OptionalNumberField(title: "VLAN Tag", placeholder: "None", value: $network.vlanTag)
                    }
                }
                Toggle("Unique MAC Addresses", isOn: $draft.uniqueMACAddresses)
            } header: {
                Text("Network")
            } footer: {
                Text("Give the VM new MAC addresses when the source guest keeps running on the same network.")
            }
        }
    }
}

/// A bridge for one network device, or the default bridge of the import.
private struct BridgePickerWithDefault: View {
    let connection: ServerConnection
    let node: String
    @Binding var selection: String
    @State private var bridges: [NodeNetworkInterface] = []

    var body: some View {
        Picker("Bridge", selection: $selection) {
            Text("Default Bridge").tag("")
            ForEach(bridges, id: \.name) { Text($0.name).tag($0.name) }
        }
        .task(id: node) { bridges = await connection.load(PVE.bridges(node: node)) }
    }
}

/// Imports a disk image into an existing VM: choose the VM, then the Add Hard Disk form with the image preset.
struct ImportDiskTargetView: View {
    let connection: ServerConnection
    let node: String
    let volume: String

    private var vms: [GuestSummary] {
        (connection.snapshot?.guests ?? []).filter { $0.kind == .virtualMachine && $0.node == node && !$0.isTemplate }
            .sorted { $0.vmid < $1.vmid }
    }

    var body: some View {
        List {
            Section {
                ForEach(vms) { guest in
                    NavigationLink {
                        ImportDiskLoader(connection: connection, reference: GuestReference(node: node, vmid: guest.vmid, kind: .virtualMachine), volume: volume)
                    } label: {
                        LabeledContent(guest.name, value: String(guest.vmid))
                    }
                }
            } footer: {
                Text(vms.isEmpty ? "There is no VM on \(node) to import the disk into." : "The image is copied into a new disk of the VM.")
            }
        }
        .navigationTitle("Import as Disk")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Loads the chosen VM, then shows Add Hard Disk importing the image.
private struct ImportDiskLoader: View {
    @State private var detail: GuestDetail
    let volume: String

    init(connection: ServerConnection, reference: GuestReference, volume: String) {
        _detail = State(initialValue: GuestDetail(reference: reference, connection: connection))
        self.volume = volume
    }

    var body: some View {
        Group {
            if let config = detail.config {
                AddDiskEditor(detail: detail, config: config, importSource: volume)
            } else if let error = detail.loadError {
                ContentUnavailableView("Cannot Load the VM", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .task { await detail.load() }
    }
}
