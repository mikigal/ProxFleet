import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The datacenter's storage definitions: add, edit, disable, restrict to nodes and remove.
struct DatacenterStorageView: View {
    @State private var storage: DatacenterStorage
    @State private var creating: StorageBackend?
    @State private var removing: StorageConfig?
    @State private var errorMessage: String?

    init(connection: ServerConnection) {
        _storage = State(initialValue: DatacenterStorage(connection: connection))
    }

    var body: some View {
        List {
            if let configs = storage.configs {
                Section {
                    ForEach(configs) { config in
                        NavigationLink {
                            if let draft = StorageConfigDraft(config) {
                                StorageConfigEditor(storage: storage, draft: draft, digest: config.digest, isNew: false)
                            } else {
                                UnsupportedStorageView(config: config)
                            }
                        } label: {
                            StorageConfigRow(config: config)
                        }
                        .accessibilityIdentifier("storageconfig.\(config.storage)")
                        .swipeActions {
                            // Not `role: .destructive`: a full swipe would hide the row, but this only asks first.
                            if storage.canModify {
                                Button("Remove", systemImage: "trash") { removing = config }
                                    .tint(.red)
                            }
                        }
                    }
                } footer: {
                    Text("Storage definitions apply to every node of the cluster, or to the nodes they list.")
                }
            }
        }
        .overlay {
            if let error = storage.loadError, storage.configs == nil {
                ContentUnavailableView("Cannot Load the Storage", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if storage.configs == nil {
                ProgressView()
            }
        }
        .navigationTitle("Storage")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    ForEach(StorageBackend.allCases) { type in
                        Button(type.title, systemImage: type.systemImage) { creating = type }
                    }
                }
                .disabled(!storage.canModify)
                .accessibilityIdentifier("storageconfig.add")
            }
        }
        .refreshable { await storage.load() }
        .task { await storage.load() }
        .sheet(item: $creating) { type in
            NavigationStack {
                StorageConfigEditor(storage: storage, draft: StorageConfigDraft(type: type), digest: nil, isNew: true)
            }
        }
        .confirmationDialog("Remove \(removing?.storage ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { config in
            Button("Remove", role: .destructive) { Task { await remove(config) } }
                .accessibilityIdentifier("storageconfig.remove.confirm")
        } message: { _ in
            Text("Only the definition is removed; the data on the storage stays. Guests whose disks are on it cannot start until it is added again.")
        }
        .alert("Storage Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func remove(_ config: StorageConfig) async {
        do {
            try await storage.delete(config.storage)
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
        }
    }
}

private struct StorageConfigRow: View {
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

/// Ceph, iSCSI, ESXi and other storages the app does not edit yet.
private struct UnsupportedStorageView: View {
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
        }
        .navigationTitle(config.storage)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Editor

/// Creates or edits a storage definition. Connection settings can only be set when creating.
struct StorageConfigEditor: View {
    let storage: DatacenterStorage
    let original: StorageConfigDraft
    let digest: String?
    let isNew: Bool
    @State private var draft: StorageConfigDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(storage: DatacenterStorage, draft: StorageConfigDraft, digest: String?, isNew: Bool) {
        self.storage = storage
        self.digest = digest
        self.isNew = isNew
        original = draft
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
                if draft.type != .pbs {
                    contentSection
                }
                nodesSection
                if draft.holdsBackups {
                    retentionSection
                }
            }
            .disabled(!storage.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? Text("New \(Text(draft.type.title))") : Text(draft.storage))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
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
        }
    }

    private var retentionSection: some View {
        Section {
            Toggle("Keep All Backups", isOn: $draft.prune.keepAll)
            if !draft.prune.keepAll {
                ForEach(PruneOptions.keys, id: \.self) { key in
                    LabeledTextField(title: Self.retentionTitle(key), prompt: "–", text: Binding(get: { draft.prune.counts[key] ?? "" }, set: { draft.prune.counts[key] = $0 }),
                                     keyboard: .numberPad, identifier: "prune.\(key)")
                }
            }
            FieldError(message: errors["prune-backups"])
            LabeledTextField(title: "Max. Protected", prompt: "Default", text: $draft.maxProtectedBackups, keyboard: .numbersAndPunctuation)
        } header: {
            Text("Backup Retention")
        } footer: {
            Text("Backup jobs and Back Up Now without overriding remove older backups beyond these counts. With nothing set, all backups are kept. Protected backups are never removed.")
        }
    }

    private static func retentionTitle(_ key: String) -> LocalizedStringKey {
        switch key {
        case "keep-last": "Keep Last"
        case "keep-hourly": "Keep Hourly"
        case "keep-daily": "Keep Daily"
        case "keep-weekly": "Keep Weekly"
        case "keep-monthly": "Keep Monthly"
        default: "Keep Yearly"
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
            if isNew {
                try await storage.create(draft)
            } else {
                try await storage.update(draft.storage, draft.changes(from: original), digest: digest)
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

    var body: some View {
        Section {
            switch draft.type {
            case .dir, .btrfs:
                fixedField("Path", text: $draft.path, prompt: "/mnt/data", key: "path")
            case .nfs:
                fixedField("Server", text: $draft.server, prompt: "192.168.1.10", key: "server")
                scanPicker("Export", selection: $draft.export, key: "export", fixed: !isNew)
                LabeledTextField(title: "Mount Options", prompt: "vers=4.2", text: $draft.mountOptions)
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
                scanPicker("Volume Group", selection: $draft.volumeGroup, key: "vgname", fixed: !isNew)
            case .lvmthin:
                scanPicker("Volume Group", selection: $draft.volumeGroup, key: "vgname", fixed: !isNew)
                thinPoolPicker
            case .zfspool:
                scanPicker("ZFS Pool", selection: $draft.pool, key: "pool", fixed: !isNew)
                Toggle("Thin Provisioning", isOn: $draft.sparse)
                LabeledTextField(title: "Block Size", prompt: "16k", text: $draft.blockSize)
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
            } else if draft.type.isOnNetwork, let node = storage.scanNode {
                Text("Scan asks the server from \(node), so it must be reachable from the nodes.")
            }
        }
        .task(id: draft.type) {
            if isNew, [.lvm, .lvmthin, .zfspool].contains(draft.type) { await scan() }
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
                .disabled(draft.server.trimmingCharacters(in: .whitespaces).isEmpty || isScanning || storage.scanNode == nil)
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

    private func scan() async {
        guard let node = storage.scanNode else { return }
        let server = draft.server.trimmingCharacters(in: .whitespaces)
        let request: APIRequest<[StorageScanResult]>
        switch draft.type {
        case .nfs: request = PVE.scanNFS(node: node, server: server)
        case .cifs: request = PVE.scanCIFS(node: node, server: server, username: draft.username, password: draft.password, domain: draft.domain)
        case .pbs: request = PVE.scanPBS(node: node, server: server, username: draft.username, password: draft.password, fingerprint: draft.fingerprint, port: Int(draft.port))
        case .lvm, .lvmthin: request = PVE.scanVolumeGroups(node: node)
        case .zfspool: request = PVE.scanZFSPools(node: node)
        case .dir, .btrfs: return
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

    private func scanThinPools() async {
        guard let node = storage.scanNode, !draft.volumeGroup.isEmpty else { return }
        thinPools = try? await storage.scan(PVE.scanThinPools(node: node, volumeGroup: draft.volumeGroup))
        if let first = thinPools?.first, draft.thinPool.isEmpty { draft.thinPool = first.name }
    }
}
