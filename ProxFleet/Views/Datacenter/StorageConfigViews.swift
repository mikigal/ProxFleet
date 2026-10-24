import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI
import UniformTypeIdentifiers

/// One storage's definition, shared by every node that has the storage: the editor, or the raw settings of types
/// the app does not edit. Shown as a storage's Settings tab, and on its own for disabled storages.
struct StorageSettingsView: View {
    let storage: DatacenterStorage
    let name: String

    var body: some View {
        Group {
            if let config = storage.configs?.first(where: { $0.storage == name }) {
                if let draft = StorageConfigDraft(config) {
                    StorageConfigEditor(storage: storage, draft: draft, digest: config.digest, isNew: false)
                } else {
                    UnsupportedStorageView(storage: storage, config: config)
                }
            } else if let error = storage.loadError {
                ContentUnavailableView("Cannot Load the Settings", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if storage.configs != nil {
                ContentUnavailableView("No Settings", systemImage: "gearshape", description: Text("\(name) is not in the datacenter's storage configuration."))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await storage.load() }
    }
}

/// Removes a storage definition after asking, then leaves the screen.
private struct RemoveStorageSection: View {
    let storage: DatacenterStorage
    let name: String
    @State private var confirms = false
    @State private var isRemoving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Section {
            Button(role: .destructive) {
                confirms = true
            } label: {
                Label("Remove Storage", systemImage: "trash")
            }
            .disabled(!storage.canModify || isRemoving)
            .accessibilityIdentifier("storageconfig.remove")
            .confirmationDialog("Remove \(name)?", isPresented: $confirms, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { await remove() } }
                    .accessibilityIdentifier("storageconfig.remove.confirm")
            } message: {
                Text("Only the definition is removed; the data on the storage stays. Guests whose disks are on it cannot start until it is added again.")
            }
            .alert("Storage Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
        } footer: {
            Text("Removes the storage from every node.")
        }
    }

    private func remove() async {
        isRemoving = true
        defer { isRemoving = false }
        do {
            try await storage.delete(name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension StorageBackend {
    var title: LocalizedStringKey {
        switch self {
        case .dir: "Directory"
        case .nfs: "NFS"
        case .cifs: "SMB/CIFS"
        case .pbs: "Proxmox Backup Server"
        case .lvm: "LVM"
        case .lvmthin: "LVM-Thin"
        case .zfspool: "ZFS"
        case .btrfs: "Btrfs"
        case .iscsi: "iSCSI"
        case .cephfs: "CephFS"
        case .rbd: "RBD"
        case .zfs: "ZFS over iSCSI"
        case .esxi: "ESXi"
        }
    }

    var systemImage: String {
        switch self {
        case .dir, .btrfs: "folder"
        case .nfs, .cifs: "externaldrive.connected.to.line.below"
        case .pbs: "clock.arrow.circlepath"
        case .lvm: "square.stack.3d.up"
        case .lvmthin: "square.stack.3d.down.forward"
        case .zfspool: "cylinder.split.1x2"
        case .iscsi, .zfs: "server.rack"
        case .cephfs, .rbd: "circle.hexagongrid"
        case .esxi: "square.and.arrow.down.on.square"
        }
    }
}

/// A storage definition: its type, location, content and nodes.
struct StorageConfigRow: View {
    let config: StorageConfig

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: StorageBackend(rawValue: config.type)?.systemImage ?? "externaldrive")
                .font(.title3)
                .foregroundStyle(config.isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.storage)
                        .font(.body.weight(.medium))
                    if config.isDisabled {
                        Text("Disabled")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: .capsule)
                            .foregroundStyle(.secondary)
                    }
                }
                if let location = config.location, !location.isEmpty {
                    Text(location)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let order = StorageContentType.allCases.map(\.rawValue)
        let content = order.filter(config.content.contains).map { String(localized: StorageContentType(rawValue: $0)!.shortTitle) }
        var parts = [content.joined(separator: ", ")]
        if !config.nodes.isEmpty { parts.append(config.nodes.joined(separator: ", ")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension StorageContentType {
    var shortTitle: LocalizedStringResource {
        switch self {
        case .images: "Disks"
        case .rootdir: "Containers"
        case .iso: "ISO"
        case .vztmpl: "Templates"
        case .backup: "Backups"
        case .snippets: "Snippets"
        case .import: "Import"
        }
    }
}

/// iSCSI direct, DRBD and other storages the app does not edit.
private struct UnsupportedStorageView: View {
    let storage: DatacenterStorage
    let config: StorageConfig

    var body: some View {
        List {
            Section {
                ForEach(config.values.sorted { $0.key < $1.key }, id: \.key) { key, value in
                    LabeledContent(key) { Text(value).textSelection(.enabled) }
                }
            } footer: {
                Text("\(config.type) storages can be changed in the web interface.")
            }
            RemoveStorageSection(storage: storage, name: config.storage)
        }
        .navigationTitle(config.storage)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Editor

/// Creates or edits a storage definition. Connection settings can only be set when creating. A new storage's
/// sheet closes once it is added; an existing storage's form stays and starts over from the saved settings.
struct StorageConfigEditor: View {
    let storage: DatacenterStorage
    let isNew: Bool
    @State private var original: StorageConfigDraft
    @State private var digest: String?
    @State private var draft: StorageConfigDraft
    @State private var saveCount = 0
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    /// A key Proxmox generated for a PBS storage, shown once before the editor closes.
    @State private var generatedKey: String?
    @Environment(\.dismiss) private var dismiss

    init(storage: DatacenterStorage, draft: StorageConfigDraft, digest: String?, isNew: Bool) {
        self.storage = storage
        self.isNew = isNew
        _original = State(initialValue: draft)
        _digest = State(initialValue: digest)
        _draft = State(initialValue: draft)
    }

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: isNew) : [:]).merging(fieldErrors) { _, server in server }
    }

    private var hasChanges: Bool { isNew || !draft.changes(from: original).isEmpty }

    var body: some View {
        Form {
            if !storage.canModify {
                Section {
                    Label("Read only. Changing storage needs the Datastore.Allocate privilege on /storage.", systemImage: "lock.fill")
                        .font(.subheadline)
                }
            }
            Group {
                Section {
                    if isNew {
                        LabeledTextField(title: "ID", prompt: "backup", text: $draft.storage, identifier: "storageconfig.id")
                        FieldError(message: errors["storage"])
                    } else {
                        LabeledContent("ID", value: draft.storage)
                    }
                    LabeledContent("Type") { Text(draft.type.title) }
                    Toggle("Enabled", isOn: $draft.isEnabled)
                    if draft.type.canBeMarkedShared {
                        Toggle("Shared", isOn: $draft.isShared)
                    }
                } footer: {
                    if draft.type.canBeMarkedShared {
                        Text("Shared means the same data is reachable from every node, e.g. a directory on a network mount. Proxmox does not share it by itself.")
                    }
                }
                StorageConnectionSection(storage: storage, draft: $draft, isNew: isNew, errors: errors)
                if draft.type.hasContentChoice {
                    contentSection
                }
                nodesSection
                if draft.type == .pbs {
                    PBSEncryptionSection(draft: $draft, isNew: isNew, error: errors["encryption-key"])
                }
                if draft.type.supportsPreallocation || draft.type.supportsVolumeChainSnapshots {
                    advancedSection
                }
                if draft.holdsBackups {
                    retentionSection
                }
            }
            .disabled(!storage.canModify)
            ErrorSection(message: errorMessage)
            if !isNew {
                RemoveStorageSection(storage: storage, name: draft.storage)
            }
        }
        .navigationTitle(isNew ? Text("New \(Text(draft.type.title))") : Text(draft.storage))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .sensoryFeedback(.success, trigger: saveCount)
        .sheet(isPresented: Binding(get: { generatedKey != nil }, set: { if !$0 { generatedKey = nil; if isNew { dismiss() } } })) {
            NavigationStack {
                EncryptionKeyView(storage: draft.storage, key: generatedKey ?? "")
            }
            .interactiveDismissDisabled()
        }
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if storage.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!hasChanges)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private var contentSection: some View {
        Section {
            ForEach(draft.type.supportedContent) { type in
                Toggle(isOn: Binding(get: { draft.content.contains(type.rawValue) }, set: { on in
                    if on { draft.content.insert(type.rawValue) } else { draft.content.remove(type.rawValue) }
                })) {
                    Label(type.title, systemImage: type.systemImage)
                }
                .accessibilityIdentifier("content.\(type.rawValue)")
            }
            FieldError(message: errors["content"])
        } header: {
            Text("Content")
        }
    }

    private var nodesSection: some View {
        Section {
            Toggle("All Nodes", isOn: Binding(get: { draft.nodes.isEmpty }, set: { all in
                draft.nodes = all ? [] : Set(storage.nodeNames.prefix(1))
            }))
            if !draft.nodes.isEmpty {
                ForEach(storage.nodeNames, id: \.self) { node in
                    Toggle(node, isOn: Binding(get: { draft.nodes.contains(node) }, set: { on in
                        if on { draft.nodes.insert(node) } else if draft.nodes.count > 1 { draft.nodes.remove(node) }
                    }))
                }
            }
        } header: {
            Text("Nodes")
        } footer: {
            Text("The settings are the same on every node that has the storage.")
        }
    }

    private var advancedSection: some View {
        Section {
            if draft.type.supportsPreallocation {
                Picker("Preallocation", selection: $draft.preallocation) {
                    Text("Default (Metadata)").tag("")
                    Text("Off").tag("off")
                    Text("Metadata").tag("metadata")
                    Text("Falloc").tag("falloc")
                    Text("Full").tag("full")
                }
                FieldError(message: errors["preallocation"])
            }
            if draft.type.supportsVolumeChainSnapshots {
                Toggle("Snapshots as Volume-Chain", isOn: $draft.volumeChainSnapshots)
                    .disabled(!isNew && draft.type != .lvm)
                FieldError(message: errors["snapshot-as-volume-chain"])
            }
        } header: {
            Text("Advanced")
        } footer: {
            if draft.type.supportsVolumeChainSnapshots {
                Text(draft.type == .lvm
                    ? "Snapshots as a volume chain are a technology preview. Keep them on while qcow2 images exist on the storage."
                    : "Snapshots as a volume chain are a technology preview and can only be turned on when the storage is added.")
            }
        }
    }

    private var retentionSection: some View {
        Section {
            RetentionFields(prune: $draft.prune, error: errors["prune-backups"])
            LabeledTextField(title: "Max. Protected", prompt: "Default", text: $draft.maxProtectedBackups, keyboard: .numbersAndPunctuation)
        } header: {
            Text("Backup Retention")
        } footer: {
            Text("Backup jobs and Back Up Now without overriding remove older backups beyond these counts. With nothing set, all backups are kept. Protected backups are never removed.")
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
            let key = isNew
                ? try await storage.create(draft)
                : try await storage.update(draft.storage, draft.changes(from: original), digest: digest)
            if !isNew {
                startOver()
            }
            if let key {
                generatedKey = key
            } else if isNew {
                dismiss()
            }
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shows the saved settings with their new digest, so the next save starts from them.
    private func startOver() {
        saveCount += 1
        guard let config = storage.configs?.first(where: { $0.storage == draft.storage }),
              let saved = StorageConfigDraft(config) else { return }
        original = saved
        draft = saved
        digest = config.digest
        showsProblems = false
    }
}

/// Where the data is: path, server and export or share, PBS datastore, volume group, ZFS pool. Fixed after creation.
private struct StorageConnectionSection: View {
    let storage: DatacenterStorage
    @Binding var draft: StorageConfigDraft
    let isNew: Bool
    let errors: [String: String]
    @State private var results: [StorageScanResult]?
    @State private var thinPools: [StorageScanResult]?
    @State private var isScanning = false
    @State private var scanError: String?
    /// LVM on iSCSI: the iSCSI storage whose LUN becomes the volume group's base; empty for an existing group.
    @State private var baseStorage = ""
    @State private var luns: [StorageVolume]?
    /// The cluster's own Ceph pools or file systems; nil while unknown, empty when Ceph is not set up.
    @State private var cephChoices: [StorageScanResult]?

    var body: some View {
        Section {
            switch draft.type {
            case .dir, .btrfs:
                fixedField("Path", text: $draft.path, prompt: "/mnt/data", key: "path")
            case .nfs:
                fixedField("Server", text: $draft.server, prompt: "192.168.1.10", key: "server")
                scanPicker("Export", selection: $draft.export, key: "export", fixed: !isNew)
                Picker("NFS Version", selection: $draft.nfsVersion) {
                    Text("Default").tag("")
                    ForEach(StorageConfigDraft.nfsVersions, id: \.self) { Text($0).tag($0) }
                }
                LabeledTextField(title: "Mount Options", prompt: "soft", text: $draft.mountOptions)
            case .cifs:
                fixedField("Server", text: $draft.server, prompt: "192.168.1.10", key: "server")
                LabeledTextField(title: "User", prompt: "Guest", text: $draft.username)
                passwordField
                LabeledTextField(title: "Domain", prompt: "None", text: $draft.domain)
                scanPicker("Share", selection: $draft.share, key: "share", fixed: !isNew)
                LabeledTextField(title: "Subdirectory", prompt: "None", text: $draft.subdir)
                Picker("SMB Version", selection: $draft.smbVersion) {
                    Text("Default").tag("")
                    ForEach(["2.0", "2.1", "3", "3.0", "3.11"], id: \.self) { Text($0).tag($0) }
                }
            case .pbs:
                fixedField("Server", text: $draft.server, prompt: "pbs.example.com", key: "server")
                LabeledTextField(title: "User", prompt: "backup@pbs", text: $draft.username, identifier: "pbs.user")
                FieldError(message: errors["username"])
                passwordField
                LabeledTextField(title: "Fingerprint", prompt: "Not needed for trusted certificates", text: $draft.fingerprint)
                FieldError(message: errors["fingerprint"])
                LabeledTextField(title: "Port", prompt: "8007", text: $draft.port, keyboard: .numberPad)
                FieldError(message: errors["port"])
                scanPicker("Datastore", selection: $draft.datastore, key: "datastore", fixed: !isNew)
                LabeledTextField(title: "Namespace", prompt: "Root", text: $draft.namespace)
            case .lvm:
                lvmFields
            case .lvmthin:
                scanPicker("Volume Group", selection: $draft.volumeGroup, key: "vgname", fixed: !isNew)
                thinPoolPicker
            case .zfspool:
                scanPicker("ZFS Pool", selection: $draft.pool, key: "pool", fixed: !isNew)
                Toggle("Thin Provisioning", isOn: $draft.sparse)
                LabeledTextField(title: "Block Size", prompt: "16k", text: $draft.blockSize)
            case .iscsi:
                fixedField("Portal", text: $draft.portal, prompt: "192.168.1.20", key: "portal")
                scanPicker("Target", selection: $draft.target, key: "target", fixed: !isNew)
                Toggle("Use LUNs Directly", isOn: $draft.usesLUNsDirectly)
                    .accessibilityIdentifier("iscsi.luns")
            case .cephfs, .rbd:
                cephFields
            case .zfs:
                zfsOverISCSIFields
            case .esxi:
                fixedField("Server", text: $draft.server, prompt: "esxi.example.com", key: "server")
                LabeledTextField(title: "Port", prompt: "443", text: $draft.port, keyboard: .numberPad)
                FieldError(message: errors["port"])
                LabeledTextField(title: "User", prompt: "root", text: $draft.username, identifier: "esxi.user")
                FieldError(message: errors["username"])
                passwordField
                Toggle("Skip Certificate Verification", isOn: $draft.skipsCertificateVerification)
            }
            if let scanError {
                Label(scanError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(draft.type.isOnNetwork ? "Server" : "Location")
        } footer: {
            if !isNew {
                Text("The location cannot change after the storage was added. Remove it and add it again instead.")
            } else if draft.type == .iscsi {
                Text("Without LUNs used directly, the storage only provides LUNs as the base of an LVM storage.")
            } else if draft.type == .esxi {
                Text("Guests on the ESXi host show up as import content of this storage and can be imported as VMs.")
            } else if draft.type.isOnNetwork, !draft.type.isCeph, let node = storage.scanNode {
                Text("Scan asks the server from \(node), so it must be reachable from the nodes.")
            }
        }
        .task(id: draft.type) {
            if isNew, [.lvm, .lvmthin, .zfspool].contains(draft.type) { await scan() }
            if isNew, draft.type.isCeph { await loadCephChoices() }
        }
    }

    /// An existing volume group, or a new one on a LUN of an iSCSI storage.
    @ViewBuilder
    private var lvmFields: some View {
        if isNew {
            Picker("Base Storage", selection: $baseStorage) {
                Text("Existing Volume Groups").tag("")
                ForEach(iscsiStorages, id: \.self) { Text("\($0) (iSCSI)").tag($0) }
            }
            .onChange(of: baseStorage) {
                draft.baseVolume = ""
                Task { await loadLUNs() }
            }
            if baseStorage.isEmpty {
                scanPicker("Volume Group", selection: $draft.volumeGroup, key: "vgname", fixed: false)
            } else {
                Picker("Base Volume", selection: $draft.baseVolume) {
                    Text("Choose").tag("")
                    ForEach(luns ?? []) { lun in
                        Text(lun.size.map { "\(lun.fileName) (\(Format.bytes($0)))" } ?? lun.fileName).tag(lun.volumeID)
                    }
                }
                FieldError(message: errors["base"])
                LabeledTextField(title: "Volume Group", prompt: "vg-san", text: $draft.volumeGroup, identifier: "storage.vgname")
                FieldError(message: errors["vgname"])
            }
        } else {
            LabeledContent("Volume Group", value: draft.volumeGroup)
            if !draft.baseVolume.isEmpty {
                LabeledContent("Base Volume", value: draft.baseVolume)
            }
        }
        Toggle("Wipe Removed Volumes", isOn: $draft.wipesRemovedVolumes)
    }

    private var iscsiStorages: [String] {
        (storage.configs ?? []).filter { $0.type == "iscsi" }.map(\.storage)
    }

    /// The cluster's own Ceph, or an external one with monitors and a key.
    @ViewBuilder
    private var cephFields: some View {
        let isRBD = draft.type == .rbd
        if isNew {
            Toggle(isRBD ? "Use Proxmox VE Ceph Pool" : "Use Proxmox VE CephFS", isOn: $draft.usesClusterCeph)
                .disabled(cephChoices?.isEmpty ?? true)
        }
        if isRBD || draft.usesClusterCeph {
            let key = isRBD ? "pool" : "fs-name"
            let selection = isRBD ? $draft.pool : $draft.fsName
            if !isNew {
                LabeledContent(isRBD ? "Pool" : "File System", value: selection.wrappedValue.isEmpty ? String(localized: "Default") : selection.wrappedValue)
            } else if draft.usesClusterCeph, let choices = cephChoices, !choices.isEmpty {
                Picker(isRBD ? "Pool" : "File System", selection: selection) {
                    if !isRBD { Text("Default").tag("") }
                    ForEach(choices) { Text($0.name).tag($0.name) }
                }
            } else {
                LabeledTextField(title: isRBD ? "Pool" : "File System", prompt: isRBD ? "rbd" : "Default", text: selection, identifier: "storage.\(key)")
            }
            FieldError(message: errors[key])
        }
        if !draft.usesClusterCeph {
            LabeledTextField(title: "Monitors", prompt: "10.0.0.1 10.0.0.2", text: $draft.monitors, identifier: "storage.monhost")
            FieldError(message: errors["monhost"])
            if isNew {
                LabeledTextField(title: "User", prompt: "admin", text: $draft.username)
            } else {
                LabeledContent("User", value: draft.username)
            }
            FieldError(message: errors["username"])
            TextField(isRBD ? "Keyring" : "Secret Key", text: $draft.keyring, prompt: Text(isNew ? (isRBD ? "Keyring" : "Secret Key") : "Unchanged"), axis: .vertical)
                .lineLimit(1...6)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("storage.keyring")
            FieldError(message: errors["keyring"])
        }
        if isRBD {
            Toggle("KRBD", isOn: $draft.usesKRBD)
            if isNew {
                LabeledTextField(title: "Namespace", prompt: "None", text: $draft.namespace)
            } else if !draft.namespace.isEmpty {
                LabeledContent("Namespace", value: draft.namespace)
            }
        }
        if isNew, cephChoices?.isEmpty == true {
            Text("Ceph is not set up on this cluster, so the storage needs an external Ceph cluster.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// A ZFS pool on another host, whose volumes are exported over iSCSI.
    @ViewBuilder
    private var zfsOverISCSIFields: some View {
        fixedField("Portal", text: $draft.portal, prompt: "192.168.1.20", key: "portal")
        fixedField("Pool", text: $draft.pool, prompt: "tank/proxmox", key: "pool")
        fixedField("Block Size", text: $draft.blockSize, prompt: "4k", key: "blocksize")
        fixedField("Target", text: $draft.target, prompt: "iqn.2003-01.org.linux-iscsi.san:target", key: "target")
        if isNew {
            Picker("iSCSI Provider", selection: $draft.iscsiProvider) {
                ForEach(ISCSIProvider.allCases) { Text($0.title).tag($0) }
            }
        } else {
            LabeledContent("iSCSI Provider", value: draft.iscsiProvider.title)
        }
        switch draft.iscsiProvider {
        case .comstar:
            fixedField("Target Group", text: $draft.comstarTargetGroup, prompt: "Optional", key: "comstar_tg")
            fixedField("Host Group", text: $draft.comstarHostGroup, prompt: "Optional", key: "comstar_hg")
        case .lio:
            fixedField("Target Portal Group", text: $draft.lioTargetPortalGroup, prompt: "tpg1", key: "lio_tpg")
        case .istgt, .iet:
            EmptyView()
        }
        Toggle("Thin Provisioning", isOn: $draft.sparse)
        if draft.iscsiProvider.hasWriteCache {
            Toggle("Write Cache", isOn: $draft.writeCache)
        }
    }

    @ViewBuilder
    private var passwordField: some View {
        LabeledContent("Password") {
            SecureField(isNew ? "Required" : "Unchanged", text: $draft.password)
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .accessibilityIdentifier("storage.password")
        }
        FieldError(message: errors["password"])
    }

    @ViewBuilder
    private func fixedField(_ title: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, key: String) -> some View {
        if isNew {
            LabeledTextField(title: title, prompt: prompt, text: text, keyboard: key == "server" ? .URL : .default, identifier: "storage.\(key)")
            FieldError(message: errors[key])
        } else {
            LabeledContent(title, value: text.wrappedValue)
        }
    }

    /// A text field with a Scan button; the scan results become a picker.
    @ViewBuilder
    private func scanPicker(_ title: LocalizedStringKey, selection: Binding<String>, key: String, fixed: Bool) -> some View {
        if fixed {
            LabeledContent(title, value: selection.wrappedValue)
        } else {
            if let results, !results.isEmpty {
                Picker(title, selection: selection) {
                    Text("Choose").tag("")
                    ForEach(results) { result in
                        Text(result.detail.map { "\(result.name) (\($0))" } ?? result.name).tag(result.name)
                    }
                    if !selection.wrappedValue.isEmpty, !results.contains(where: { $0.name == selection.wrappedValue }) {
                        Text(selection.wrappedValue).tag(selection.wrappedValue)
                    }
                }
                .accessibilityIdentifier("scan.\(key)")
                .onChange(of: selection.wrappedValue) {
                    if draft.type == .lvmthin { Task { await scanThinPools() } }
                }
            } else {
                LabeledTextField(title: title, prompt: "", text: selection, identifier: "storage.\(key)")
            }
            FieldError(message: errors[key])
            if draft.type.isOnNetwork {
                Button {
                    Task { await scan() }
                } label: {
                    HStack {
                        Label("Scan \(Text(title))", systemImage: "magnifyingglass")
                        Spacer()
                        if isScanning { ProgressView() }
                    }
                }
                .disabled(scanAddress.isEmpty || isScanning || storage.scanNode == nil)
                .accessibilityIdentifier("storage.scan")
            }
        }
    }

    @ViewBuilder
    private var thinPoolPicker: some View {
        if isNew {
            Picker("Thin Pool", selection: $draft.thinPool) {
                Text("Choose").tag("")
                ForEach(thinPools ?? []) { pool in
                    Text(pool.detail.map { "\(pool.name) (\($0))" } ?? pool.name).tag(pool.name)
                }
            }
            FieldError(message: errors["thinpool"])
        } else {
            LabeledContent("Thin Pool", value: draft.thinPool)
        }
    }

    /// The server or portal a network scan asks.
    private var scanAddress: String {
        (draft.type == .iscsi ? draft.portal : draft.server).trimmingCharacters(in: .whitespaces)
    }

    private func scan() async {
        guard let node = storage.scanNode else { return }
        let server = scanAddress
        let request: APIRequest<[StorageScanResult]>
        switch draft.type {
        case .nfs: request = PVE.scanNFS(node: node, server: server)
        case .cifs: request = PVE.scanCIFS(node: node, server: server, username: draft.username, password: draft.password, domain: draft.domain)
        case .pbs: request = PVE.scanPBS(node: node, server: server, username: draft.username, password: draft.password, fingerprint: draft.fingerprint, port: Int(draft.port))
        case .lvm, .lvmthin: request = PVE.scanVolumeGroups(node: node)
        case .zfspool: request = PVE.scanZFSPools(node: node)
        case .iscsi: request = PVE.scanISCSI(node: node, portal: server)
        case .dir, .btrfs, .cephfs, .rbd, .zfs, .esxi: return
        }
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        do {
            results = try await storage.scan(request)
            if results?.isEmpty == true { scanError = String(localized: "The scan found nothing.") }
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func loadLUNs() async {
        luns = nil
        guard let node = storage.scanNode, !baseStorage.isEmpty else { return }
        luns = try? await storage.connection.send(PVE.storageVolumes(node: node, storage: baseStorage, content: .images))
    }

    /// Pools or file systems of the cluster's Ceph; without Ceph the storage must be external.
    private func loadCephChoices() async {
        guard let node = storage.scanNode else {
            cephChoices = []
            draft.usesClusterCeph = false
            return
        }
        let request = draft.type == .rbd ? PVE.cephPools(node: node) : PVE.cephFilesystems(node: node)
        cephChoices = (try? await storage.scan(request)) ?? []
        if cephChoices?.isEmpty == true {
            draft.usesClusterCeph = false
        } else if draft.type == .rbd, draft.pool.isEmpty {
            draft.pool = cephChoices?.first?.name ?? ""
        }
    }

    private func scanThinPools() async {
        guard let node = storage.scanNode, !draft.volumeGroup.isEmpty else { return }
        thinPools = try? await storage.scan(PVE.scanThinPools(node: node, volumeGroup: draft.volumeGroup))
        if let first = thinPools?.first, draft.thinPool.isEmpty { draft.thinPool = first.name }
    }
}

// MARK: - PBS encryption

/// Client-side encryption of backups on a Proxmox Backup Server: none, a generated key or an uploaded one.
private struct PBSEncryptionSection: View {
    @Binding var draft: StorageConfigDraft
    let isNew: Bool
    let error: String?
    @State private var picksFile = false

    var body: some View {
        Section {
            if draft.hasEncryptionKey {
                LabeledContent("Encryption Key") {
                    Label(keySummary, systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                }
                Picker("Key", selection: $draft.encryptionMode) {
                    Text("Keep").tag(PBSEncryptionMode.keep)
                    Text("Remove").tag(PBSEncryptionMode.none)
                    Text("Generate New").tag(PBSEncryptionMode.autogenerate)
                    Text("Upload Other").tag(PBSEncryptionMode.upload)
                }
                .accessibilityIdentifier("pbs.encryption")
            } else {
                Picker("Encryption", selection: Binding(get: { draft.encryptionMode == .keep ? .none : draft.encryptionMode }, set: { draft.encryptionMode = $0 })) {
                    Text("None").tag(PBSEncryptionMode.none)
                    Text("Generate Key").tag(PBSEncryptionMode.autogenerate)
                    Text("Upload Key").tag(PBSEncryptionMode.upload)
                }
                .accessibilityIdentifier("pbs.encryption")
            }
            if draft.encryptionMode == .upload {
                TextField("Key", text: $draft.encryptionKey, prompt: Text("{\"kdf\": …, \"data\": …}"), axis: .vertical)
                    .lineLimit(2...8)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Choose Key File", systemImage: "doc") { picksFile = true }
            }
            FieldError(message: error)
        } header: {
            Text("Encryption")
        } footer: {
            if draft.hasEncryptionKey, draft.encryptionMode != .keep {
                Label("Removing or replacing the key breaks restoring the backups made with it.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if draft.encryptionMode == .autogenerate {
                Text("The key is shown once after saving. Keep it safe: without it, encrypted backups cannot be restored.")
            } else {
                Text("Backups are encrypted on the node before they reach the backup server.")
            }
        }
        .fileImporter(isPresented: $picksFile, allowedContentTypes: [.json, .data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) { draft.encryptionKey = text }
        }
    }

    private var keySummary: String {
        guard let info = draft.encryptionKeyInfo, info.contains(":") else { return String(localized: "Active") }
        // The web interface shows the first eight bytes of the fingerprint.
        return info.split(separator: ":").prefix(8).joined(separator: ":")
    }
}

/// The key Proxmox generated for an encrypted PBS storage, shown once so it can be saved.
private struct EncryptionKeyView: View {
    let storage: String
    let key: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(key)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button("Copy Key", systemImage: "doc.on.doc") { UIPasteboard.general.string = key }
                ShareLink(item: KeyFile(name: "pve-storage-\(storage).enc", text: key), preview: SharePreview("pve-storage-\(storage).enc")) {
                    Label("Save Key File", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Save the key in a password manager and keep a copy offline. Losing it makes every backup encrypted with it unusable.")
            }
        }
        .navigationTitle("Save the Encryption Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// A text file to share, e.g. an encryption key.
private struct KeyFile: Transferable {
    let name: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            let url = FileManager.default.temporaryDirectory.appending(path: file.name)
            try Data(file.text.utf8).write(to: url)
            return SentTransferredFile(url)
        }
    }
}
