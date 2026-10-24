import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// PCI, USB and directory mappings: names guests use for host devices and directories, with an entry per node.
struct ResourceMappingsView: View {
    @State private var list: ResourceMappingList
    @State private var creating: ResourceMappingKind?
    @State private var deleting: (kind: ResourceMappingKind, id: String)?
    @State private var errorMessage: String?

    init(connection: ServerConnection) {
        _list = State(initialValue: ResourceMappingList(connection: connection))
    }

    var body: some View {
        List {
            ForEach(ResourceMappingKind.allCases) { kind in
                if let mappings = list.mappings[kind] {
                    Section {
                        if mappings.isEmpty {
                            Text("None").foregroundStyle(.secondary)
                        }
                        ForEach(mappings) { mapping in
                            NavigationLink {
                                ResourceMappingEditor(list: list, kind: kind, mapping: mapping)
                            } label: {
                                MappingRow(kind: kind, mapping: mapping)
                            }
                            .accessibilityIdentifier("mapping.\(kind.rawValue).\(mapping.id)")
                            .swipeActions {
                                if list.canModify {
                                    Button("Delete", systemImage: "trash") { deleting = (kind, mapping.id) }
                                        .tint(.red)
                                }
                            }
                        }
                    } header: {
                        Text(kind.title)
                    }
                }
            }
            if let error = list.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .overlay { if list.mappings.isEmpty, list.loadError == nil { ProgressView() } }
        .navigationTitle("Resource Mappings")
        .refreshable { await list.load() }
        .task { await list.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("PCI Device", systemImage: "cpu") { creating = .pci }
                        .accessibilityIdentifier("mapping.add.pci")
                    Button("USB Device", systemImage: "cable.connector") { creating = .usb }
                        .accessibilityIdentifier("mapping.add.usb")
                    if list.connection.supports(.directoryMappings) {
                        Button("Directory", systemImage: "folder") { creating = .dir }
                            .accessibilityIdentifier("mapping.add.dir")
                    }
                }
                .disabled(!list.canModify)
                .accessibilityIdentifier("mapping.add")
            }
        }
        .sheet(item: $creating) { kind in
            NavigationStack { ResourceMappingEditor(list: list, kind: kind, mapping: nil) }
        }
        .confirmationDialog("Delete the mapping \(deleting?.id ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let deleting else { return }
                Task {
                    do { try await list.delete(deleting.kind, id: deleting.id) } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: {
            Text("Guests that use it cannot start until a mapping of that name exists again.")
        }
        .alert("Mapping Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct MappingRow: View {
    let kind: ResourceMappingKind
    let mapping: ResourceMappingDetail

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .pci ? "cpu" : kind == .usb ? "cable.connector" : "folder")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mapping.id).font(.body.weight(.medium))
                    if mapping.mdev { AccessBadge(text: "Mediated") }
                }
                Text([mapping.description, entriesSummary].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if mapping.checks.contains(where: { $0.severity == "error" }) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if !mapping.checks.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var entriesSummary: String? {
        let paths = mapping.entries.compactMap { $0["path"] ?? $0["id"] }
        guard !paths.isEmpty else { return nil }
        return Array(Set(paths)).sorted().joined(separator: ", ")
    }
}

// MARK: - Editor

struct ResourceMappingEditor: View {
    let list: ResourceMappingList
    let kind: ResourceMappingKind
    let mapping: ResourceMappingDetail?
    let original: ResourceMappingDraft
    @State private var draft: ResourceMappingDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(list: ResourceMappingList, kind: ResourceMappingKind, mapping: ResourceMappingDetail?) {
        self.list = list
        self.kind = kind
        self.mapping = mapping
        let draft = mapping.map { ResourceMappingDraft(kind: kind, $0) } ?? ResourceMappingDraft(kind: kind)
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { mapping == nil }
    private var nodes: [String] { list.connection.snapshot?.nodes.map(\.name) ?? [] }

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: isNew) : [:]).merging(fieldErrors) { _, server in server }
    }

    var body: some View {
        Form {
            if let checks = mapping?.checks, !checks.isEmpty {
                Section {
                    ForEach(checks, id: \.self) { check in
                        Label(check.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(check.severity == "error" ? .red : .orange)
                    }
                } footer: {
                    Text("Found on \(list.checkedNode ?? "") when the list was loaded.")
                }
            }
            Group {
                Section {
                    if isNew {
                        LabeledTextField(title: "Name", prompt: kind == .dir ? "media" : "gpu", text: $draft.id, identifier: "mapping.id")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        FieldError(message: errors["id"])
                    }
                    LabeledTextField(title: "Description", prompt: "None", text: $draft.description, identifier: "mapping.description")
                    if kind == .pci {
                        Toggle("Mediated Devices", isOn: $draft.mdev)
                            .accessibilityIdentifier("mapping.mdev")
                        Toggle("Live Migration", isOn: $draft.liveMigration)
                    }
                } footer: {
                    switch kind {
                    case .pci: Text("Mediated devices: the devices offer vGPU profiles, which VMs pick instead of the whole device. Live migration is experimental and needs hardware and driver support.")
                    case .usb: Text("VMs pass the mapped device through by this name on whichever node they run.")
                    case .dir: Text("VMs share the mapped directory with virtiofs by this name.")
                    }
                }
                ForEach(nodes, id: \.self) { node in
                    nodeSection(node)
                }
                FieldError(message: errors["map"])
            }
            .disabled(!list.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? Text(newTitle) : Text(verbatim: draft.id))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if list.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!isNew && draft.changes(from: original).isEmpty)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private var newTitle: LocalizedStringKey {
        switch kind {
        case .pci: "New PCI Mapping"
        case .usb: "New USB Mapping"
        case .dir: "New Directory Mapping"
        }
    }

    @ViewBuilder
    private func nodeSection(_ node: String) -> some View {
        let entries = draft.entries(on: node)
        Section {
            switch kind {
            case .dir:
                LabeledTextField(title: "Path", prompt: "/mnt/data", text: Binding(get: { entries.first?["path"] ?? "" }, set: { path in
                    draft.setEntries(path.isEmpty ? [] : [ResourceMappingDraft.directoryEntry(path, node: node)], on: node)
                }), identifier: "mapping.path.\(node)")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            case .pci, .usb:
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry["path"] ?? entry["id"] ?? "–").font(.body.monospaced())
                        Text(entryDetails(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    MappingDevicePicker(list: list, kind: kind, node: node, mdevOnly: draft.mdev, selection: Binding(get: { draft.entries(on: node) }, set: {
                        draft.setEntries($0, on: node)
                    }))
                } label: {
                    Text(entries.isEmpty ? "Choose Device" : "Change")
                }
                .accessibilityIdentifier("mapping.choose.\(node)")
            }
        } header: {
            Text(node)
        } footer: {
            if kind == .pci, entries.count > 1 {
                Text("A VM gets the first of these devices that is free when it starts.")
            } else if kind == .dir {
                Text("The directory has to exist on the node. Leave it empty on nodes without it.")
            }
        }
    }

    private func entryDetails(_ entry: PropertyString) -> String {
        switch kind {
        case .pci:
            return [entry["id"].map { String(localized: "ID \($0)") }, entry["iommugroup"].map { String(localized: "IOMMU group \($0)") }].compactMap { $0 }.joined(separator: " · ")
        case .usb:
            return entry["path"] != nil ? String(localized: "Port, device \(entry["id"] ?? "")") : String(localized: "Device ID")
        case .dir:
            return ""
        }
    }

    private func save() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems(isNew: isNew).isEmpty else {
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if let mapping {
                try await list.update(kind, id: mapping.id, draft.changes(from: original), digest: mapping.digest)
            } else {
                try await list.create(draft)
            }
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The node's devices to map: several PCI devices or whole slots, or one USB device by ID or by port.
private struct MappingDevicePicker: View {
    let list: ResourceMappingList
    let kind: ResourceMappingKind
    let node: String
    let mdevOnly: Bool
    @Binding var selection: [PropertyString]
    @State private var pciDevices: [NodePCIDevice]?
    @State private var usbDevices: [NodeUSBDevice]?
    @State private var usbByPort = false

    private var selectedPaths: Set<String> { Set(selection.compactMap { $0["path"] }) }

    var body: some View {
        List {
            switch kind {
            case .pci: pciSections
            case .usb: usbSections
            case .dir: EmptyView()
            }
        }
        .overlay { if pciDevices == nil && usbDevices == nil { ProgressView() } }
        .navigationTitle(node)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            switch kind {
            case .pci: pciDevices = await list.pciDevices(node: node)
            case .usb:
                usbDevices = await list.usbDevices(node: node)
                usbByPort = selection.first?["path"] != nil
            case .dir: break
            }
        }
    }

    @ViewBuilder
    private var pciSections: some View {
        let devices = (pciDevices ?? []).filter { !mdevOnly || $0.mdev == true }
        let slots = Dictionary(grouping: devices) { String($0.id.dropLast(2)) }.filter { $0.value.count > 1 }
        if pciDevices?.allSatisfy({ $0.iommuGroup == -1 }) == true, pciDevices?.isEmpty == false {
            Section {
                Label("No IOMMU is active on this node, so VMs cannot use these devices yet.", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
        if !slots.isEmpty {
            Section {
                ForEach(slots.keys.sorted(), id: \.self) { slot in
                    let first = slots[slot]!.sorted { $0.id < $1.id }[0]
                    pciToggle(first, path: slot, title: String(localized: "All functions of \(first.deviceName ?? slot)"), allFunctions: true)
                }
            } header: {
                Text("Whole Devices")
            } footer: {
                Text("Passes every function of the slot as one device, e.g. a GPU with its audio controller.")
            }
        }
        Section {
            ForEach(devices) { device in
                pciToggle(device, path: device.id, title: device.deviceName ?? device.id, allFunctions: false)
                    .disabled(selectedPaths.contains(String(device.id.dropLast(2))))
            }
        } header: {
            Text("Functions")
        } footer: {
            Text("Several devices make a pool: a VM gets the first free one when it starts.")
        }
    }

    private func pciToggle(_ device: NodePCIDevice, path: String, title: String, allFunctions: Bool) -> some View {
        Toggle(isOn: Binding(get: { selectedPaths.contains(path) }, set: { on in
            selection.removeAll { $0["path"] == path }
            if on {
                // A whole slot replaces its single functions.
                if allFunctions { selection.removeAll { $0["path"]?.hasPrefix(path + ".") == true } }
                selection.append(ResourceMappingDraft.pciEntry(device, node: node, allFunctions: allFunctions))
            }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                Text([path, device.vendorName, device.iommuGroup.map { $0 == -1 ? nil : String(localized: "IOMMU group \($0)") } ?? nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("mapping.pci.\(path)")
    }

    @ViewBuilder
    private var usbSections: some View {
        Section {
            Toggle("Map by Port", isOn: $usbByPort)
                .onChange(of: usbByPort) {
                    guard let current = selection.first, let device = usbDevices?.first(where: { $0.deviceID == current["id"] }) else { return }
                    selection = [ResourceMappingDraft.usbEntry(device, node: node, byPort: usbByPort)]
                }
                .accessibilityIdentifier("mapping.usb.byPort")
        } footer: {
            Text(usbByPort ? "Whatever is plugged into the port is passed through." : "The device is found by its vendor and product ID on any port.")
        }
        Section {
            if usbDevices?.isEmpty == true {
                Text("No USB devices").foregroundStyle(.secondary)
            }
            ForEach(usbDevices ?? []) { device in
                Button {
                    selection = [ResourceMappingDraft.usbEntry(device, node: node, byPort: usbByPort)]
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.product ?? device.deviceID).foregroundStyle(Color.primary)
                            Text([device.deviceID, device.manufacturer, device.portID.map { String(localized: "Port \($0)") }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        if selection.first?["id"] == device.deviceID && (!usbByPort || selection.first?["path"] == device.portID) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(usbByPort && device.portID == nil)
                .accessibilityIdentifier("mapping.usb.\(device.deviceID)")
            }
        }
    }
}
