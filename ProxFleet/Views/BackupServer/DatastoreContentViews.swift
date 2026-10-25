import FleetCore
import PBSKit
import ProxmoxCore
import SwiftUI

// MARK: - Namespace

/// A namespace of a datastore: the namespaces below it and its backup groups.
struct DatastoreContentView: View {
    @State private var content: DatastoreContent
    @State private var search = ""
    @State private var creatingNamespace = false
    @State private var verifying = false
    @State private var pruning = false
    @State private var deleting: BackupNamespace?
    @State private var moving: BackupNamespace?
    @State private var message: (title: String, text: String)?

    init(store: String, namespace: BackupNamespace = .root, connection: ServerConnection) {
        _content = State(initialValue: DatastoreContent(store: store, namespace: namespace, connection: connection))
    }

    private var connection: ServerConnection { content.connection }

    private var shownGroups: [BackupGroup] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return content.groups ?? [] }
        return (content.groups ?? []).filter { group in
            [group.reference.path, group.comment ?? "", group.owner ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            if let error = content.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let namespaces = content.namespaces, !namespaces.isEmpty, search.isEmpty {
                Section("Namespaces") {
                    ForEach(namespaces) { namespace in
                        NavigationLink {
                            DatastoreContentView(store: content.store, namespace: namespace, connection: connection)
                        } label: {
                            Label(namespace.name, systemImage: "folder")
                        }
                        .accessibilityIdentifier("namespace.\(namespace.path)")
                        .swipeActions {
                            if content.can("Datastore.Modify") {
                                Button("Delete", systemImage: "trash") { deleting = namespace }
                                    .tint(.red)
                                if connection.supports(backupServer: .moveGroupsAndNamespaces) {
                                    Button("Move", systemImage: "arrow.right.doc.on.clipboard") { moving = namespace }
                                        .tint(.indigo)
                                }
                            }
                        }
                    }
                }
            }
            ForEach(BackupType.allCases) { type in
                let groups = shownGroups.filter { $0.reference.type == type }
                if !groups.isEmpty {
                    Section(type.title) {
                        ForEach(groups) { group in
                            NavigationLink {
                                BackupGroupView(store: content.store, group: group, connection: connection)
                            } label: {
                                BackupGroupRow(group: group)
                            }
                            .accessibilityIdentifier("group.\(group.reference.path)")
                            .contextMenu {
                                Button("Copy Name", systemImage: "doc.on.doc") { UIPasteboard.general.string = group.reference.path }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(content.namespace.isRoot ? content.store : content.namespace.name)
        .searchable(text: $search, prompt: "Search groups")
        .overlay {
            if content.groups == nil, content.loadError == nil {
                ProgressView()
            } else if content.groups?.isEmpty == true, content.namespaces?.isEmpty == true {
                ContentUnavailableView("No Backups", systemImage: "archivebox", description: Text("Nothing has been backed up to this namespace yet."))
            } else if !search.isEmpty, shownGroups.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Namespace", systemImage: "folder.badge.gearshape") {
                    Button("New Namespace…", systemImage: "folder.badge.plus") { creatingNamespace = true }
                        .disabled(!content.can("Datastore.Modify") || content.namespace.depth >= BackupNamespace.maximumDepth)
                        .accessibilityIdentifier("namespace.create")
                    Button("Verify All…", systemImage: "checkmark.shield") { verifying = true }
                        .disabled(!content.can("Datastore.Verify"))
                    Button("Prune All…", systemImage: "scissors") { pruning = true }
                        .disabled(!content.can("Datastore.Prune") && !content.can("Datastore.Modify"))
                        .accessibilityIdentifier("namespace.prune")
                }
                .accessibilityIdentifier("namespace.actions")
            }
        }
        .refreshable { await content.load() }
        // Also when coming back from a group, which may have changed meanwhile.
        .task { await content.load() }
        .alert("New Namespace", isPresented: $creatingNamespace) {
            NewNamespaceAlert(content: content) { message = ($0, $1) }
        } message: {
            Text("Inside \(content.namespace.isRoot ? String(localized: "the root namespace") : content.namespace.path).")
        }
        .sheet(isPresented: $verifying) {
            NavigationStack {
                VerifyNamespaceView(content: content)
            }
        }
        .sheet(isPresented: $pruning) {
            NavigationStack {
                PruneNamespaceView(content: content)
            }
        }
        .sheet(item: $moving) { namespace in
            NavigationStack {
                MoveNamespaceView(content: content, namespace: namespace)
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { namespace in
            Button("Delete Namespace and Backups", role: .destructive) { delete(namespace, deleteGroups: true) }
            Button("Delete If Empty") { delete(namespace, deleteGroups: false) }
        } message: { _ in
            Text("Deleting the backups also deletes the namespaces below. Protected snapshots stay, and the namespaces holding them too.")
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message?.text ?? "")
        }
    }

    private func delete(_ namespace: BackupNamespace, deleteGroups: Bool) {
        Task {
            do {
                if let result = try await content.deleteNamespace(namespace, deleteGroups: deleteGroups), result.protectedSnapshots > 0 {
                    message = (String(localized: "Partly Deleted"), String(localized: "\(result.protectedSnapshots) protected snapshots were kept, with the namespaces holding them."))
                }
            } catch {
                message = (String(localized: "Cannot Delete the Namespace"), error.localizedDescription)
            }
        }
    }
}

private struct BackupGroupRow: View {
    let group: BackupGroup

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: group.reference.type.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.reference.backupID)
                        .font(.headline)
                    if let comment = group.comment {
                        Text(comment)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    Text("^[\(group.snapshotCount) snapshot](inflect: true)")
                    if let last = group.lastBackup {
                        Text(verbatim: "·")
                        Text(last, format: .relative(presentation: .named))
                    }
                    if let owner = group.owner {
                        Text(verbatim: "·")
                        Text(owner)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NewNamespaceAlert: View {
    let content: DatastoreContent
    let onError: (String, String) -> Void
    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("namespace.name")
        Button("Cancel", role: .cancel) {}
        Button("Create") {
            Task {
                do {
                    try await content.createNamespace(name)
                } catch {
                    onError(String(localized: "Cannot Create the Namespace"), error.localizedDescription)
                }
            }
        }
    }
}

private struct VerifyNamespaceView: View {
    let content: DatastoreContent
    @State private var skipVerified = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle("Skip Verified Snapshots", isOn: $skipVerified)
            } footer: {
                Text("Checks every snapshot in \(content.namespace.isRoot ? content.store : content.namespace.path) and the namespaces below.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Verify All")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Verify", isWorking: isWorking) {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            try await content.verify(skipVerified: skipVerified, reverifyAfterDays: nil)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

/// Prune All of a namespace: the rules apply to every group in it and below, as a task.
private struct PruneNamespaceView: View {
    let content: DatastoreContent
    @State private var retention = RetentionPolicy(last: 3)
    @State private var dryRun = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                KeepRulesFields(retention: $retention)
            } footer: {
                Text("Applies to every backup group in \(content.namespace.isRoot ? content.store : content.namespace.path) and the namespaces below. Protected snapshots are always kept.")
            }
            Section {
                Toggle("Dry Run", isOn: $dryRun)
                    .accessibilityIdentifier("prune.dryRun")
            } footer: {
                Text("A dry run only lists in its task log what would be removed.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Prune All")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton(dryRun ? "Test" : "Prune", isWorking: isWorking) {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            try await content.pruneAll(keep: retention, dryRun: dryRun)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(retention.keepsEverything)
                .accessibilityIdentifier("prune.start")
            }
        }
    }
}

private struct MoveNamespaceView: View {
    let content: DatastoreContent
    let namespace: BackupNamespace
    @State private var target = ""
    @State private var targets: [BackupNamespace] = []
    @State private var mergesGroups = true
    @State private var deletesSource = true
    /// Levels below the namespace that move along; nil for all.
    @State private var maxDepth: Int?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Target Namespace", text: $target, prompt: Text(verbatim: "archive/\(namespace.name)"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !targets.isEmpty {
                    Menu("Existing Namespaces") {
                        ForEach(targets) { candidate in
                            Button(candidate.isRoot ? String(localized: "Root") : candidate.path) { target = candidate.child(namespace.name).path }
                        }
                    }
                }
            } footer: {
                Text("The new path of the namespace, with everything below it.")
            }
            Section {
                Picker("Max Depth", selection: $maxDepth) {
                    Text("Full").tag(Int?.none)
                    ForEach(0..<8) { depth in
                        Text(depth == 0 ? String(localized: "This Namespace Only") : String(localized: "\(depth) Levels")).tag(Int?.some(depth))
                    }
                }
                Toggle("Merge Groups", isOn: $mergesGroups)
                    .accessibilityIdentifier("namespace.move.merge")
                Toggle("Delete Source", isOn: $deletesSource)
                    .accessibilityIdentifier("namespace.move.deleteSource")
            } footer: {
                Text("Merge Groups adds the snapshots to groups that exist at the target already; they need the same owner and different backup times. Delete Source removes the emptied namespace.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Move \(namespace.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Move", isWorking: isWorking) {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            let task = try await content.moveNamespace(namespace, to: BackupNamespace(target.trimmingCharacters(in: .whitespaces)),
                                                                       mergeGroups: mergesGroups, deletesSource: deletesSource, maxDepth: maxDepth)
                            if case .failed(let message) = await content.connection.tasks.result(of: task.id) {
                                errorMessage = message
                                return
                            }
                            await content.load()
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task {
            targets = await content.allNamespaces().filter { !namespace.contains($0) }
        }
    }
}

// MARK: - Group

/// A backup group: its snapshots, notes and actions.
struct BackupGroupView: View {
    @State private var detail: BackupGroupDetail
    @State private var editingNotes = false
    @State private var pruning = false
    @State private var changingOwner = false
    @State private var moving = false
    @State private var confirmsDeletion = false
    @State private var message: (title: String, text: String)?
    @Environment(\.dismiss) private var dismiss

    init(store: String, group: BackupGroup, connection: ServerConnection) {
        _detail = State(initialValue: BackupGroupDetail(store: store, group: group, connection: connection))
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: detail.group.type.systemImage)
                        .font(.title)
                        .foregroundStyle(.tint)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail.group.path)
                            .font(.headline)
                        if let owner = detail.owner {
                            Label(owner, systemImage: "person")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if !detail.group.namespace.isRoot {
                            Label(detail.group.namespace.path, systemImage: "folder")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Notes") {
                Button {
                    editingNotes = true
                } label: {
                    if let notes = detail.notes, !notes.isEmpty {
                        Text(notes)
                            .foregroundStyle(.primary)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Add Notes")
                    }
                }
                .foregroundStyle(detail.notes?.isEmpty == false ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .disabled(!detail.canChangeBackups)
                .accessibilityIdentifier("group.notes")
            }
            if let error = detail.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let snapshots = detail.snapshots {
                Section("Snapshots") {
                    ForEach(snapshots) { snapshot in
                        NavigationLink {
                            SnapshotView(group: detail, snapshot: snapshot)
                        } label: {
                            SnapshotRow(snapshot: snapshot)
                        }
                        .accessibilityIdentifier("snapshot.\(snapshot.reference.time)")
                        .contextMenu {
                            Button("Copy Name", systemImage: "doc.on.doc") { UIPasteboard.general.string = snapshot.reference.name }
                        }
                        .swipeActions(edge: .trailing) {
                            if detail.canChangeBackups {
                                Button("Delete", systemImage: "trash") { run { try await detail.deleteSnapshot(snapshot.reference) } }
                                    .tint(.red)
                                    .disabled(snapshot.isProtected)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if detail.canChangeBackups {
                                Button(snapshot.isProtected ? "Unprotect" : "Protect", systemImage: snapshot.isProtected ? "lock.open" : "lock") {
                                    run { try await detail.setProtected(snapshot.reference, !snapshot.isProtected) }
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(detail.group.path)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if detail.snapshots == nil, detail.loadError == nil { ProgressView() }
        }
        .refreshable { await detail.load() }
        .task { if detail.snapshots == nil { await detail.load() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Actions", systemImage: "ellipsis.circle") {
                    Button("Verify", systemImage: "checkmark.shield") { run { try await detail.verify() } }
                        .disabled(!detail.can("Datastore.Verify") && !detail.canChangeBackups)
                    Button("Prune…", systemImage: "scissors") { pruning = true }
                        .disabled(!detail.can("Datastore.Prune") && !detail.canChangeBackups)
                        .accessibilityIdentifier("group.prune")
                    Button("Change Owner…", systemImage: "person.crop.circle.badge.checkmark") { changingOwner = true }
                        .disabled(!detail.can("Datastore.Modify"))
                    if detail.connection.supports(backupServer: .moveGroupsAndNamespaces) {
                        Button("Move…", systemImage: "arrow.right.doc.on.clipboard") { moving = true }
                            .disabled(!detail.can("Datastore.Modify"))
                    }
                    Button("Delete Group…", systemImage: "trash", role: .destructive) { confirmsDeletion = true }
                        .disabled(!detail.canChangeBackups)
                        .accessibilityIdentifier("group.delete")
                }
                .accessibilityIdentifier("group.actions")
            }
        }
        .sheet(isPresented: $editingNotes) {
            NavigationStack {
                BackupNotesEditor(title: "Group Notes", notes: detail.notes ?? "") { try await detail.setNotes($0) }
            }
        }
        .sheet(isPresented: $pruning) {
            NavigationStack {
                PruneGroupView(detail: detail)
            }
        }
        .sheet(isPresented: $changingOwner) {
            NavigationStack {
                ChangeOwnerView(detail: detail)
            }
        }
        .sheet(isPresented: $moving) {
            NavigationStack {
                MoveGroupView(detail: detail) { dismiss() }
            }
        }
        .confirmationDialog("Delete \(detail.group.path)?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete All Snapshots", role: .destructive) {
                Task {
                    do {
                        let result = try await detail.delete()
                        if let result, result.protectedSnapshots > 0 {
                            message = (String(localized: "Partly Deleted"), String(localized: "\(result.protectedSnapshots) protected snapshots were kept, and the group with them."))
                            await detail.load()
                        } else {
                            dismiss()
                        }
                    } catch {
                        message = (String(localized: "Cannot Delete the Group"), error.localizedDescription)
                    }
                }
            }
        } message: {
            Text("Every snapshot of the group is deleted for good. Protected snapshots stay.")
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message?.text ?? "")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                message = (String(localized: "Action Failed"), error.localizedDescription)
            }
        }
    }
}

private struct SnapshotRow: View {
    let snapshot: BackupSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(snapshot.date, format: .dateTime.day().month(.abbreviated).year().hour().minute().second())
                Spacer()
                if snapshot.isProtected {
                    Image(systemName: "lock.fill").foregroundStyle(.orange).accessibilityLabel("Protected")
                }
                if snapshot.cryptMode == .encrypt {
                    Image(systemName: "key.fill").foregroundStyle(.secondary).accessibilityLabel("Encrypted")
                }
                VerificationBadge(verification: snapshot.verification)
            }
            HStack(spacing: 4) {
                if let size = snapshot.size {
                    Text(Format.bytes(size))
                }
                if let comment = snapshot.comment {
                    Text(verbatim: "·")
                    Text(comment).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct VerificationBadge: View {
    let verification: SnapshotVerification?

    var body: some View {
        switch verification?.succeeded {
        case true?:
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green).accessibilityLabel("Verified")
        case false?:
            Image(systemName: "xmark.shield.fill").foregroundStyle(.red).accessibilityLabel("Verification failed")
        case nil:
            Image(systemName: "shield").foregroundStyle(.secondary).accessibilityLabel("Not verified")
        }
    }
}

/// Notes in a sheet: Markdown text the web interface shows as well.
struct BackupNotesEditor: View {
    let title: LocalizedStringKey
    @State var notes: String
    let save: (String) async throws -> Void
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextEditor(text: $notes)
                    .frame(minHeight: 180)
                    .accessibilityIdentifier("notes.text")
            } footer: {
                Text("The first line shows as the comment in the lists.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Save", isWorking: isSaving) {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        do {
                            try await save(notes)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .accessibilityIdentifier("notes.save")
            }
        }
    }
}

/// Prune of one group with a live preview from the server, like the web interface's prune dialog.
private struct PruneGroupView: View {
    let detail: BackupGroupDetail
    @State private var retention = RetentionPolicy(last: 3)
    @State private var preview: [SnapshotPruneDecision]?
    @State private var previewError: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var removals: Int { preview?.filter { !$0.keep }.count ?? 0 }

    var body: some View {
        Form {
            Section {
                KeepRulesFields(retention: $retention)
            } footer: {
                Text("Snapshots matching none of the rules are removed. Protected snapshots are always kept.")
            }
            Section {
                if let preview {
                    ForEach(preview) { decision in
                        HStack {
                            Text(decision.reference.date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                            Spacer()
                            if decision.isProtected {
                                Image(systemName: "lock.fill").foregroundStyle(.orange)
                            }
                            Text(decision.keep ? "Keep" : "Remove")
                                .fontWeight(.semibold)
                                .foregroundStyle(decision.keep ? .green : .red)
                        }
                        .font(.subheadline)
                        .accessibilityElement(children: .combine)
                    }
                } else if let previewError {
                    Label(previewError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    ProgressView()
                }
            } header: {
                Text("Preview")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Prune \(detail.group.path)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton(removals > 0 ? "Remove \(removals)" : "Prune", isWorking: isWorking) {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            let task = try await detail.prune(keep: retention)
                            _ = await detail.connection.tasks.result(of: task.id)
                            await detail.load()
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(retention.keepsEverything || removals == 0)
                .accessibilityIdentifier("prune.start")
            }
        }
        .task(id: retention) {
            // Let the user finish typing before asking the server.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                preview = try await detail.previewPrune(keep: retention).sorted { $0.reference.time > $1.reference.time }
                previewError = nil
            } catch {
                previewError = error.localizedDescription
            }
        }
    }
}

private struct ChangeOwnerView: View {
    let detail: BackupGroupDetail
    @State private var owner: String
    @State private var users: [BackupServerUser] = []
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(detail: BackupGroupDetail) {
        self.detail = detail
        _owner = State(initialValue: detail.owner ?? "")
    }

    var body: some View {
        Form {
            Section {
                Picker("Owner", selection: $owner) {
                    ForEach(users) { user in
                        ForEach(user.authIDs, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Only the owner (and administrators) may add snapshots to the group or remove them.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Change Owner")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Save", isWorking: isWorking) {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            try await detail.changeOwner(to: owner)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(owner.isEmpty || owner == detail.owner)
            }
        }
        .task { users = (try? await detail.connection.send(PBS.users()).value) ?? [] }
    }
}

private struct MoveGroupView: View {
    let detail: BackupGroupDetail
    let onMoved: () -> Void
    @State private var target: BackupNamespace?
    @State private var merge = true
    @State private var namespaces: [BackupNamespace] = []
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Picker("Namespace", selection: $target) {
                    ForEach(namespaces) { namespace in
                        Text(namespace.isRoot ? String(localized: "Root") : namespace.path).tag(BackupNamespace?.some(namespace))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Toggle("Merge with Existing Group", isOn: $merge)
            } footer: {
                Text("When the namespace already has a group \(detail.group.path), its snapshots are added to it. Otherwise the move fails.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Move \(detail.group.path)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Move", isWorking: isWorking) {
                    guard let target else { return }
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            let task = try await detail.move(to: target, merge: merge)
                            if case .failed(let message) = await detail.connection.tasks.result(of: task.id) {
                                errorMessage = message
                                return
                            }
                            dismiss()
                            onMoved()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(target == nil)
            }
        }
        .task {
            namespaces = ((try? await detail.connection.send(PBS.namespaces(detail.store))) ?? []).filter { $0 != detail.group.namespace }
        }
    }
}

// MARK: - Snapshot

/// One snapshot: details, notes, protection and its files.
private struct SnapshotView: View {
    let group: BackupGroupDetail
    let snapshot: BackupSnapshot
    @State private var detail: SnapshotDetail
    @State private var editingNotes = false
    @State private var confirmsDeletion = false
    @State private var actionError: String?
    @Environment(\.dismiss) private var dismiss

    init(group: BackupGroupDetail, snapshot: BackupSnapshot) {
        self.group = group
        self.snapshot = snapshot
        _detail = State(initialValue: SnapshotDetail(store: group.store, reference: snapshot.reference, connection: group.connection))
    }

    /// The group's copy, which follows changes made here.
    private var current: BackupSnapshot {
        group.snapshots?.first { $0.id == snapshot.id } ?? snapshot
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Time", value: current.date.formatted(date: .long, time: .standard))
                if let size = current.size {
                    LabeledContent("Size", value: Format.bytes(size))
                }
                if let owner = current.owner {
                    LabeledContent("Owner", value: owner)
                }
                LabeledContent("Encryption", value: current.cryptMode == .encrypt ? String(localized: "Encrypted") : current.cryptMode == .signOnly ? String(localized: "Signed") : String(localized: "None"))
                LabeledContent("Verification") {
                    HStack(spacing: 6) {
                        VerificationBadge(verification: current.verification)
                        Text(current.verification.map { $0.succeeded ? String(localized: "Verified") : String(localized: "Failed") } ?? String(localized: "Not Verified"))
                    }
                }
                if let upid = current.verification?.upid, let parsed = UPID(upid) {
                    NavigationLink("Verification Log", value: ServerRoute.task(node: parsed.node, upid: upid))
                }
                Toggle("Protected", isOn: Binding(get: { current.isProtected }, set: { protect in
                    Task {
                        do { try await group.setProtected(current.reference, protect) } catch { actionError = error.localizedDescription }
                    }
                }))
                .disabled(!group.canChangeBackups)
                .accessibilityIdentifier("snapshot.protected")
            }
            Section("Notes") {
                Button {
                    editingNotes = true
                } label: {
                    if let notes = detail.notes, !notes.isEmpty {
                        Text(notes).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                    } else if detail.notes == nil, detail.notesError == nil {
                        ProgressView()
                    } else {
                        Text("Add Notes")
                    }
                }
                .foregroundStyle(detail.notes?.isEmpty == false ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .disabled(!group.canChangeBackups || detail.notes == nil)
                .accessibilityIdentifier("snapshot.notes")
            }
            Section("Files") {
                ForEach(current.files) { file in
                    SnapshotFileRow(detail: detail, file: file)
                }
            }
            Section {
                Button("Verify", systemImage: "checkmark.shield") {
                    Task {
                        do { try await group.verify(current.reference) } catch { actionError = error.localizedDescription }
                    }
                }
                .disabled(!group.can("Datastore.Verify") && !group.canChangeBackups)
                Button("Delete Snapshot…", systemImage: "trash", role: .destructive) { confirmsDeletion = true }
                    .disabled(!group.canChangeBackups || current.isProtected)
                    .accessibilityIdentifier("snapshot.delete")
            } footer: {
                if current.isProtected {
                    Text("Protected snapshots cannot be deleted, also not by prune or garbage collection.")
                }
            }
        }
        .navigationTitle(current.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task { await detail.loadNotes() }
        .sheet(isPresented: $editingNotes) {
            NavigationStack {
                BackupNotesEditor(title: "Snapshot Notes", notes: detail.notes ?? "") { notes in
                    try await detail.setNotes(notes)
                    await group.load()
                }
            }
        }
        .confirmationDialog("Delete this snapshot?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete Snapshot", role: .destructive) {
                Task {
                    do {
                        try await group.deleteSnapshot(current.reference)
                        dismiss()
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            }
        }
        .alert("Action Failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }
}

/// A file of a snapshot: file archives open in the browser, small files show their text, others download.
private struct SnapshotFileRow: View {
    let detail: SnapshotDetail
    let file: SnapshotFile

    var body: some View {
        switch file.kind {
        case .fileArchive where file.cryptMode != .encrypt:
            NavigationLink {
                BackupFilesView(files: SnapshotArchiveFiles(detail: detail, archive: file), title: file.displayName)
            } label: {
                label
            }
            .accessibilityIdentifier("file.\(file.name)")
        case .blob where file.size != nil && file.cryptMode != .encrypt:
            NavigationLink {
                FileTextView(detail: detail, file: file)
            } label: {
                label
            }
            .accessibilityIdentifier("file.\(file.name)")
        default:
            label
        }
    }

    private var label: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                HStack(spacing: 4) {
                    if let size = file.size { Text(Format.bytes(size)) }
                    if file.cryptMode == .encrypt { Text(verbatim: "·"); Text("Encrypted") }
                    if file.cryptMode == .signOnly { Text(verbatim: "·"); Text("Signed") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch file.kind {
        case .fileArchive: "folder"
        case .filePayload: "shippingbox"
        case .diskImage: "internaldrive"
        case .catalog: "list.bullet.rectangle"
        case .blob: "doc.text"
        case .other: "doc"
        }
    }
}

/// The text of a small file of a snapshot, such as the guest configuration or the client log.
private struct FileTextView: View {
    let detail: SnapshotDetail
    let file: SnapshotFile
    @State private var text: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text ?? "")
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(file.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if let errorMessage {
                ContentUnavailableView("Cannot Load the File", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if text == nil {
                ProgressView()
            }
        }
        .task {
            do {
                text = try await detail.text(of: file)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
