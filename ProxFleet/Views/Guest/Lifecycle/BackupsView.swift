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
                            BackupDetailView(detail: detail, backup: backup)
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

private struct BackupRow: View {
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

/// One backup: details, notes, protection, its configuration, restore and deletion.
private struct BackupDetailView: View {
    let detail: GuestDetail
    let backup: BackupVolume
    @State private var notes: String
    @State private var showsRestore = false
    @State private var confirmsDeletion = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// Set by the restore sheet; opened once the sheet is gone, as pushing while it closes is unreliable.
    @State private var newGuest: GuestReference?
    @State private var openedGuest: GuestReference?
    @Environment(\.dismiss) private var dismiss

    init(detail: GuestDetail, backup: BackupVolume) {
        self.detail = detail
        self.backup = backup
        _notes = State(initialValue: backup.notes)
    }

    /// The backup as last loaded, so protection and notes reflect changes made here.
    private var current: BackupVolume { detail.backups?.first { $0.volumeID == backup.volumeID } ?? backup }

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
                        Task { await perform(PVE.updateBackup(node: detail.reference.node, volume: backup.volumeID, notes: notes)) }
                    }
                    .accessibilityIdentifier("backup.notes.save")
                }
            } header: {
                Text("Notes")
            }
            Section {
                Toggle("Protected", isOn: Binding(get: { current.isProtected }, set: { protect in
                    Task { await perform(PVE.updateBackup(node: detail.reference.node, volume: backup.volumeID, isProtected: protect)) }
                }))
                .accessibilityIdentifier("backup.protected")
            } footer: {
                Text("Protected backups are not deleted, neither by hand nor by the storage's retention settings.")
            }
            Section {
                NavigationLink("Show Configuration") {
                    BackupConfigurationView(node: detail.reference.node, backup: backup, connection: detail.connection)
                }
                if detail.can("VM.Backup") {
                    Button("Restore…") { showsRestore = true }
                        .accessibilityIdentifier("backup.restore")
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
                RestoreView(detail: detail, backup: current) { target in
                    if target.vmid == detail.reference.vmid {
                        Task { await detail.reloadAfterRestore() }
                    } else {
                        newGuest = target
                    }
                }
            }
            .serverDestinations(detail.connection)
        }
        .navigationDestination(item: $openedGuest) { reference in
            GuestDetailView(reference: reference, connection: detail.connection)
        }
        .alert("Delete Backup?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    if await perform(PVE.deleteBackup(node: detail.reference.node, volume: backup.volumeID)) { dismiss() }
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
            try await detail.runBackupAction(request)
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
        }
    }
}

/// Restores a backup over its guest or as a new guest, like the web interface's Restore dialog.
private struct RestoreView: View {
    let detail: GuestDetail
    let onRestored: (GuestReference) -> Void
    @State private var draft: RestoreDraft

    init(detail: GuestDetail, backup: BackupVolume, onRestored: @escaping (GuestReference) -> Void) {
        self.detail = detail
        self.onRestored = onRestored
        var draft = RestoreDraft(backup: backup, source: detail.reference)
        draft.sourceIsRunning = detail.powerState != .stopped
        _draft = State(initialValue: draft)
    }

    private var isVM: Bool { detail.reference.kind == .virtualMachine }
    private var kindName: String { isVM ? "VM" : "CT" }

    var body: some View {
        CreationWizard<SinglePageStep, _>(
            title: "Restore",
            connection: detail.connection,
            reference: draft.target,
            problems: draft.problems,
            makeRequest: { PVE.restore(draft) },
            onCreated: onRestored,
            actionTitle: "Restore",
            workingTitle: "Restoring \(kindName) \(String(draft.target.vmid))…",
            confirmation: draft.overwrites ? (
                String(localized: "Replace \(kindName) \(String(detail.reference.vmid))?"),
                String(localized: "The current disks and configuration of \(detail.name) are deleted and replaced by the backup. This cannot be undone.")
            ) : nil
        ) { _, errors in
            Section {
                if let date = draft.backup.date {
                    LabeledContent("Backup", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Picker("Restore To", selection: $draft.overwrites) {
                    Text("This \(kindName) (\(String(detail.reference.vmid)))").tag(true)
                    Text("New \(kindName)").tag(false)
                }
                .accessibilityIdentifier("restore.target")
                FieldError(message: errors["force"])
                if !draft.overwrites {
                    GuestIDField(connection: detail.connection, vmid: $draft.vmid, error: errors["vmid"])
                }
            } footer: {
                if draft.overwrites {
                    Text("The current disks and configuration of \(detail.name) are replaced by the backup.")
                } else {
                    Text("The new guest gets the configuration of the backup, including its name.")
                }
            }
            Section {
                NodeStoragePicker(
                    title: "Storage", connection: detail.connection, node: detail.reference.node, content: isVM ? "images" : "rootdir",
                    selection: $draft.storage, defaultTitle: isVM ? "From Backup Configuration" : nil
                )
                FieldError(message: errors["storage"])
                Toggle("Unique MAC Addresses", isOn: $draft.uniqueMACAddresses)
                Toggle("Start After Restore", isOn: $draft.startAfterRestore)
            } footer: {
                Text("Give a restored copy new MAC addresses when the original still runs on the same network.")
            }
        }
    }
}
