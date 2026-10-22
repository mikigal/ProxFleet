import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Scheduled syncs of LDAP and Active Directory realms (`/cluster/jobs/realm-sync`), with Run Now.
struct RealmSyncJobsView: View {
    let access: AccessControl
    @State private var jobs: [RealmSyncJob]?
    @State private var loadError: String?
    @State private var editing: Editing?
    @State private var deleting: RealmSyncJob?
    @State private var started: String?
    @State private var errorMessage: String?

    struct Editing: Identifiable {
        var job: RealmSyncJob?
        var id: String { job?.id ?? "" }
    }

    private var canModify: Bool { access.can("Realm.AllocateUser") }
    private var syncableRealms: [Realm] { (access.realms ?? []).filter { RealmType(rawValue: $0.type)?.canSync == true } }

    var body: some View {
        List {
            if let jobs {
                Section {
                    if jobs.isEmpty {
                        Text("No sync jobs").foregroundStyle(.secondary)
                    }
                    ForEach(jobs) { job in
                        Button {
                            editing = Editing(job: job)
                        } label: {
                            row(job)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("syncjob.\(job.id)")
                        .swipeActions {
                            if canModify {
                                Button("Delete", systemImage: "trash") { deleting = job }
                                    .tint(.red)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if canModify {
                                Button("Run Now", systemImage: "play.fill") { Task { await run(job) } }
                                    .tint(.green)
                            }
                        }
                        .contextMenu {
                            Button("Run Now", systemImage: "play.fill") { Task { await run(job) } }
                                .disabled(!canModify)
                        }
                    }
                } footer: {
                    Text(syncableRealms.isEmpty
                        ? "Add an LDAP or Active Directory realm first."
                        : "Swipe right on a job to run it now. Jobs start from the realm's sync defaults.")
                }
            }
        }
        .overlay {
            if let loadError, jobs == nil {
                ContentUnavailableView("Cannot Load the Sync Jobs", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if jobs == nil {
                ProgressView()
            }
        }
        .navigationTitle("Sync Jobs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { editing = Editing() }
                    .disabled(!canModify || syncableRealms.isEmpty)
                    .accessibilityIdentifier("syncjob.add")
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { editing in
            NavigationStack { RealmSyncJobEditor(access: access, job: editing.job, realms: syncableRealms) }
        }
        .confirmationDialog("Delete the sync job \(deleting?.id ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { job in
            Button("Delete", role: .destructive) { Task { await delete(job) } }
        } message: { _ in
            Text("Users and groups synced so far stay.")
        }
        .alert("Sync Started", isPresented: Binding(get: { started != nil }, set: { if !$0 { started = nil } })) {
            Button("OK") {}
        } message: {
            Text("The sync of \(started ?? "") runs as a task. Failures show up in the task list.")
        }
        .accessError($errorMessage)
    }

    private func row(_ job: RealmSyncJob) -> some View {
        HStack(spacing: 12) {
            Image(systemName: job.isEnabled ? "calendar.badge.clock" : "calendar")
                .font(.title3)
                .foregroundStyle(job.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(job.realm).font(.body.weight(.medium))
                    if !job.isEnabled { AccessBadge(text: "Disabled") }
                }
                Text([job.comment, job.schedule, (job.isEnabled ? job.nextRun : nil).map { String(localized: "next \($0.formatted(.relative(presentation: .named)))") }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            jobs = try await access.realmSyncJobs()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(_ job: RealmSyncJob) async {
        do {
            try await access.deleteRealmSyncJob(job.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func run(_ job: RealmSyncJob) async {
        do {
            _ = try await access.runRealmSyncJob(job)
            started = job.realm
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RealmSyncJobEditor: View {
    let access: AccessControl
    let job: RealmSyncJob?
    let realms: [Realm]
    let original: RealmSyncJobDraft
    @State private var draft: RealmSyncJobDraft
    @State private var nextRuns: Result<[Date], ConfigUpdateError>?
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(access: AccessControl, job: RealmSyncJob?, realms: [Realm]) {
        self.access = access
        self.job = job
        self.realms = realms
        let draft = job.map(RealmSyncJobDraft.init) ?? RealmSyncJobDraft(realm: realms.first?.realm ?? "")
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { job == nil }
    private var canModify: Bool { access.can("Realm.AllocateUser") }

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: isNew) : [:]).merging(fieldErrors) { _, server in server }
    }

    var body: some View {
        Form {
            Group {
                Section {
                    if isNew {
                        Picker("Realm", selection: $draft.realm) {
                            ForEach(realms) { Text($0.realm).tag($0.realm) }
                        }
                        .accessibilityIdentifier("syncjob.realm")
                        FieldError(message: errors["realm"])
                        LabeledTextField(title: "Job ID", prompt: "Automatic", text: $draft.id, identifier: "syncjob.id")
                        FieldError(message: errors["id"])
                    } else {
                        LabeledContent("Realm", value: draft.realm)
                    }
                    Toggle("Enabled", isOn: $draft.isEnabled)
                    LabeledTextField(title: "Comment", prompt: "None", text: $draft.comment, identifier: "syncjob.comment")
                }
                Section {
                    HStack {
                        TextField("Schedule", text: $draft.schedule, prompt: Text("sat 02:00"))
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("syncjob.schedule")
                        Menu {
                            ForEach(BackupJobDraft.schedulePresets, id: \.schedule) { preset in
                                Button(preset.title) { draft.schedule = preset.schedule }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .accessibilityLabel("Schedule Presets")
                    }
                    FieldError(message: errors["schedule"])
                    switch nextRuns {
                    case .success(let dates):
                        ForEach(dates, id: \.self) { date in
                            Label(date.formatted(.dateTime.weekday(.wide).day().month().hour().minute()), systemImage: "clock")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    case .failure(.invalid(_, let fields)):
                        FieldError(message: fields["schedule"] ?? String(localized: "The server cannot read this schedule."))
                    case .failure(let error):
                        FieldError(message: error.localizedDescription)
                    case nil:
                        EmptyView()
                    }
                } header: {
                    Text("Schedule")
                }
                Section {
                    SyncOptionFields(scope: $draft.options.scope, enableNew: $draft.options.enableNew, removeVanished: $draft.options.removeVanished, allowsNoDefault: false)
                    FieldError(message: errors["scope"])
                } header: {
                    Text("Sync Options")
                } footer: {
                    Text("New jobs start from the realm's sync defaults, which are set in the realm's settings.")
                }
            }
            .disabled(!canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? "New Sync Job" : draft.id)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!isNew && draft.changes(from: original).isEmpty)
                        .accessibilityIdentifier("save")
                }
            }
        }
        .task(id: draft.realm) {
            // Like the web interface, a new job takes the realm's sync defaults.
            guard isNew, !draft.realm.isEmpty, let config = try? await access.realmConfig(draft.realm),
                  let realm = RealmDraft(realm: draft.realm, config) else { return }
            draft.options = realm.syncDefaults
            if draft.options.enableNew == nil { draft.options.enableNew = true }
        }
        .task(id: draft.schedule) {
            try? await Task.sleep(for: .milliseconds(400))
            let schedule = draft.schedule.trimmingCharacters(in: .whitespaces)
            guard !Task.isCancelled, !schedule.isEmpty else { return }
            nextRuns = await access.nextRuns(of: schedule)
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
                try await access.createRealmSyncJob(draft)
            } else {
                try await access.updateRealmSyncJob(draft, draft.changes(from: original))
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
