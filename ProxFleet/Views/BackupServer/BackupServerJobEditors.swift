import FleetCore
import PBSKit
import SwiftUI

/// Form scaffold for creating or editing a job: Add or Save, local problems after the first attempt, the server's
/// field errors, a lock when the user may not change it, and Delete for existing jobs.
struct BackupServerJobForm<Content: View>: View {
    let title: String
    let isNew: Bool
    var lockMessage: String?
    let hasChanges: Bool
    /// Read when saving, not when the form was last drawn, so text typed just before tapping Add is checked too.
    let problems: () -> [String: String]
    let submit: () async throws(ConfigUpdateError) -> Void
    var delete: (() async throws(ConfigUpdateError) -> Void)?
    @ViewBuilder let content: (_ errors: [String: String]) -> Content

    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var confirmsDeletion = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    private var errors: [String: String] {
        (showsProblems ? problems() : [:]).merging(fieldErrors) { _, server in server }
    }

    var body: some View {
        Form {
            if let lockMessage {
                Section {
                    Label {
                        Text(lockMessage)
                    } icon: {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            Group {
                content(errors)
            }
            .disabled(lockMessage != nil)
            ErrorSection(message: errorMessage)
            if delete != nil, lockMessage == nil {
                Section {
                    Button("Delete Job", role: .destructive) { confirmsDeletion = true }
                        .accessibilityIdentifier("job.delete")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if lockMessage == nil {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!isNew && !hasChanges)
                        .accessibilityIdentifier("save")
                }
            }
        }
        .confirmationDialog("Delete this job?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete Job", role: .destructive) { Task { await remove() } }
        } message: {
            Text("The job stops running. Backups it made stay.")
        }
    }

    private func save() async {
        showsProblems = true
        fieldErrors = [:]
        guard problems().isEmpty else {
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await submit()
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() async {
        guard let delete else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await delete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A picker over a datastore's namespaces, with the root first.
struct BackupNamespacePicker: View {
    let title: LocalizedStringKey
    @Binding var path: String
    let namespaces: [BackupNamespace]
    var identifier: String?

    var body: some View {
        Picker(title, selection: $path) {
            Text("Root").tag("")
            ForEach(namespaces.filter { !$0.isRoot }) { Text($0.path).tag($0.path) }
            if !path.isEmpty, !namespaces.contains(BackupNamespace(path)) { Text(path).tag(path) }
        }
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// How many namespace levels below a job's namespace it includes.
struct MaxDepthPicker: View {
    @Binding var maxDepth: Int?
    /// Levels the namespace still has below it.
    var levelsBelow = BackupNamespace.maximumDepth

    var body: some View {
        Picker("Max. Depth", selection: $maxDepth) {
            Text("All Levels").tag(Int?.none)
            Text("This Namespace Only").tag(Int?.some(0))
            ForEach(Array(1...max(1, levelsBelow)), id: \.self) { level in
                Text(String(AttributedString(localized: "^[\(level) level](inflect: true) below").characters)).tag(Int?.some(level))
            }
        }
    }
}

/// A picker of the server's datastores, keeping a value that is no longer listed.
struct DatastorePicker: View {
    let title: LocalizedStringKey
    @Binding var store: String
    let stores: [String]
    var identifier: String?

    var body: some View {
        Picker(title, selection: $store) {
            if store.isEmpty { Text("Choose").tag("") }
            ForEach(stores, id: \.self) { Text($0).tag($0) }
            if !store.isEmpty, !stores.contains(store) { Text(store).tag(store) }
        }
        .accessibilityIdentifier(identifier ?? "")
    }
}

// MARK: - Sync jobs

struct SyncJobEditor: View {
    let jobs: BackupServerJobs
    let job: SyncJob?
    private let original: SyncJobDraft
    @State private var draft: SyncJobDraft
    @State private var remotes: [BackupRemote]?
    @State private var owners: [String] = []
    @State private var localNamespaces: [BackupNamespace] = []
    @State private var otherStores: [String] = []
    @State private var otherNamespaces: [BackupNamespace] = []
    @State private var groups: [BackupGroup] = []
    @State private var keys: [EncryptionKeyEntry] = []
    @State private var scanError: String?

    init(jobs: BackupServerJobs, job: SyncJob) {
        self.jobs = jobs
        self.job = job
        original = SyncJobDraft(job)
        _draft = State(initialValue: original)
    }

    init(jobs: BackupServerJobs, direction: SyncDirection) {
        self.jobs = jobs
        job = nil
        var draft = SyncJobDraft(direction: direction, store: jobs.stores.first ?? "", owner: jobs.connection.profile.userID)
        draft.schedule = "hourly"
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { job == nil }
    private var isPush: Bool { draft.direction == .push }
    private var connection: ServerConnection { jobs.connection }
    private func supports(_ feature: PBSFeature) -> Bool { connection.supports(backupServer: feature) }

    /// The remote the other side is on, nil for a local pull.
    private var otherRemote: String? { draft.pullsLocally ? nil : (draft.remote.isEmpty ? nil : draft.remote) }

    private var title: String {
        if let job { return job.comment ?? job.id }
        return isPush ? String(localized: "New Push Job") : String(localized: "New Pull Job")
    }

    var body: some View {
        BackupServerJobForm(title: title, isNew: isNew, lockMessage: jobs.lockReason(.sync, store: draft.store, direction: draft.direction),
                            hasChanges: !draft.changes(from: original).isEmpty, problems: { draft.problems(isNew: isNew) },
                            submit: save, delete: deleteAction, content: formContent)
            .task { await loadChoices() }
            .task(id: draft.store) {
                localNamespaces = (try? await jobs.namespaces(remote: nil, store: draft.store)) ?? []
            }
            .task(id: "\(draft.pullsLocally)|\(draft.remote)") { await scanOtherStores() }
            .task(id: "\(draft.pullsLocally)|\(draft.remote)|\(draft.remoteStore)") {
                otherNamespaces = []
                guard !draft.remoteStore.isEmpty, draft.pullsLocally || !draft.remote.isEmpty else { return }
                otherNamespaces = (try? await jobs.namespaces(remote: otherRemote, store: draft.remoteStore)) ?? []
            }
            .task(id: groupSource) {
                groups = []
                let source = groupSource
                guard !source.store.isEmpty else { return }
                groups = (try? await jobs.groups(remote: source.remote, store: source.store, namespace: BackupNamespace(source.namespace))) ?? []
            }
    }

    private var deleteAction: (() async throws(ConfigUpdateError) -> Void)? {
        guard !isNew else { return nil }
        return { () async throws(ConfigUpdateError) in try await remove() }
    }

    @ViewBuilder
    private func formContent(_ errors: [String: String]) -> some View {
        localSection(errors)
        otherSection(errors)
        Section {
            CalendarEventField(title: "Schedule", schedule: $draft.schedule, identifier: "syncjob.schedule", error: errors["schedule"])
        } footer: {
            Text("Empty runs the job only by hand.")
        }
        optionsSection(errors)
        GroupFilterSection(filters: $draft.groupFilters, groups: groups, allowsExclude: supports(.excludeGroupFilters), error: errors["group-filter"])
        if supports(.syncEncryption) {
            encryptionSection(errors)
        }
        if let job {
            // The list's copy, which reloads after Run Now.
            JobLastRunSection(connection: jobs.connection, state: jobs.syncJobs?.first { $0.id == job.id }?.state ?? job.state,
                              canRun: jobs.canChange(.sync, store: job.store, direction: job.direction), run: runNow)
        }
    }

    private func runNow() async throws(ConfigUpdateError) {
        if let job { _ = try await jobs.run(.sync, id: job.id) }
    }

    private func loadChoices() async {
        async let remotes = jobs.remotes()
        async let owners = jobs.owners()
        async let keys = jobs.encryptionKeys()
        self.remotes = await remotes
        self.owners = await owners
        self.keys = await keys
        // Without remotes, a new pull job can only pull from another local datastore.
        if isNew, !isPush, self.remotes?.isEmpty == true { draft.isLocal = true }
        if isNew, !draft.pullsLocally, draft.remote.isEmpty, let first = self.remotes?.first { draft.remote = first.name }
    }

    private func scanOtherStores() async {
        otherStores = []
        scanError = nil
        guard draft.pullsLocally || !draft.remote.isEmpty else { return }
        do {
            otherStores = try await jobs.datastores(remote: otherRemote)
            if isNew, draft.remoteStore.isEmpty || !otherStores.contains(draft.remoteStore) {
                // A local pull cannot use the datastore it pulls into.
                draft.remoteStore = otherStores.first { !draft.pullsLocally || $0 != draft.store } ?? ""
            }
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func save() async throws(ConfigUpdateError) {
        if let job {
            try await jobs.update(.sync, id: job.id, draft.changes(from: original))
        } else {
            try await jobs.create(draft)
        }
    }

    private func remove() async throws(ConfigUpdateError) {
        if let job { try await jobs.delete(.sync, id: job.id) }
    }

    /// Where the synced groups come from, for offering them as filters.
    private var groupSource: GroupSource {
        isPush ? GroupSource(remote: nil, store: draft.store, namespace: draft.namespace)
            : GroupSource(remote: otherRemote, store: draft.remoteStore, namespace: draft.remoteNamespace)
    }

    private struct GroupSource: Hashable {
        let remote: String?
        let store: String
        let namespace: String
    }

    @ViewBuilder
    private func localSection(_ errors: [String: String]) -> some View {
        Section {
            if isNew {
                LabeledTextField(title: "Job ID", prompt: "Automatic", text: $draft.id, identifier: "syncjob.id")
                FieldError(message: errors["id"])
            }
            DatastorePicker(title: "Local Datastore", store: $draft.store, stores: jobs.stores, identifier: "syncjob.store")
            FieldError(message: errors["store"])
            BackupNamespacePicker(title: "Local Namespace", path: $draft.namespace, namespaces: localNamespaces, identifier: "syncjob.ns")
            FieldError(message: errors["ns"])
            Picker(isPush ? "Local User" : "Local Owner", selection: $draft.owner) {
                ForEach(owners, id: \.self) { Text($0).tag($0) }
                if !owners.contains(draft.owner) { Text(draft.owner.isEmpty ? connection.profile.userID : draft.owner).tag(draft.owner) }
            }
            FieldError(message: errors["owner"])
            LabeledContent("Comment") {
                TextField("Comment", text: $draft.comment, prompt: Text("None"))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("syncjob.comment")
            }
        } header: {
            Text(isPush ? "Source" : "Target")
        } footer: {
            Text(isPush ? "The groups of the local user are pushed." : "Synced groups belong to the local owner.")
        }
    }

    @ViewBuilder
    private func otherSection(_ errors: [String: String]) -> some View {
        Section {
            if !isPush {
                Picker("Location", selection: $draft.isLocal) {
                    Text("Remote").tag(false)
                    Text("Local").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("syncjob.location")
            }
            if !draft.pullsLocally {
                Picker(isPush ? "Target Remote" : "Source Remote", selection: $draft.remote) {
                    if draft.remote.isEmpty { Text("Choose").tag("") }
                    ForEach(remotes ?? []) { Text($0.name).tag($0.name) }
                    if !draft.remote.isEmpty, remotes?.contains(where: { $0.name == draft.remote }) == false { Text(draft.remote).tag(draft.remote) }
                }
                .accessibilityIdentifier("syncjob.remote")
                if remotes?.isEmpty == true {
                    Text("Add a remote under More → Remotes first.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                FieldError(message: errors["remote"])
            }
            DatastorePicker(title: isPush ? "Target Datastore" : "Source Datastore", store: $draft.remoteStore, stores: otherStores, identifier: "syncjob.remoteStore")
            FieldError(message: errors["remote-store"] ?? scanError)
            BackupNamespacePicker(title: isPush ? "Target Namespace" : "Source Namespace", path: $draft.remoteNamespace, namespaces: otherNamespaces,
                                  identifier: "syncjob.remoteNs")
            FieldError(message: errors["remote-ns"])
            MaxDepthPicker(maxDepth: $draft.maxDepth, levelsBelow: BackupNamespace.maximumDepth - BackupNamespace(isPush ? draft.namespace : draft.remoteNamespace).depth)
            FieldError(message: errors["max-depth"])
        } header: {
            Text(isPush ? "Target" : "Source")
        }
    }

    @ViewBuilder
    private func optionsSection(_ errors: [String: String]) -> some View {
        Section {
            Toggle("Remove Vanished", isOn: $draft.removeVanished)
                .accessibilityIdentifier("syncjob.removeVanished")
            OptionalNumberField(title: "Transfer Last", placeholder: "All", value: $draft.transferLast)
            FieldError(message: errors["transfer-last"])
            if !draft.pullsLocally {
                ByteRateField(title: "Rate Limit", rate: $draft.rateLimit)
                FieldError(message: errors[isPush ? "rate-out" : "rate-in"])
            }
            if supports(.syncWorkerThreads) {
                OptionalNumberField(title: "Worker Threads", placeholder: "1", value: $draft.workerThreads)
                FieldError(message: errors["worker-threads"])
            }
            if !isPush, supports(.resyncCorrupt) {
                Toggle("Re-sync Corrupt", isOn: $draft.resyncCorrupt)
            }
            if supports(.encryptedAndVerifiedOnlySync) {
                Toggle("Encrypted Only", isOn: $draft.encryptedOnly)
                Toggle("Verified Only", isOn: $draft.verifiedOnly)
            }
            if supports(.syncOnMount) {
                Toggle("Run on Mount", isOn: $draft.runOnMount)
                if supports(.unmountAfterSync) {
                    Toggle("Unmount When Done", isOn: $draft.unmountOnDone)
                        .disabled(!draft.runOnMount)
                }
            }
        } header: {
            Text("Options")
        } footer: {
            Text(optionsFooter)
        }
        .onChange(of: draft.runOnMount) { if !draft.runOnMount { draft.unmountOnDone = false } }
    }

    private var optionsFooter: String {
        var parts = [isPush
            ? String(localized: "Remove Vanished deletes snapshots on the target that are gone here. Transfer Last pushes only the newest snapshots of each group.")
            : String(localized: "Remove Vanished deletes local snapshots that are gone on the source. Transfer Last pulls only the newest snapshots of each group.")]
        if !isPush, supports(.resyncCorrupt) {
            parts.append(String(localized: "Re-sync Corrupt pulls snapshots again whose verification failed here."))
        }
        if supports(.syncOnMount) {
            parts.append(String(localized: "Run on Mount starts the job when a removable datastore it uses is mounted."))
        }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private func encryptionSection(_ errors: [String: String]) -> some View {
        Section {
            if isPush {
                Picker("Encryption Key", selection: $draft.activeEncryptionKey) {
                    Text("None").tag("")
                    ForEach(keys.filter { !$0.isArchived }) { Text($0.id).tag($0.id) }
                    if !draft.activeEncryptionKey.isEmpty, !keys.contains(where: { $0.id == draft.activeEncryptionKey }) {
                        Text(draft.activeEncryptionKey).tag(draft.activeEncryptionKey)
                    }
                }
                FieldError(message: errors["active-encryption-key"])
            }
            ForEach(Array(Set(keys.map(\.id) + draft.associatedKeys)).sorted(), id: \.self) { key in
                Toggle(isOn: Binding(get: { draft.associatedKeys.contains(key) }, set: { on in
                    if on { draft.associatedKeys.append(key) } else { draft.associatedKeys.removeAll { $0 == key } }
                })) {
                    VStack(alignment: .leading) {
                        Text(key)
                        if keys.first(where: { $0.id == key })?.isArchived == true {
                            Text("Archived").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isPush && key == draft.activeEncryptionKey)
            }
            if keys.isEmpty, draft.associatedKeys.isEmpty {
                Text("No encryption keys. Add them under More → Encryption Keys.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            FieldError(message: errors["associated-key"])
        } header: {
            Text("Encryption")
        } footer: {
            Text(isPush
                ? "Snapshots are encrypted with the key while they are pushed. Associated keys are the ones used before, kept so the job knows those snapshots."
                : "Associated keys decrypt encrypted snapshots while they are pulled.")
        }
    }
}

/// A rate per second with its unit, empty for no limit.
struct ByteRateField: View {
    let title: LocalizedStringKey
    @Binding var rate: ByteRate

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $rate.amount, prompt: Text("Unlimited"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("rate.amount")
                Picker(title, selection: $rate.unit) {
                    ForEach(ByteRate.Unit.allCases) { Text("\($0.rawValue)/s").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// The group filters of a sync job: which groups to include or exclude.
struct GroupFilterSection: View {
    @Binding var filters: [GroupFilter]
    let groups: [BackupGroup]
    let allowsExclude: Bool
    var error: String?

    var body: some View {
        Section {
            // By position: an ID from the filter's text would change with every typed character and end the editing.
            ForEach(filters.indices, id: \.self) { index in
                GroupFilterRow(filter: $filters[index], groups: groups, allowsExclude: allowsExclude)
            }
            .onDelete { filters.remove(atOffsets: $0) }
            Menu {
                Button("Type") { filters.append(GroupFilter(kind: .type, value: "vm")) }
                    .accessibilityIdentifier("groupfilter.add.type")
                Button("Group") { filters.append(GroupFilter(kind: .group, value: groups.first?.reference.path ?? "")) }
                    .accessibilityIdentifier("groupfilter.add.group")
                Button("Regular Expression") { filters.append(GroupFilter(kind: .regex, value: "")) }
                    .accessibilityIdentifier("groupfilter.add.regex")
            } label: {
                // The whole row opens the menu, not only its text.
                Label("Add Filter", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("groupfilter.add")
            FieldError(message: error)
        } header: {
            Text("Group Filters")
        } footer: {
            Text(allowsExclude
                ? "Without filters every group is synced. Include filters choose groups, exclude filters then leave groups out."
                : "Without filters every group is synced; with filters only the matching groups.")
        }
    }
}

private struct GroupFilterRow: View {
    @Binding var filter: GroupFilter
    let groups: [BackupGroup]
    let allowsExclude: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Filter", selection: $filter.kind) {
                    Text("Type").tag(GroupFilter.Kind.type)
                    Text("Group").tag(GroupFilter.Kind.group)
                    Text("Regex").tag(GroupFilter.Kind.regex)
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: filter.kind) { _, kind in
                    switch kind {
                    case .type: filter.value = "vm"
                    case .group: filter.value = groups.first?.reference.path ?? ""
                    case .regex: filter.value = ""
                    }
                }
                Spacer()
                if allowsExclude {
                    Picker("Mode", selection: $filter.excludes) {
                        Text("Include").tag(false)
                        Text("Exclude").tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            switch filter.kind {
            case .type:
                Picker("Type", selection: $filter.value) {
                    Text("Virtual Machines").tag("vm")
                    Text("Containers").tag("ct")
                    Text("Hosts").tag("host")
                }
                .pickerStyle(.segmented)
            case .group:
                HStack {
                    TextField("vm/100", text: $filter.value)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("groupfilter.value")
                    if !groups.isEmpty {
                        Menu {
                            ForEach(groups) { group in
                                Button(group.comment.map { "\(group.reference.path) · \($0)" } ?? group.reference.path) { filter.value = group.reference.path }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .accessibilityLabel("Groups")
                    }
                }
            case .regex:
                TextField("^vm/1\\d\\d$", text: $filter.value)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("groupfilter.value")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Verification jobs

struct VerifyJobEditor: View {
    let jobs: BackupServerJobs
    let job: VerifyJob?
    private let original: VerifyJobDraft
    @State private var draft: VerifyJobDraft
    @State private var namespaces: [BackupNamespace] = []

    init(jobs: BackupServerJobs, job: VerifyJob?) {
        self.jobs = jobs
        self.job = job
        original = job.map(VerifyJobDraft.init) ?? VerifyJobDraft(store: jobs.stores.first ?? "")
        _draft = State(initialValue: original)
    }

    var body: some View {
        BackupServerJobForm(title: job.map { $0.comment ?? $0.id } ?? String(localized: "New Verification Job"), isNew: job == nil,
                            lockMessage: jobs.lockReason(.verify, store: draft.store),
                            hasChanges: !draft.changes(from: original).isEmpty, problems: { draft.problems(isNew: job == nil) },
                            submit: save, delete: deleteAction, content: formContent)
            .task(id: draft.store) {
                namespaces = (try? await jobs.namespaces(remote: nil, store: draft.store)) ?? []
            }
    }

    private var deleteAction: (() async throws(ConfigUpdateError) -> Void)? {
        guard job != nil else { return nil }
        return { () async throws(ConfigUpdateError) in try await remove() }
    }

    @ViewBuilder
    private func formContent(_ errors: [String: String]) -> some View {
        Section {
            if job == nil {
                LabeledTextField(title: "Job ID", prompt: "Automatic", text: $draft.id, identifier: "verifyjob.id")
                FieldError(message: errors["id"])
            }
            DatastorePicker(title: "Datastore", store: $draft.store, stores: jobs.stores, identifier: "verifyjob.store")
            FieldError(message: errors["store"])
            BackupNamespacePicker(title: "Namespace", path: $draft.namespace, namespaces: namespaces)
            MaxDepthPicker(maxDepth: $draft.maxDepth, levelsBelow: BackupNamespace.maximumDepth - BackupNamespace(draft.namespace).depth)
            LabeledContent("Comment") {
                TextField("Comment", text: $draft.comment, prompt: Text("None"))
                    .multilineTextAlignment(.trailing)
            }
        }
        Section {
            CalendarEventField(title: "Schedule", schedule: $draft.schedule, identifier: "verifyjob.schedule", error: errors["schedule"])
        } footer: {
            Text("Empty runs the job only by hand.")
        }
        Section {
            Toggle("Skip Verified", isOn: $draft.skipVerified)
                .accessibilityIdentifier("verifyjob.skipVerified")
            if draft.skipVerified {
                OptionalNumberField(title: "Re-Verify After (Days)", placeholder: "Never", value: $draft.reverifyAfterDays)
                FieldError(message: errors["outdated-after"])
            }
            if jobs.connection.supports(backupServer: .verificationThreads) {
                OptionalNumberField(title: "Read Threads", placeholder: "1", value: $draft.readThreads)
                FieldError(message: errors["read-threads"])
                OptionalNumberField(title: "Verify Threads", placeholder: "4", value: $draft.verifyThreads)
                FieldError(message: errors["verify-threads"])
            }
        } header: {
            Text("Options")
        } footer: {
            Text("Skipping verified snapshots checks only new ones, and those verified longer ago than the days set.")
        }
        if let job {
            JobLastRunSection(connection: jobs.connection, state: jobs.verifyJobs?.first { $0.id == job.id }?.state ?? job.state,
                              canRun: jobs.canChange(.verify, store: job.store), run: runNow)
        }
    }

    private func runNow() async throws(ConfigUpdateError) {
        if let job { _ = try await jobs.run(.verify, id: job.id) }
    }

    private func save() async throws(ConfigUpdateError) {
        if let job {
            try await jobs.update(.verify, id: job.id, draft.changes(from: original))
        } else {
            try await jobs.create(draft)
        }
    }

    private func remove() async throws(ConfigUpdateError) {
        if let job { try await jobs.delete(.verify, id: job.id) }
    }
}

// MARK: - Prune jobs

struct PruneJobEditor: View {
    let jobs: BackupServerJobs
    let job: PruneJob?
    private let original: PruneJobDraft
    @State private var draft: PruneJobDraft
    @State private var namespaces: [BackupNamespace] = []

    init(jobs: BackupServerJobs, job: PruneJob?) {
        self.jobs = jobs
        self.job = job
        original = job.map(PruneJobDraft.init) ?? PruneJobDraft(store: jobs.stores.first ?? "")
        _draft = State(initialValue: original)
    }

    var body: some View {
        BackupServerJobForm(title: job.map { $0.comment ?? $0.id } ?? String(localized: "New Prune Job"), isNew: job == nil,
                            lockMessage: jobs.lockReason(.prune, store: draft.store),
                            hasChanges: !draft.changes(from: original).isEmpty, problems: { draft.problems(isNew: job == nil) },
                            submit: save, delete: deleteAction, content: formContent)
            .task(id: draft.store) {
                namespaces = (try? await jobs.namespaces(remote: nil, store: draft.store)) ?? []
            }
    }

    private var deleteAction: (() async throws(ConfigUpdateError) -> Void)? {
        guard job != nil else { return nil }
        return { () async throws(ConfigUpdateError) in try await remove() }
    }

    @ViewBuilder
    private func formContent(_ errors: [String: String]) -> some View {
        Section {
            if job == nil {
                LabeledTextField(title: "Job ID", prompt: "Automatic", text: $draft.id, identifier: "prunejob.id")
                FieldError(message: errors["id"])
            }
            Toggle("Enabled", isOn: $draft.isEnabled)
            DatastorePicker(title: "Datastore", store: $draft.store, stores: jobs.stores, identifier: "prunejob.store")
            FieldError(message: errors["store"])
            BackupNamespacePicker(title: "Namespace", path: $draft.namespace, namespaces: namespaces)
            MaxDepthPicker(maxDepth: $draft.maxDepth, levelsBelow: BackupNamespace.maximumDepth - BackupNamespace(draft.namespace).depth)
            LabeledContent("Comment") {
                TextField("Comment", text: $draft.comment, prompt: Text("None"))
                    .multilineTextAlignment(.trailing)
            }
        }
        Section {
            CalendarEventField(title: "Schedule", schedule: $draft.schedule, prompt: "Required", identifier: "prunejob.schedule", error: errors["schedule"])
        }
        Section {
            KeepRulesFields(retention: $draft.retention, errors: errors)
        } header: {
            Text("Keep")
        } footer: {
            Text("Each group keeps the snapshots the rules select; the rest are removed. Protected snapshots always stay.")
        }
        if let job {
            JobLastRunSection(connection: jobs.connection, state: jobs.pruneJobs?.first { $0.id == job.id }?.state ?? job.state,
                              canRun: jobs.canChange(.prune, store: job.store), run: runNow)
        }
    }

    private func runNow() async throws(ConfigUpdateError) {
        if let job { _ = try await jobs.run(.prune, id: job.id) }
    }

    private func save() async throws(ConfigUpdateError) {
        if let job {
            try await jobs.update(.prune, id: job.id, draft.changes(from: original))
        } else {
            try await jobs.create(draft)
        }
    }

    private func remove() async throws(ConfigUpdateError) {
        if let job { try await jobs.delete(.prune, id: job.id) }
    }
}
