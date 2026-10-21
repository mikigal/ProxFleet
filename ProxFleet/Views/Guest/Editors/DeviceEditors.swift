import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Edits a VM network device, or adds one when `nic` is nil.
struct NetworkDeviceEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let nic: GuestNIC?
    @State private var draft: NetworkDeviceDraft
    @State private var vlanText: String
    @State private var bridges: [NodeNetworkInterface] = []
    @State private var confirmsRemoval = false
    @Environment(\.dismiss) private var dismiss

    init(detail: GuestDetail, config: GuestConfig, nic: GuestNIC?) {
        self.detail = detail
        self.config = config
        self.nic = nic
        let draft = nic.map(NetworkDeviceDraft.init) ?? NetworkDeviceDraft()
        _draft = State(initialValue: draft)
        _vlanText = State(initialValue: draft.vlanTag.map(String.init) ?? "")
    }

    private var key: String? { nic?.key ?? config.nextFreeKey(prefix: "net", slots: 32) }

    var body: some View {
        ConfigEditor(title: nic == nil ? "Add Network Device" : LocalizedStringKey(nic!.key), detail: detail, makeUpdate: update) { errors in
            Section {
                Picker("Bridge", selection: $draft.bridge) {
                    ForEach(bridgeNames, id: \.self) { name in
                        Text(bridges.first { $0.name == name }?.comment.flatMap { $0.isEmpty ? nil : "\(name) – \($0)" } ?? name).tag(name)
                    }
                }
                LabeledContent("VLAN Tag") {
                    TextField("None", text: $vlanText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Firewall", isOn: $draft.firewall)
                Toggle("Disconnected", isOn: $draft.isDisconnected)
            }
            Section {
                Picker("Model", selection: $draft.model) {
                    ForEach(NetworkDeviceDraft.models, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("MAC Address") {
                    TextField("Automatic", text: Binding(get: { draft.macAddress ?? "" }, set: { draft.macAddress = $0.isEmpty ? nil : $0.uppercased() }))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                }
                FieldError(message: key.flatMap { errors[$0] })
            } footer: {
                Text("VirtIO is the fastest model; use Intel E1000 for guests without VirtIO drivers.")
            }
            if let nic {
                Section {
                    Button("Remove Network Device", role: .destructive) { confirmsRemoval = true }
                }
                .alert("Remove \(nic.key)?", isPresented: $confirmsRemoval) {
                    Button("Cancel", role: .cancel) {}
                    Button("Remove", role: .destructive) { Task { await remove(nic.key) } }
                } message: {
                    Text("The guest loses this network connection.")
                }
            }
        }
        .task { bridges = await detail.load(PVE.bridges(node: detail.reference.node)) }
    }

    private var bridgeNames: [String] {
        var names = bridges.map(\.name)
        if !names.contains(draft.bridge) { names.insert(draft.bridge, at: 0) }
        return names
    }

    private func update() -> GuestConfigUpdate? {
        guard let key else { return nil }
        var draft = draft
        draft.vlanTag = Int(vlanText)
        let value = draft.stringValue
        guard value != nic.map({ config[$0.key] ?? "" }) else { return nil }
        var update = GuestConfigUpdate()
        update.set(key, value)
        return update
    }

    private func remove(_ key: String) async {
        var update = GuestConfigUpdate()
        update.set(key, nil)
        try? await detail.apply(update)
        dismiss()
    }
}

/// Options, size and removal of an existing disk.
struct DiskEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let disk: GuestDisk
    @State private var draft: DiskOptionsDraft
    /// Containers: options of the root file system or mount point.
    @State private var mountDraft: MountPointDraft?
    @State private var growBy = 8
    @State private var confirmsGrow = false
    @State private var confirmsDetach = false
    @State private var confirmsDelete = false
    @State private var actionError: String?
    @State private var isWorking = false
    @Environment(\.dismiss) private var dismiss

    init(detail: GuestDetail, config: GuestConfig, disk: GuestDisk) {
        self.detail = detail
        self.config = config
        self.disk = disk
        _draft = State(initialValue: DiskOptionsDraft(disk))
        if detail.reference.kind == .container, !disk.isUnused {
            _mountDraft = State(initialValue: MountPointDraft(disk))
        }
    }

    private var isVM: Bool { detail.reference.kind == .virtualMachine }

    var body: some View {
        ConfigEditor(title: LocalizedStringKey(disk.key), detail: detail, makeUpdate: update) { errors in
            Section {
                LabeledContent("Volume", value: disk.volume)
                if let size = disk.size {
                    LabeledContent("Size", value: size)
                }
            }
            if !disk.isUnused, disk.size != nil {
                Section {
                    NumberField(title: "Grow By", value: $growBy, range: 1...16_384, unit: "GiB")
                    Button("Grow Disk") { confirmsGrow = true }
                        .disabled(isWorking)
                } footer: {
                    Text("Disks can only grow. Extend the partition and file system inside the guest afterwards.")
                }
            }
            if isVM, !disk.isUnused, disk.key != "efidisk0", disk.key != "tpmstate0" {
                Section("Options") {
                    Picker("Cache", selection: $draft.cache) {
                        Text("Default (No cache)").tag(String?.none)
                        ForEach(DiskOptionsDraft.cacheModes, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Toggle("Discard", isOn: $draft.discard)
                    Toggle("IO Thread", isOn: $draft.ioThread)
                    Toggle("SSD Emulation", isOn: $draft.ssdEmulation)
                    Toggle("Include in Backups", isOn: $draft.includeInBackup)
                    FieldError(message: errors[disk.key])
                }
            }
            if let binding = Binding($mountDraft) {
                MountPointOptionsSection(draft: binding, error: errors[disk.key])
            }
            Section {
                if disk.isUnused {
                    Button("Delete Disk Permanently", role: .destructive) { confirmsDelete = true }
                } else if disk.key != "rootfs" {
                    Button("Detach Disk", role: .destructive) { confirmsDetach = true }
                }
            } footer: {
                if !disk.isUnused, disk.key != "rootfs" {
                    Text("A detached disk keeps its data and shows up as unused until you delete it.")
                }
            }
            ErrorSection(message: actionError)
        }
        .disabled(isWorking)
        .alert("Grow \(disk.key) by \(growBy) GiB?", isPresented: $confirmsGrow) {
            Button("Cancel", role: .cancel) {}
            Button("Grow") { Task { await grow() } }
        } message: {
            Text("This cannot be undone. Disks cannot shrink.")
        }
        .alert("Detach \(disk.key)?", isPresented: $confirmsDetach) {
            Button("Cancel", role: .cancel) {}
            Button("Detach", role: .destructive) { Task { await remove() } }
        } message: {
            Text("The guest loses access to this disk. Its data is kept.")
        }
        .alert("Delete \(disk.volume)?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await remove() } }
        } message: {
            Text("All data on this disk is destroyed. This cannot be undone.")
        }
    }

    private func update() -> GuestConfigUpdate? {
        if let mountDraft {
            let value = mountDraft.stringValue
            guard value != MountPointDraft(disk).stringValue else { return nil }
            var update = GuestConfigUpdate()
            update.set(disk.key, value)
            return update
        }
        guard isVM, !disk.isUnused else { return nil }
        let value = draft.stringValue
        guard value != config[disk.key] else { return nil }
        var update = GuestConfigUpdate()
        update.set(disk.key, value)
        return update
    }

    private func grow() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await detail.growDisk(disk.key, byGiB: growBy)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func remove() async {
        isWorking = true
        defer { isWorking = false }
        var update = GuestConfigUpdate()
        update.set(disk.key, nil)
        do {
            try await detail.apply(update)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// Changes the image in a CD/DVD drive, or adds a drive when `drive` is nil.
struct CDROMEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let drive: GuestDisk?
    @State private var selection: String?
    @State private var bus: DiskBus = .ide
    @State private var images: [StorageVolume] = []
    @State private var isLoading = true
    @State private var confirmsRemoval = false
    @Environment(\.dismiss) private var dismiss

    init(detail: GuestDetail, config: GuestConfig, drive: GuestDisk?) {
        self.detail = detail
        self.config = config
        self.drive = drive
        _selection = State(initialValue: drive.flatMap { $0.volume == "none" ? nil : $0.volume })
    }

    var body: some View {
        ConfigEditor(title: drive.map { LocalizedStringKey($0.key) } ?? "Add CD/DVD Drive", detail: detail, makeUpdate: update) { errors in
            if drive == nil {
                Section {
                    Picker("Bus", selection: $bus) {
                        Text(DiskBus.ide.title).tag(DiskBus.ide)
                        Text(DiskBus.sata.title).tag(DiskBus.sata)
                        Text(DiskBus.scsi.title).tag(DiskBus.scsi)
                    }
                }
            }
            Section {
                Picker("Image", selection: $selection) {
                    Text("No Disc").tag(String?.none)
                    ForEach(images) { image in
                        Text(image.fileName).tag(String?.some(image.volumeID))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if isLoading { ProgressView() }
                FieldError(message: (drive?.key).flatMap { errors[$0] })
            } header: {
                Text("ISO Images")
            } footer: {
                Text("Upload ISO images in the web interface or download them to a storage with ISO content.")
            }
            if let drive {
                Section {
                    Button("Remove Drive", role: .destructive) { confirmsRemoval = true }
                }
                .alert("Remove \(drive.key)?", isPresented: $confirmsRemoval) {
                    Button("Cancel", role: .cancel) {}
                    Button("Remove", role: .destructive) { Task { await remove(drive.key) } }
                }
            }
        }
        .task { await loadImages() }
    }

    private func loadImages() async {
        let storages = await detail.load(PVE.storages(node: detail.reference.node, content: "iso"))
        var all: [StorageVolume] = []
        for storage in storages {
            all += await detail.load(PVE.storageContent(node: detail.reference.node, storage: storage.storage, content: "iso"))
        }
        images = all.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        isLoading = false
    }

    private func update() -> GuestConfigUpdate? {
        let value = GuestConfig.cdromValue(isoVolume: selection)
        var update = GuestConfigUpdate()
        if let drive {
            guard selection != (drive.volume == "none" ? nil : drive.volume) else { return nil }
            update.set(drive.key, value)
        } else {
            guard let key = config.nextFreeKey(prefix: bus.rawValue, slots: bus.slots) else { return nil }
            update.set(key, value)
        }
        return update
    }

    private func remove(_ key: String) async {
        var update = GuestConfigUpdate()
        update.set(key, nil)
        try? await detail.apply(update)
        dismiss()
    }
}

/// Creates a new disk on a storage and attaches it.
struct AddDiskEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var bus: DiskBus = .scsi
    @State private var storage = ""
    @State private var sizeGiB = 32
    @State private var discard = true
    @State private var ioThread = true
    @State private var ssdEmulation = false
    @State private var storages: [StorageInfo] = []

    var body: some View {
        ConfigEditor(title: "Add Hard Disk", detail: detail, makeUpdate: update, footer: "New disks are available to the guest right away if it supports hot-plugging.") { errors in
            Section {
                Picker("Bus", selection: $bus) {
                    ForEach(DiskBus.allCases) { Text($0.title).tag($0) }
                }
                Picker("Storage", selection: $storage) {
                    ForEach(storages) { info in
                        Text(storageLabel(info)).tag(info.storage)
                    }
                }
                NumberField(title: "Size", value: $sizeGiB, range: 1...65_536, unit: "GiB")
                if let key = nextKey { FieldError(message: errors[key]) }
            }
            Section("Options") {
                Toggle("Discard", isOn: $discard)
                if bus == .scsi || bus == .virtio {
                    Toggle("IO Thread", isOn: $ioThread)
                }
                Toggle("SSD Emulation", isOn: $ssdEmulation)
            }
        }
        .task {
            storages = await detail.load(PVE.storages(node: detail.reference.node, content: "images")).filter(\.isActive)
            if storage.isEmpty { storage = storages.first?.storage ?? "" }
        }
    }

    private var nextKey: String? { config.nextFreeKey(prefix: bus.rawValue, slots: bus.slots) }

    private func storageLabel(_ info: StorageInfo) -> String {
        guard let available = info.available else { return info.storage }
        return "\(info.storage) (\(Format.bytes(available)) free)"
    }

    private func update() -> GuestConfigUpdate? {
        guard let key = nextKey, !storage.isEmpty else { return nil }
        var update = GuestConfigUpdate()
        update.set(key, GuestConfig.newDiskValue(
            storage: storage,
            sizeGiB: sizeGiB,
            discard: discard,
            ioThread: ioThread && (bus == .scsi || bus == .virtio),
            ssdEmulation: ssdEmulation && bus != .virtio
        ))
        return update
    }
}
