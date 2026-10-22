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
    @State private var rateText: String
    @State private var mtuText: String
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
        _rateText = State(initialValue: draft.rateLimit.map { $0.formatted(.number.grouping(.never)) } ?? "")
        _mtuText = State(initialValue: draft.mtu.map(String.init) ?? "")
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
            } footer: {
                Text("VirtIO is the fastest model; use Intel E1000 for guests without VirtIO drivers.")
            }
            Section {
                LabeledContent("Rate Limit") {
                    TextField("Unlimited", text: $rateText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("MTU") {
                    TextField("Default", text: $mtuText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                if draft.model == "virtio" {
                    Picker("Multiqueue", selection: Binding(get: { draft.queues ?? 0 }, set: { draft.queues = $0 == 0 ? nil : $0 })) {
                        Text("Off").tag(0)
                        ForEach([2, 4, 8, 16, 32, 64], id: \.self) { Text("\($0) Queues").tag($0) }
                    }
                }
                LabeledContent("VLAN Trunks") {
                    TextField("All", text: $draft.trunks)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
                FieldError(message: key.flatMap { errors[$0] })
            } header: {
                Text("Advanced")
            } footer: {
                Text("Rate limit in MB/s. Multiqueue lets several vCPUs handle network traffic; match it to the vCPU count. Trunks limit the VLANs passed to the guest, e.g. 10;20-30.")
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
        draft.rateLimit = Double(rateText.replacingOccurrences(of: ",", with: "."))
        draft.mtu = Int(mtuText)
        let value = draft.stringValue
        guard value != nic.map({ NetworkDeviceDraft($0).stringValue }) else { return nil }
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
    /// `scsi`, `virtio`, `sata` or `ide`.
    private var bus: String { String(disk.key.prefix { $0.isLetter }) }
    /// Bind mounts and the EFI and TPM state disks cannot be moved or reassigned here.
    private var canMove: Bool { disk.size != nil && !["efidisk0", "tpmstate0"].contains(disk.key) || disk.isUnused }

    var body: some View {
        ConfigEditor(title: LocalizedStringKey(disk.key), detail: detail, makeUpdate: update) { errors in
            if isStale {
                Section {
                    Label("This disk was changed elsewhere. Go back to see its current settings.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                LabeledContent("Volume", value: disk.volume)
                if let size = disk.size {
                    LabeledContent("Size", value: size)
                }
            }
            // EFI and TPM state disks have a fixed size.
            if !disk.isUnused, disk.size != nil, disk.key != "efidisk0", disk.key != "tpmstate0" {
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
                    Picker("Async IO", selection: $draft.asyncIO) {
                        Text("Default (io_uring)").tag(String?.none)
                        ForEach(DiskOptionsDraft.asyncIOModes, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Toggle("Discard", isOn: $draft.discard)
                    if bus == "scsi" || bus == "virtio" {
                        Toggle("IO Thread", isOn: $draft.ioThread)
                        Toggle("Read Only", isOn: $draft.readOnly)
                    }
                    if bus != "virtio" {
                        Toggle("SSD Emulation", isOn: $draft.ssdEmulation)
                    }
                    Toggle("Include in Backups", isOn: $draft.includeInBackup)
                    Toggle("Replicate", isOn: $draft.replicate)
                    LabeledContent("Serial") {
                        TextField("None", text: $draft.serial)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    NavigationLink {
                        DiskLimitsEditor(limits: $draft.limits)
                    } label: {
                        LabeledContent("Bandwidth Limits", value: draft.limits.values.contains { !$0.isEmpty } ? String(localized: "Set") : String(localized: "Unlimited"))
                    }
                    FieldError(message: errors[disk.key])
                }
            }
            if let binding = Binding($mountDraft) {
                MountPointOptionsSection(draft: binding, error: errors[disk.key])
            }
            if canMove {
                Section {
                    if disk.isUnused {
                        NavigationLink("Attach Disk") {
                            AttachUnusedDiskEditor(detail: detail, config: config, disk: disk) { dismiss() }
                        }
                    } else {
                        NavigationLink("Move to Another Storage") {
                            MoveDiskView(detail: detail, disk: disk) { dismiss() }
                        }
                    }
                    if disk.key != "rootfs" {
                        NavigationLink("Reassign to Another Guest") {
                            ReassignDiskView(detail: detail, disk: disk) { dismiss() }
                        }
                    }
                }
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

    /// The disk no longer matches the configuration, e.g. after a move; saving would overwrite the new volume.
    private var isStale: Bool { detail.config.map { $0[disk.key] != config[disk.key] } ?? false }

    private func update() -> GuestConfigUpdate? {
        guard !isStale else { return nil }
        if let mountDraft {
            let value = mountDraft.stringValue
            guard value != MountPointDraft(disk).stringValue else { return nil }
            var update = GuestConfigUpdate()
            update.set(disk.key, value)
            return update
        }
        guard isVM, !disk.isUnused else { return nil }
        let value = draft.stringValue
        guard value != DiskOptionsDraft(disk).stringValue else { return nil }
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
    /// An ISO image's volume, `GuestConfig.physicalCDROM` for the host's drive, nil for no disc.
    @State private var selection: String?
    @State private var media: CDROMMedia
    @State private var bus: DiskBus = .ide
    @State private var images: [StorageVolume] = []
    @State private var isLoading = true
    @State private var confirmsRemoval = false
    @Environment(\.dismiss) private var dismiss

    init(detail: GuestDetail, config: GuestConfig, drive: GuestDisk?) {
        self.detail = detail
        self.config = config
        self.drive = drive
        let volume = drive.flatMap { $0.volume == "none" ? nil : $0.volume }
        _selection = State(initialValue: volume == GuestConfig.physicalCDROM ? nil : volume)
        _media = State(initialValue: volume == nil ? (drive == nil ? .image : .none) : volume == GuestConfig.physicalCDROM ? .physical : .image)
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
                Picker("Media", selection: $media) {
                    Text("ISO Image").tag(CDROMMedia.image)
                    Text("Physical Drive").tag(CDROMMedia.physical)
                    Text("None").tag(CDROMMedia.none)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("cdrom.media")
            } footer: {
                switch media {
                case .physical: Text("Passes the host's own CD/DVD drive to the guest.")
                case .none: Text("The drive stays empty.")
                case .image: EmptyView()
                }
            }
            if media == .image {
                Section {
                    Picker("Image", selection: $selection) {
                        if selection == nil { Text("Choose").tag(String?.none) }
                        ForEach(images) { image in
                            Text(image.fileName).tag(String?.some(image.volumeID))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if isLoading { ProgressView() }
                } header: {
                    Text("ISO Images")
                } footer: {
                    Text("Download ISO images to a storage with ISO content from the storage's screen.")
                }
            }
            if let key = drive?.key ?? newKey, let message = errors[key] {
                Section { FieldError(message: message) }
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
        images = await detail.connection.volumes(node: detail.reference.node, content: "iso")
        isLoading = false
    }

    private var newKey: String? { config.nextFreeKey(prefix: bus.rawValue, slots: bus.slots) }

    /// The drive's volume as chosen, nil for no disc; `.image` without a chosen image cannot be saved.
    private var volume: String?? {
        switch media {
        case .image: selection.map { .some($0) }
        case .physical: .some(GuestConfig.physicalCDROM)
        case .none: .some(nil)
        }
    }

    private func update() -> GuestConfigUpdate? {
        guard let volume else { return nil }
        let value = GuestConfig.cdromValue(isoVolume: volume)
        var update = GuestConfigUpdate()
        if let drive {
            guard volume != (drive.volume == "none" ? nil : drive.volume) else { return nil }
            update.set(drive.key, value)
        } else {
            guard let newKey else { return nil }
            update.set(newKey, value)
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

/// What a CD/DVD drive holds.
enum CDROMMedia: Hashable {
    case image, physical, none
}

/// Creates a new disk on a storage and attaches it, with every option of the web interface's Add Hard Disk dialog.
struct AddDiskEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var disk: NewVMDisk
    @State private var slot = 0
    @State private var storages: [StorageInfo] = []

    /// `importSource` starts with importing that image, e.g. from a storage's import content.
    init(detail: GuestDetail, config: GuestConfig, importSource: String? = nil) {
        self.detail = detail
        self.config = config
        var disk = NewVMDisk()
        if let importSource {
            disk.isImport = true
            disk.importSource = importSource
        }
        _disk = State(initialValue: disk)
    }

    var body: some View {
        ConfigEditor(title: "Add Hard Disk", detail: detail, makeUpdate: update, footer: "New disks are available to the guest right away if it supports hot-plugging.") { errors in
            Section {
                Picker("Source", selection: $disk.isImport) {
                    Text("New Disk").tag(false)
                    Text("Import Image").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("disk.source")
            } footer: {
                if disk.isImport {
                    Text("Copies a disk image (qcow2, vmdk or raw) from a storage with import content, e.g. a cloud image.")
                }
            }
            NewDiskSections(
                disk: $disk, key: key, error: errors[key], connection: detail.connection, node: detail.reference.node,
                storages: storages, showsAdvanced: true, freeSlots: freeSlots, slot: $slot
            )
        }
        .onChange(of: disk.bus) { slot = freeSlots(disk.bus).first ?? 0 }
        .task {
            storages = await detail.load(PVE.storages(node: detail.reference.node, content: "images")).filter(\.isActive)
            slot = freeSlots(disk.bus).first ?? 0
            disk.chooseFormat(for: storages.first { $0.storage == disk.storage })
        }
    }

    private var key: String { "\(disk.bus.rawValue)\(slot)" }

    /// Device numbers of a bus no disk or drive uses yet.
    private func freeSlots(_ bus: DiskBus) -> [Int] {
        (0..<bus.slots).filter { config["\(bus.rawValue)\($0)"] == nil }
    }

    private func update() -> GuestConfigUpdate? {
        guard !disk.storage.isEmpty, config[key] == nil, freeSlots(disk.bus).contains(slot), !disk.isImport || !disk.importSource.isEmpty else { return nil }
        var update = GuestConfigUpdate()
        update.set(key, disk.value)
        return update
    }
}
