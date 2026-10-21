import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The node's disks, and the LVM volume groups, thin pools, ZFS pools and directories built on them.
struct NodeDisksView: View {
    let detail: NodeDetail
    @State private var creating: DiskStorageKind?
    @State private var deleting: DiskStorageTarget?
    @State private var errorMessage: String?

    private var canModify: Bool { detail.can("Sys.Modify") }

    var body: some View {
        List {
            if let disks = detail.disks {
                Section("Disks") {
                    ForEach(NodeDisk.grouped(disks), id: \.disk.id) { entry in
                        NavigationLink {
                            DiskDetailView(detail: detail, path: entry.disk.path)
                        } label: {
                            DiskRow(disk: entry.disk, usage: Self.usage(of: entry))
                        }
                        .accessibilityIdentifier("disk.\(entry.disk.name)")
                    }
                }
            }
            if let pools = detail.zfsPools, !pools.isEmpty {
                Section("ZFS") {
                    ForEach(pools) { pool in
                        NavigationLink {
                            ZFSPoolView(detail: detail, pool: pool)
                        } label: {
                            StorageRow(title: pool.name, systemImage: "cylinder.split.1x2", used: pool.allocated, total: pool.size, badge: pool.isHealthy ? nil : pool.health)
                        }
                        .accessibilityIdentifier("zfs.\(pool.name)")
                        .swipeActions { deleteButton(DiskStorageTarget(kind: .zfs, name: pool.name)) }
                    }
                }
            }
            if let groups = detail.volumeGroups, !groups.isEmpty {
                Section("LVM") {
                    ForEach(groups) { group in
                        StorageRow(title: group.name, subtitle: group.physicalVolumes.map(\.name).joined(separator: ", "), systemImage: "square.stack.3d.up",
                                   used: group.size - group.free, total: group.size, warnsWhenFull: false)
                            .swipeActions { deleteButton(DiskStorageTarget(kind: .lvm, name: group.name)) }
                    }
                }
            }
            if let pools = detail.thinPools, !pools.isEmpty {
                Section("LVM-Thin") {
                    ForEach(pools) { pool in
                        StorageRow(title: pool.name, subtitle: String(localized: "in \(pool.volumeGroup) · metadata \(Format.fraction(pool.metadataUsed, of: pool.metadataSize).formatted(.percent.precision(.fractionLength(0))))"),
                                   systemImage: "square.stack.3d.down.forward", used: pool.used, total: pool.size)
                            .swipeActions { deleteButton(DiskStorageTarget(kind: .lvmThin, name: pool.name, volumeGroup: pool.volumeGroup)) }
                    }
                }
            }
            if let directories = detail.directories, !directories.isEmpty {
                Section("Directories") {
                    ForEach(directories) { mount in
                        LabeledContent {
                            Text(mount.fileSystem)
                        } label: {
                            Label {
                                Text(mount.path)
                                Text(mount.device)
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                        .swipeActions { deleteButton(DiskStorageTarget(kind: .directory, name: mount.name)) }
                    }
                }
            }
        }
        .overlay {
            if let errorMessage, detail.disks == nil {
                ContentUnavailableView("Cannot Load the Disks", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if detail.disks == nil {
                ProgressView()
            }
        }
        .navigationTitle("Disks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(DiskStorageKind.allCases) { kind in
                        Button(kind.createTitle, systemImage: kind.systemImage) { creating = kind }
                    }
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .disabled(!canModify || detail.disks == nil)
                .accessibilityIdentifier("disks.add")
            }
        }
        .refreshable { errorMessage = await detail.loadDisks() }
        .task { errorMessage = await detail.loadDisks() }
        .sheet(item: $creating) { kind in
            NavigationStack {
                CreateDiskStorageView(detail: detail, kind: kind)
            }
        }
        .sheet(item: $deleting) { target in
            NavigationStack {
                DeleteDiskStorageView(detail: detail, target: target)
            }
        }
    }

    /// For a partitioned disk, what its partitions hold, e.g. `ZFS` or `BIOS boot, EFI, LVM`.
    static func usage(of entry: (disk: NodeDisk, partitions: [NodeDisk])) -> String {
        let uses = entry.partitions.compactMap(\.usage).filter { $0 != "ZFS reserved" }
        guard entry.disk.usage == "partitions", !uses.isEmpty else { return entry.disk.usageTitle }
        return uses.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
    }

    /// Not `role: .destructive`: a full swipe with that role hides the row right away, but this only asks first.
    @ViewBuilder
    private func deleteButton(_ target: DiskStorageTarget) -> some View {
        if canModify {
            Button("Remove", systemImage: "trash") { deleting = target }
                .tint(.red)
        }
    }
}

/// What a removal acts on.
struct DiskStorageTarget: Identifiable, Hashable {
    let kind: DiskStorageKind
    let name: String
    var volumeGroup: String?

    var id: String { "\(kind.rawValue)/\(volumeGroup ?? "")/\(name)" }
}

extension DiskStorageKind {
    var title: LocalizedStringKey {
        switch self {
        case .lvm: "LVM Volume Group"
        case .lvmThin: "LVM Thin Pool"
        case .zfs: "ZFS Pool"
        case .directory: "Directory"
        }
    }

    var createTitle: LocalizedStringKey {
        switch self {
        case .lvm: "Create LVM Volume Group"
        case .lvmThin: "Create LVM Thin Pool"
        case .zfs: "Create ZFS Pool"
        case .directory: "Create Directory"
        }
    }

    var systemImage: String {
        switch self {
        case .lvm: "square.stack.3d.up"
        case .lvmThin: "square.stack.3d.down.forward"
        case .zfs: "cylinder.split.1x2"
        case .directory: "folder"
        }
    }
}

extension NodeDisk {
    var systemImage: String {
        switch type {
        case "nvme": "memorychip"
        case "usb": "externaldrive"
        default: "internaldrive"
        }
    }

    /// `partitions` → `Partitions`; other values (`LVM`, `ext4`) are kept as they are.
    var usageTitle: String {
        guard let usage else { return String(localized: "Unused") }
        return usage == "partitions" ? String(localized: "Partitions") : usage == "mounted" ? String(localized: "Mounted") : usage
    }

    var typeTitle: String {
        switch type {
        case "hdd": String(localized: "Hard Disk")
        case "ssd": String(localized: "SSD")
        case "nvme": String(localized: "NVMe")
        case "usb": String(localized: "USB")
        case "partition": String(localized: "Partition")
        case "unknown": String(localized: "Disk")
        default: type.uppercased()
        }
    }
}

private struct DiskRow: View {
    let disk: NodeDisk
    let usage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: disk.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(disk.name)
                        .font(.body.weight(.medium))
                    Text(Format.bytes(disk.size))
                        .foregroundStyle(.secondary)
                }
                Text([disk.model, usage].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if disk.isFailing {
                Badge(text: disk.health ?? "", color: .red)
            } else if let wearout = disk.wearout, wearout < 100 {
                Text("\(wearout)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(wearout < 20 ? .orange : .secondary)
                    .accessibilityLabel("\(wearout)% life left")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StorageRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let used: Int64
    let total: Int64
    /// Volume groups are usually allocated completely, which is no reason for alarm.
    var warnsWhenFull = true
    var badge: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.body.weight(.medium))
                    if let badge { Badge(text: badge, color: .orange) }
                    Spacer()
                    Text("\(Format.bytes(used)) of \(Format.bytes(total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Format.fraction(used, of: total))
                    .tint(warnsWhenFull && Format.fraction(used, of: total) > 0.9 ? .red : .accentColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }
}

// MARK: - Disk

/// A disk with its partitions and SMART values, and Initialize with GPT and Wipe.
private struct DiskDetailView: View {
    let detail: NodeDetail
    let path: String
    @State private var smart: SMARTReport?
    @State private var smartError: String?
    @State private var confirmsWipe = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var entry: (disk: NodeDisk, partitions: [NodeDisk])? {
        NodeDisk.grouped(detail.disks ?? []).first { $0.disk.path == path }
    }

    var body: some View {
        List {
            if let entry {
                let disk = entry.disk
                Section {
                    LabeledContent("Model", value: disk.model ?? "–")
                    if let serial = disk.serial { LabeledContent("Serial Number", value: serial) }
                    LabeledContent("Size", value: Format.bytes(disk.size))
                    LabeledContent("Type", value: disk.rpm.map { "\(disk.typeTitle), \($0) rpm" } ?? disk.typeTitle)
                    LabeledContent("Usage", value: NodeDisksView.usage(of: entry))
                    LabeledContent("Partition Table", value: disk.hasGPT ? "GPT" : String(localized: "None"))
                    if let wwn = disk.wwn { LabeledContent("WWN", value: wwn) }
                }
                if !entry.partitions.isEmpty {
                    Section("Partitions") {
                        ForEach(entry.partitions) { partition in
                            LabeledContent {
                                Text(Format.bytes(partition.size))
                            } label: {
                                Text(partition.name)
                                Text(partition.usageTitle)
                            }
                        }
                    }
                }
                smartSection(disk)
                Section {
                    if disk.isUnused, !disk.hasGPT {
                        Button {
                            Task { await run { () throws(ConfigUpdateError) in try await detail.initializeGPT(path) } }
                        } label: {
                            Label("Initialize Disk with GPT", systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("disk.initgpt")
                    }
                    Button(role: .destructive) {
                        confirmsWipe = true
                    } label: {
                        HStack {
                            Label("Wipe Disk", systemImage: "eraser")
                            Spacer()
                            if isWorking { ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("disk.wipe")
                } footer: {
                    Text("Wiping removes the partition table and file system signatures, so the disk shows as unused. Disks in use are refused.")
                }
                .disabled(isWorking || !detail.can("Sys.Modify"))
            }
        }
        .navigationTitle(entry?.disk.name ?? path)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSMART() }
        .confirmationDialog("Wipe \(path)?", isPresented: $confirmsWipe, titleVisibility: .visible) {
            Button("Wipe Disk", role: .destructive) {
                Task { await run { () throws(ConfigUpdateError) in try await detail.wipe(path) } }
            }
            .accessibilityIdentifier("disk.wipe.confirm")
        } message: {
            Text("All data on the disk becomes unreadable. This cannot be undone.")
        }
        .alert("Disk Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func smartSection(_ disk: NodeDisk) -> some View {
        Section {
            if let smart {
                LabeledContent("Health") {
                    Text(smart.health)
                        .foregroundStyle(["OK", "PASSED"].contains(smart.health.uppercased()) ? .green : .red)
                }
                if let wearout = disk.wearout {
                    LabeledContent("Life Left", value: "\(wearout)%")
                }
                if !smart.attributes.isEmpty {
                    NavigationLink("SMART Attributes") {
                        SMARTAttributesView(attributes: smart.attributes)
                    }
                } else if let text = smart.text {
                    NavigationLink("SMART Report") {
                        ScrollView([.vertical, .horizontal]) {
                            Text(text)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .navigationTitle("SMART Report")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            } else if let smartError {
                Text(smartError).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        } header: {
            Text("SMART")
        }
    }

    private func loadSMART() async {
        do {
            smart = try await detail.smart(of: path)
        } catch is CancellationError {
        } catch {
            smartError = error.localizedDescription
        }
    }

    private func run(_ action: () async throws(ConfigUpdateError) -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await action()
            await loadSMART()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SMARTAttributesView: View {
    let attributes: [SMARTReport.Attribute]

    var body: some View {
        List(attributes) { attribute in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(attribute.name)
                        .font(.body.weight(.medium))
                    Spacer()
                    Text(attribute.raw)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(attribute.isFailing ? .red : .primary)
                }
                Text("ID \(String(attribute.id)) · value \(attribute.value) · worst \(attribute.worst) · threshold \(attribute.threshold)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if attribute.isFailing {
                    Text("Failed: \(attribute.fail)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .navigationTitle("SMART Attributes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - ZFS

private struct ZFSPoolView: View {
    let detail: NodeDetail
    let pool: ZFSPool
    @State private var status: ZFSPoolStatus?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Health") {
                    Text(pool.health).foregroundStyle(pool.isHealthy ? .green : .orange)
                }
                LabeledContent("Size", value: Format.bytes(pool.size))
                LabeledContent("Allocated", value: Format.bytes(pool.allocated))
                LabeledContent("Free", value: Format.bytes(pool.free))
                LabeledContent("Fragmentation", value: "\(pool.fragmentation)%")
                LabeledContent("Deduplication", value: pool.dedupRatio.formatted(.number.precision(.fractionLength(2))) + "×")
            }
            if let status {
                Section {
                    if let text = status.status { LabeledContent("Status") { Text(text) } }
                    if let action = status.action { LabeledContent("Action") { Text(action) } }
                    if let scan = status.scan { LabeledContent("Last Scrub") { Text(scan) } }
                    if let errors = status.errors { LabeledContent("Errors") { Text(errors) } }
                }
                Section("Devices") {
                    ForEach(Array(status.devices.flatMap { $0.flattened() }.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            Text(row.device.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(row.depth == 0 ? .body.weight(.medium) : .body)
                                .padding(.leading, CGFloat(row.depth) * 18)
                            Spacer()
                            if row.device.hasErrors {
                                Text("R \(row.device.readErrors) W \(row.device.writeErrors) C \(row.device.checksumErrors)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.red)
                            }
                            if let state = row.device.state {
                                Text(state)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(state == "ONLINE" ? .green : .orange)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(pool.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            status = try await detail.zfsStatus(of: pool.name)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Create and remove

private struct CreateDiskStorageView: View {
    let detail: NodeDetail
    @State private var draft: DiskStorageDraft
    @State private var isCreating = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(detail: NodeDetail, kind: DiskStorageKind) {
        self.detail = detail
        _draft = State(initialValue: DiskStorageDraft(kind: kind))
    }

    /// Unused whole disks; partitions are not offered, as in the web interface's default.
    private var candidates: [NodeDisk] {
        NodeDisk.grouped(detail.disks ?? []).map(\.disk).filter(\.isUnused)
    }

    private var errors: [String: String] { showsProblems ? draft.problems.merging(fieldErrors) { _, server in server } : fieldErrors }

    var body: some View {
        Form {
            Section {
                LabeledTextField(title: "Name", prompt: draft.kind == .zfs ? "tank" : "data", text: $draft.name, identifier: "storage.name")
                FieldError(message: errors["name"])
                Toggle("Add Storage", isOn: $draft.addStorage)
            } footer: {
                Text("Add Storage also configures it as a storage of the datacenter, so guests and backups can use it.")
            }
            Section {
                if candidates.isEmpty {
                    Text("No unused disks. Wipe a disk to use it here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { disk in
                    Button {
                        toggle(disk.path)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(disk.name).foregroundStyle(.primary)
                                Text([disk.model, Format.bytes(disk.size)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if draft.devices.contains(disk.path) {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("candidate.\(disk.name)")
                    .accessibilityAddTraits(draft.devices.contains(disk.path) ? .isSelected : [])
                }
                FieldError(message: errors["devices"] ?? errors["device"])
            } header: {
                Text(draft.kind.takesSeveralDisks ? "Disks" : "Disk")
            } footer: {
                Text("Everything on the chosen disks is erased.")
            }
            if draft.kind == .zfs {
                Section("ZFS") {
                    Picker("RAID Level", selection: $draft.raidLevel) {
                        ForEach(DiskStorageDraft.raidLevels, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Compression", selection: $draft.compression) {
                        ForEach(DiskStorageDraft.compressions, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("ashift \(draft.ashift)", value: $draft.ashift, in: 9...16)
                }
            }
            if draft.kind == .directory {
                Section {
                    Picker("File System", selection: $draft.fileSystem) {
                        Text("ext4").tag("ext4")
                        Text("xfs").tag("xfs")
                    }
                } footer: {
                    Text("Mounted at /mnt/pve/\(draft.name.isEmpty ? "name" : draft.name).")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(draft.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isCreating)
        .disabled(isCreating)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Create", isWorking: isCreating) { Task { await create() } }
                    .accessibilityIdentifier("storage.create")
            }
        }
    }

    private func toggle(_ path: String) {
        draft.deviceSizes = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0.size) })
        if let index = draft.devices.firstIndex(of: path) {
            draft.devices.remove(at: index)
        } else if draft.kind.takesSeveralDisks {
            draft.devices.append(path)
        } else {
            draft.devices = [path]
        }
    }

    private func create() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems.isEmpty else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            try await detail.createDiskStorage(draft)
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DeleteDiskStorageView: View {
    let detail: NodeDetail
    let target: DiskStorageTarget
    @State private var cleanupConfig = true
    @State private var wipeDisks = false
    @State private var confirmation = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Label {
                    Text("The \(Text(target.kind.title)) “\(target.name)” and all data on it are removed. This cannot be undone.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            Section {
                Toggle("Remove Storage Configuration", isOn: $cleanupConfig)
                Toggle("Wipe Disks", isOn: $wipeDisks)
            } footer: {
                Text(target.kind == .lvmThin
                    ? "Removes the storage entries that use it. Wiping also removes the thin pool's volume group, so its disks show as unused."
                    : "Removes the storage entries that use it, and wipes its disks so they show as unused.")
            }
            Section {
                TextField(target.name, text: $confirmation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("remove.confirmation")
            } header: {
                Text("Type \(target.name) to Confirm")
            }
            Section {
                Button(role: .destructive) {
                    Task { await delete() }
                } label: {
                    HStack {
                        Text("Remove \(target.name)")
                        Spacer()
                        if isDeleting { ProgressView() }
                    }
                }
                .disabled(confirmation.trimmingCharacters(in: .whitespaces) != target.name || isDeleting)
                .accessibilityIdentifier("remove.confirm")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Remove \(target.name)")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isDeleting)
        .disabled(isDeleting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func delete() async {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await detail.deleteDiskStorage(target.kind, name: target.name, volumeGroup: target.volumeGroup, cleanupConfig: cleanupConfig, wipeDisks: wipeDisks)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
