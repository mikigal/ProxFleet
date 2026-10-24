import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Backups of a guest from every backup storage of its node, like the web interface's Backup panel.
struct BackupsView: View {
    let detail: GuestDetail
    @State private var showsBackupNow = false
    @State private var pendingDeletion: BackupVolume?
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        List {
            if let backups = detail.backups {
                Section {
                    ForEach(backups) { backup in
                        NavigationLink {
                            BackupDetailView(source: detail, backup: backup, guest: detail)
                        } label: {
                            BackupRow(backup: backup)
                        }
                        .swipeActions {
                            if !backup.isProtected {
                                Button("Delete") { pendingDeletion = backup }
                                    .tint(.red)
                            }
                        }
                        .accessibilityIdentifier("backup.\(backup.fileName)")
                    }
                } footer: {
                    if !backups.isEmpty, !detail.can("VM.Backup") {
                        Text("Backing up and restoring need the VM.Backup privilege on /vms/\(String(detail.reference.vmid)).")
                    }
                }
            }
        }
        .overlay {
            if detail.backups == nil {
                ProgressView()
            } else if detail.backups?.isEmpty == true {
                ContentUnavailableView {
                    Label("No Backups", systemImage: "archivebox")
                } description: {
                    Text("Backups of this guest on the storages of \(detail.reference.node) show up here.")
                } actions: {
                    if detail.can("VM.Backup") {
                        Button("Back Up Now") { showsBackupNow = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .navigationTitle("Backups")
        .refreshable { errorMessage = await detail.loadBackups() }
        .task { errorMessage = await detail.loadBackups() }
        .disabled(isWorking)
        .toolbar {
            if detail.can("VM.Backup") {
                ToolbarItem(placement: .primaryAction) {
                    Button("Back Up Now", systemImage: "plus") { showsBackupNow = true }
                        .accessibilityIdentifier("backup.now")
                }
            }
        }
        .sheet(isPresented: $showsBackupNow) {
            NavigationStack {
                BackupNowView(detail: detail)
            }
            .serverDestinations(detail.connection)
        }
        .alert("Delete Backup?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { backup in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await delete(backup) } }
        } message: { backup in
            Text("The backup from \(backup.date?.formatted(date: .abbreviated, time: .shortened) ?? backup.fileName) is deleted permanently.")
        }
        .alert("Backup Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func delete(_ backup: BackupVolume) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await detail.runBackupAction(PVE.deleteBackup(node: detail.reference.node, volume: backup.volumeID))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Where a backup screen finds the current state of a backup and runs its actions: a guest's backup list
/// or the content of a storage.
@MainActor
protocol BackupSource: AnyObject {
    var connection: ServerConnection { get }
    /// The node whose storages hold the backups.
    var backupNode: String { get }
    func backup(withID id: String) -> BackupVolume?
    func runBackupAction(_ request: APIRequest<String?>) async throws(ConfigUpdateError)
}

extension GuestDetail: BackupSource {
    var backupNode: String { reference.node }
    func backup(withID id: String) -> BackupVolume? { backups?.first { $0.volumeID == id } }
}

extension StorageDetail: BackupSource {
    var backupNode: String { node }
    func backup(withID id: String) -> BackupVolume? { backups?.first { $0.volumeID == id } }
}

extension BackupVolume {
    /// The kind of guest the backup holds, from its subtype or its file name.
    var guestKind: GuestKind {
        if let subtype { return subtype == "lxc" ? .container : .virtualMachine }
        return fileName.contains("-lxc-") || volumeID.contains("/ct/") ? .container : .virtualMachine
    }
}

struct BackupRow: View {
    let backup: BackupVolume

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: backup.isProtected ? "lock.fill" : "archivebox")
                .foregroundStyle(backup.isProtected ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                if let date = backup.date {
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                        .font(.body.weight(.medium))
                } else {
                    Text(backup.fileName)
                }
                Text([backup.storage, backup.size.map(Format.bytes), backup.format].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !backup.notes.isEmpty {
                    Text(backup.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One backup: details, notes, protection, its configuration, restore, pruning and deletion.
struct BackupDetailView: View {
    let source: any BackupSource
    let backup: BackupVolume
    /// The guest's own screen, which can restore over the guest; nil from a storage, where restores create a new guest.
    let guest: GuestDetail?
    @State private var notes: String
    @State private var showsRestore = false
    @State private var showsPrune = false
    @State private var confirmsDeletion = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// Set by the restore sheet; opened once the sheet is gone, as pushing while it closes is unreliable.
    @State private var newGuest: GuestReference?
    @State private var openedGuest: GuestReference?
    @Environment(\.dismiss) private var dismiss

    init(source: any BackupSource, backup: BackupVolume, guest: GuestDetail?) {
        self.source = source
        self.backup = backup
        self.guest = guest
        _notes = State(initialValue: backup.notes)
    }

    /// The backup as last loaded, so protection and notes reflect changes made here.
    private var current: BackupVolume { source.backup(withID: backup.volumeID) ?? backup }
    private var node: String { source.backupNode }
    private var canRestore: Bool { guest?.can("VM.Backup") ?? true }

    var body: some View {
        Form {
            Section {
                if let date = current.date {
                    LabeledContent("Created", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Storage", value: current.storage)
                if let size = current.size {
                    LabeledContent("Size", value: Format.bytes(size))
                }
                if let format = current.format {
                    LabeledContent("Format", value: format)
                }
                if current.isEncrypted {
                    LabeledContent("Encrypted", value: String(localized: "Yes"))
                }
                Text(current.fileName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section {
                TextField("None", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("backup.notes")
                if notes.trimmingCharacters(in: .whitespacesAndNewlines) != current.notes {
                    Button("Save Notes") {
                        Task { await perform(PVE.updateBackup(node: node, volume: backup.volumeID, notes: notes)) }
                    }
                    .accessibilityIdentifier("backup.notes.save")
                }
            } header: {
                Text("Notes")
            }
            Section {
                Toggle("Protected", isOn: Binding(get: { current.isProtected }, set: { protect in
                    Task { await perform(PVE.updateBackup(node: node, volume: backup.volumeID, isProtected: protect)) }
                }))
                .accessibilityIdentifier("backup.protected")
            } footer: {
                Text("Protected backups are not deleted, neither by hand nor by the storage's retention settings.")
            }
            Section {
                NavigationLink("Show Configuration") {
                    BackupConfigurationView(node: node, backup: backup, connection: source.connection)
                }
                if canRestore {
                    Button("Restore…") { showsRestore = true }
                        .accessibilityIdentifier("backup.restore")
                }
                if current.vmid != nil {
                    Button("Prune Backups…") { showsPrune = true }
                        .accessibilityIdentifier("backup.prune")
                }
            } footer: {
                if current.vmid != nil {
                    Text("Pruning removes older backups of this guest on \(current.storage) by retention rules.")
                }
            }
            Section {
                Button("Delete Backup", role: .destructive) { confirmsDeletion = true }
                    .disabled(current.isProtected)
                    .accessibilityIdentifier("backup.delete")
            } footer: {
                if current.isProtected {
                    Text("Turn off protection to delete this backup.")
                }
            }
            if isWorking {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Working…")
                    }
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .sheet(isPresented: $showsRestore, onDismiss: {
            openedGuest = newGuest
            newGuest = nil
        }) {
            NavigationStack {
                RestoreView(connection: source.connection, node: node, backup: current, guest: guest) { target in
                    if let guest, target.vmid == guest.reference.vmid {
                        Task { await guest.reloadAfterRestore() }
                    } else {
                        newGuest = target
                    }
                }
            }
            .serverDestinations(source.connection)
        }
        .sheet(isPresented: $showsPrune) {
            if let vmid = current.vmid {
                NavigationStack {
                    PruneBackupsView(source: source, storage: current.storage, kind: current.guestKind, vmid: vmid)
                }
            }
        }
        .navigationDestination(item: $openedGuest) { reference in
            GuestDetailView(reference: reference, connection: source.connection)
        }
        .alert("Delete Backup?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    if await perform(PVE.deleteBackup(node: node, volume: backup.volumeID)) { dismiss() }
                }
            }
        } message: {
            Text("This backup is deleted permanently.")
        }
    }

    @discardableResult
    private func perform(_ request: APIRequest<String?>) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await source.runBackupAction(request)
            notes = current.notes
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// The guest configuration saved in a backup.
private struct BackupConfigurationView: View {
    let node: String
    let backup: BackupVolume
    let connection: ServerConnection
    @State private var lines: [String]?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let lines {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .overlay {
            if let errorMessage {
                ContentUnavailableView("Cannot Read Configuration", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if lines == nil {
                ProgressView()
            }
        }
        .navigationTitle("Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                lines = GuestConfig.displayLines(ofBackupConfiguration: try await connection.send(PVE.backupConfiguration(node: node, volume: backup.volumeID)))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Starts a backup of the guest, like the web interface's Backup Now dialog.
private struct BackupNowView: View {
    let detail: GuestDetail
    @State private var draft: BackupDraft

    init(detail: GuestDetail) {
        self.detail = detail
        _draft = State(initialValue: BackupDraft(guest: detail.reference))
    }

    private var kindName: String { detail.reference.kind == .virtualMachine ? "VM" : "CT" }

    var body: some View {
        CreationWizard<SinglePageStep, _>(
            title: "Back Up Now",
            connection: detail.connection,
            reference: detail.reference,
            problems: draft.problems,
            makeRequest: { PVE.backupNow(draft) },
            onCreated: { _ in Task { await detail.loadBackups() } },
            actionTitle: "Back Up",
            workingTitle: "Backing up \(kindName) \(String(detail.reference.vmid))…"
        ) { _, errors in
            Section {
                NodeStoragePicker(title: "Storage", connection: detail.connection, node: detail.reference.node, content: "backup", selection: $draft.storage)
                FieldError(message: errors["storage"])
            }
            Section {
                Picker("Mode", selection: $draft.mode) {
                    Text("Snapshot").tag(BackupMode.snapshot)
                    Text("Suspend").tag(BackupMode.suspend)
                    Text("Stop").tag(BackupMode.stop)
                }
                .accessibilityIdentifier("backup.mode")
                Picker("Compression", selection: $draft.compression) {
                    Text("ZSTD (fast and good)").tag(BackupCompression.zstd)
                    Text("GZIP (good)").tag(BackupCompression.gzip)
                    Text("LZO (fast)").tag(BackupCompression.lzo)
                    Text("None").tag(BackupCompression.none)
                }
                FieldError(message: errors["mode"] ?? errors["compress"])
            } footer: {
                switch draft.mode {
                case .snapshot: Text("The guest keeps running. Containers need a storage that supports snapshots.")
                case .suspend: Text("The guest is paused or suspended briefly to get a consistent state.")
                case .stop: Text("The guest is shut down for the backup and started again afterwards. Most consistent, but with downtime.")
                }
            }
            Section {
                TextField("None", text: $draft.notes, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                FieldError(message: errors["notes-template"])
                Toggle("Protected", isOn: $draft.isProtected)
            } header: {
                Text("Notes")
            } footer: {
                Text("In notes, {{guestname}}, {{vmid}}, {{node}} and {{cluster}} are replaced. A protected backup is kept until you remove the protection.")
            }
            Section {
                Toggle("Prune Older Backups", isOn: $draft.prunes)
                    .accessibilityIdentifier("backup.prune")
                Picker("Notify", selection: $draft.usesLegacySendmail) {
                    Text("Global Settings").tag(false)
                    Text("Sendmail (Legacy)").tag(true)
                }
                if draft.usesLegacySendmail {
                    LabeledTextField(title: "Recipients", prompt: "root@pam", text: $draft.mailto, keyboard: .emailAddress, identifier: "backup.mailto")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    FieldError(message: errors["mailto"])
                }
            } footer: {
                Text("Prune removes this guest's older backups on the storage by the storage's retention settings afterwards. Notifications go to the datacenter's matchers and targets, or by sendmail to the recipients.")
            }
        }
    }
}

/// Restores a backup over its guest or as a new guest, like the web interface's Restore dialog.
struct RestoreView: View {
    let connection: ServerConnection
    let node: String
    /// The guest whose screen the restore started from; without it, the restore creates a new guest.
    let guest: GuestDetail?
    let onRestored: (GuestReference) -> Void
    @State private var draft: RestoreDraft
    /// Values of the backup's configuration, shown as placeholders of the overrides.
    @State private var backupValues: [String: String] = [:]

    init(connection: ServerConnection, node: String, backup: BackupVolume, guest: GuestDetail?, onRestored: @escaping (GuestReference) -> Void) {
        self.connection = connection
        self.node = node
        self.guest = guest
        self.onRestored = onRestored
        let source = guest?.reference ?? GuestReference(node: node, vmid: backup.vmid ?? 0, kind: backup.guestKind)
        var draft = RestoreDraft(backup: backup, source: source)
        draft.overwrites = guest != nil
        draft.sourceIsRunning = (guest?.powerState ?? .stopped) != .stopped
        _draft = State(initialValue: draft)
    }

    private var isVM: Bool { draft.source.kind == .virtualMachine }
    private var kindName: String { isVM ? "VM" : "CT" }
    private var guestName: String { guest?.name ?? "" }

    var body: some View {
        CreationWizard<SinglePageStep, _>(
            title: "Restore",
            connection: connection,
            reference: draft.target,
            problems: draft.problems,
            makeRequest: { PVE.restore(draft) },
            onCreated: onRestored,
            actionTitle: "Restore",
            workingTitle: "Restoring \(kindName) \(String(draft.target.vmid))…",
            confirmation: draft.overwrites ? (
                String(localized: "Replace \(kindName) \(String(draft.source.vmid))?"),
                String(localized: "The current disks and configuration of \(guestName) are deleted and replaced by the backup. This cannot be undone.")
            ) : nil
        ) { _, errors in
            Section {
                if let date = draft.backup.date {
                    LabeledContent("Backup", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if guest != nil {
                    Picker("Restore To", selection: $draft.overwrites) {
                        Text("This \(kindName) (\(String(draft.source.vmid)))").tag(true)
                        Text("New \(kindName)").tag(false)
                    }
                    .accessibilityIdentifier("restore.target")
                    FieldError(message: errors["force"])
                } else if let vmid = draft.backup.vmid {
                    LabeledContent("Backup Of", value: "\(kindName) \(String(vmid))")
                }
                if !draft.overwrites {
                    GuestIDField(connection: connection, vmid: $draft.vmid, error: errors["vmid"])
                }
            } footer: {
                if draft.overwrites {
                    Text("The current disks and configuration of \(guestName) are replaced by the backup.")
                } else {
                    Text("The new guest gets the configuration of the backup, including its name.")
                }
            }
            Section {
                NodeStoragePicker(
                    title: "Storage", connection: connection, node: node, content: isVM ? "images" : "rootdir",
                    selection: $draft.storage, defaultTitle: isVM ? "From Backup Configuration" : nil
                )
                FieldError(message: errors["storage"])
                LabeledContent("Bandwidth Limit") {
                    TextField("Storage Default", value: $draft.bandwidthLimit, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                FieldError(message: errors["bwlimit"])
                Toggle("Unique MAC Addresses", isOn: $draft.uniqueMACAddresses)
                if isVM, draft.backup.isOnBackupServer {
                    Toggle("Live Restore", isOn: $draft.liveRestore)
                }
                Toggle("Start After Restore", isOn: $draft.startAfterRestore)
                    .disabled(isLiveRestore)
                if offersHA {
                    Toggle("Add to HA", isOn: $draft.isHAManaged)
                    FieldError(message: errors["ha-managed"])
                }
            } footer: {
                if isLiveRestore {
                    Text("The VM starts right away while its disks are restored in the background. If anything goes wrong during the restore, data the VM writes meanwhile may be lost.")
                } else {
                    Text("Bandwidth limit in MiB/s; 0 turns off all limits. Give a restored copy new MAC addresses when the original still runs on the same network.")
                }
            }
            if !isVM {
                Section {
                    Picker("Privilege Level", selection: $draft.unprivileged) {
                        Text("From Backup").tag(Bool?.none)
                        Text("Unprivileged").tag(Bool?.some(true))
                        Text("Privileged").tag(Bool?.some(false))
                    }
                    FieldError(message: errors["unprivileged"])
                }
            }
            Section {
                LabeledContent(isVM ? "Name" : "Host Name") {
                    TextField(backupValues[isVM ? "name" : "hostname"] ?? String(localized: "From Backup"), text: $draft.name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                FieldError(message: errors[isVM ? "name" : "hostname"])
                overrideField("Cores", value: $draft.cores, key: "cores", errors: errors)
                if isVM {
                    overrideField("Sockets", value: $draft.sockets, key: "sockets", errors: errors)
                }
                overrideField("Memory (MiB)", value: $draft.memoryMiB, key: "memory", errors: errors)
            } header: {
                Text("Override Settings")
            } footer: {
                Text("Empty fields keep the values of the backup.")
            }
            .task { await loadBackupValues() }
        }
    }

    private var isLiveRestore: Bool { isVM && draft.backup.isOnBackupServer && draft.liveRestore }

    /// High availability needs a cluster.
    /// HA needs a cluster; before PVE 9.1 guests are added to it after creation only.
    private var offersHA: Bool { (connection.snapshot?.nodes.count ?? 0) > 1 && connection.supports(.haManagedCreation) }

    @ViewBuilder
    private func overrideField(_ title: LocalizedStringKey, value: Binding<Int?>, key: String, errors: [String: String]) -> some View {
        LabeledContent(title) {
            TextField(backupValues[key] ?? String(localized: "From Backup"), value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
        FieldError(message: errors[key])
    }

    private func loadBackupValues() async {
        guard backupValues.isEmpty,
              let text = try? await connection.send(PVE.backupConfiguration(node: node, volume: draft.backup.volumeID))
        else { return }
        for line in GuestConfig.displayLines(ofBackupConfiguration: text) {
            // Snapshot sections come after the current configuration.
            if line.hasPrefix("[") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            if ["name", "hostname", "cores", "sockets", "memory"].contains(key) {
                backupValues[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
    }
}

/// Removes a guest's older backups on one storage by retention rules, with a preview of what stays, like the web
/// interface's Prune dialog.
struct PruneBackupsView: View {
    let source: any BackupSource
    let storage: String
    let kind: GuestKind
    let vmid: Int
    @State private var options = PruneOptions()
    /// The storage's own retention settings, which apply while no field is set.
    @State private var storageOptions = PruneOptions()
    @State private var candidates: [PruneCandidate]?
    @State private var errorMessage: String?
    @State private var isPruning = false
    @State private var confirms = false
    @Environment(\.dismiss) private var dismiss

    private var chosen: PruneOptions? { options.serialized == nil ? nil : options }
    private var removals: Int { candidates?.filter { !$0.isKept }.count ?? 0 }

    var body: some View {
        Form {
            Section {
                RetentionFields(prune: $options, error: options.problems["prune-backups"])
            } header: {
                Text("Keep")
            } footer: {
                Text("With no field set, the retention settings of \(storage) apply. Protected backups are always kept.")
            }
            Section {
                if let candidates {
                    if candidates.isEmpty {
                        Text("No Backups").foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { candidate in
                        HStack {
                            Text(candidate.date?.formatted(date: .abbreviated, time: .shortened) ?? candidate.volumeID)
                                .strikethrough(!candidate.isKept)
                                .foregroundStyle(candidate.isKept ? .primary : .secondary)
                            Spacer()
                            Text(candidate.isKept ? (candidate.keepReason ?? String(localized: "Keep")) : String(localized: "Remove"))
                                .font(.caption)
                                .foregroundStyle(candidate.isKept ? Color.secondary : Color.red)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text("Result")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Prune \(kind == .virtualMachine ? "VM" : "CT") \(String(vmid))")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isPruning)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Prune", isWorking: isPruning) { confirms = true }
                    .disabled(removals == 0 || !options.problems.isEmpty)
                    .accessibilityIdentifier("prune.start")
            }
        }
        .alert("Remove \(removals) Backups?", isPresented: $confirms) {
            Button("Cancel", role: .cancel) {}
            Button("Prune", role: .destructive) { Task { await prune() } }
        } message: {
            Text("The backups marked Remove are deleted permanently.")
        }
        .task {
            if let config = try? await source.connection.send(PVE.storageConfig(storage)) {
                storageOptions = PruneOptions(config.values["prune-backups"])
            }
        }
        .task(id: options) {
            guard options.problems.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let found = try await source.connection.send(PVE.prunePreview(node: source.backupNode, storage: storage, kind: kind, vmid: vmid, options: chosen))
                candidates = PruneCandidate.withKeepReasons(found, options: chosen ?? storageOptions)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func prune() async {
        isPruning = true
        defer { isPruning = false }
        do {
            try await source.runBackupAction(PVE.pruneBackups(node: source.backupNode, storage: storage, kind: kind, vmid: vmid, options: chosen))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
