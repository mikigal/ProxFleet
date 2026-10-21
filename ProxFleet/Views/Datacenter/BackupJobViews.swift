import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Scheduled backup jobs of the datacenter, with Run Now and the guests no job covers.
struct BackupJobsView: View {
    @State private var list: BackupJobList
    @State private var creating = false
    @State private var running: BackupJob?
    @State private var removing: BackupJob?
    @State private var startedMessage: String?
    @State private var errorMessage: String?

    init(connection: ServerConnection) {
        _list = State(initialValue: BackupJobList(connection: connection))
    }

    var body: some View {
        List {
            if let jobs = list.jobs {
                Section {
                    if jobs.isEmpty {
                        Text("No backup jobs")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(jobs) { job in
                        NavigationLink {
                            BackupJobEditor(list: list, job: job)
                        } label: {
                            BackupJobRow(job: job, guestNames: guestNames)
                        }
                        .accessibilityIdentifier("backupjob.\(job.comment ?? job.id)")
                        .swipeActions {
                            if list.canModify {
                                // Not `role: .destructive`: a full swipe would hide the row, but this only asks first.
                                Button("Remove", systemImage: "trash") { removing = job }
                                    .tint(.red)
                            }
                            Button("Run Now", systemImage: "play.fill") { running = job }
                                .tint(.blue)
                        }
                        .contextMenu {
                            Button("Run Now", systemImage: "play.fill") { running = job }
                            if list.canModify {
                                Button("Remove", systemImage: "trash", role: .destructive) { removing = job }
                            }
                        }
                    }
                } footer: {
                    Text("Jobs run on every node that has the selected guests, at the times of their schedule.")
                }
            }
            if let guests = list.unprotectedGuests, !guests.isEmpty {
                Section {
                    ForEach(guests) { guest in
                        Label {
                            Text([String(guest.vmid), guest.name].compactMap { $0 }.joined(separator: " · "))
                        } icon: {
                            Image(systemName: guest.type == "lxc" ? "shippingbox" : "desktopcomputer")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Not Backed Up")
                } footer: {
                    Text("No enabled job covers these guests.")
                }
            }
        }
        .overlay {
            if let error = list.loadError, list.jobs == nil {
                ContentUnavailableView("Cannot Load Backup Jobs", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if list.jobs == nil {
                ProgressView()
            }
        }
        .navigationTitle("Backup Jobs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!list.canModify)
                    .accessibilityIdentifier("backupjob.add")
            }
        }
        .refreshable { await list.load() }
        .task { await list.load() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                BackupJobEditor(list: list, job: nil)
            }
        }
        .alert("Run Backup Job Now?", isPresented: Binding(get: { running != nil }, set: { if !$0 { running = nil } }), presenting: running) { job in
            Button("Cancel", role: .cancel) {}
            Button("Run Now") { Task { await run(job) } }
                .accessibilityIdentifier("backupjob.run.confirm")
        } message: { job in
            Text("Backs up \(BackupJobRow.selectionSummary(job.selection, guestNames: guestNames)) to \(job.storage ?? "the default storage") now, with the job's settings.")
        }
        .confirmationDialog("Remove this backup job?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { job in
            Button("Remove", role: .destructive) { Task { await remove(job) } }
        } message: { _ in
            Text("Existing backups stay on their storage.")
        }
        .alert("Backup Started", isPresented: Binding(get: { startedMessage != nil }, set: { if !$0 { startedMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(startedMessage ?? "")
        }
        .alert("Backup Job Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var guestNames: [Int: String] {
        Dictionary((list.connection.snapshot?.guests ?? []).map { ($0.vmid, $0.name) }) { first, _ in first }
    }

    private func run(_ job: BackupJob) async {
        do {
            let tasks = try await list.runNow(job)
            startedMessage = tasks.isEmpty
                ? String(localized: "No online node has guests of this job.")
                // String(localized:) leaves inflection markup as it is; AttributedString applies it.
                : String(AttributedString(localized: "^[\(tasks.count) backup task](inflect: true) started. Follow them in the task list.").characters)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ job: BackupJob) async {
        do {
            try await list.delete(job.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BackupJobRow: View {
    let job: BackupJob
    let guestNames: [Int: String]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(job.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(job.comment ?? Self.scheduleTitle(job.schedule))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if !job.isEnabled {
                        Text("Disabled")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: .capsule)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(Self.selectionSummary(job.selection, guestNames: guestNames)) → \(job.storage ?? "–")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(timing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Disabled jobs still report a next run, which is not shown for them.
    private var timing: String {
        guard job.isEnabled, let next = job.nextRun else { return job.schedule }
        return String(localized: "\(job.schedule) · next \(next.formatted(.relative(presentation: .named)))")
    }

    static func scheduleTitle(_ schedule: String) -> String {
        BackupJobDraft.schedulePresets.first { $0.schedule == schedule }?.title ?? schedule
    }

    static func selectionSummary(_ selection: BackupSelection, guestNames: [Int: String]) -> String {
        switch selection {
        case .all(let excluding) where excluding.isEmpty:
            return String(localized: "All guests")
        case .all(let excluding):
            return String(localized: "All guests except \(excluding.map(String.init).joined(separator: ", "))")
        case .pool(let pool):
            return String(localized: "Pool \(pool)")
        case .guests(let vmids) where vmids.count <= 3:
            return vmids.map { guestNames[$0].map { name in "\(name)" } ?? String($0) }.joined(separator: ", ")
        case .guests(let vmids):
            return String(AttributedString(localized: "^[\(vmids.count) guest](inflect: true)").characters)
        }
    }
}

// MARK: - Editor

struct BackupJobEditor: View {
    let list: BackupJobList
    let job: BackupJob?
    let original: BackupJobDraft
    @State private var draft: BackupJobDraft
    @State private var nextRuns: Result<[Date], ConfigUpdateError>?
    @State private var pools: [ResourcePool] = []
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(list: BackupJobList, job: BackupJob?) {
        self.list = list
        self.job = job
        var draft = job.map(BackupJobDraft.init) ?? BackupJobDraft()
        if job == nil {
            // The first storage that holds backups, as the web interface preselects.
            draft.storage = Self.backupStorages(list.connection.snapshot).first ?? ""
        }
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { job == nil }
    private var snapshot: ClusterSnapshot? { list.connection.snapshot }

    private var errors: [String: String] {
        (showsProblems ? draft.problems : [:]).merging(fieldErrors) { _, server in server }
    }

    private static func backupStorages(_ snapshot: ClusterSnapshot?) -> [String] {
        Array(Set((snapshot?.storages ?? []).filter { $0.content.contains("backup") }.map(\.name))).sorted()
    }

    var body: some View {
        Form {
            if !list.canModify {
                Section {
                    Label("Read only. Changing backup jobs needs the Sys.Modify privilege on /.", systemImage: "lock.fill")
                        .font(.subheadline)
                }
            }
            Group {
                generalSection
                scheduleSection
                selectionSection
                optionsSection
                retentionSection
            }
            .disabled(!list.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? "New Backup Job" : (job?.comment ?? "Backup Job"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if list.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!isNew && draft.changes(from: original).isEmpty)
                        .accessibilityIdentifier("save")
                }
            }
        }
        .task(id: draft.schedule) {
            // Waits until typing pauses before asking the server.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, !draft.schedule.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            nextRuns = await list.nextRuns(of: draft.schedule.trimmingCharacters(in: .whitespaces))
        }
        .task { pools = await list.connection.load(PVE.pools()) }
    }

    private var generalSection: some View {
        Section {
            Toggle("Enabled", isOn: $draft.isEnabled)
            Picker("Storage", selection: $draft.storage) {
                if draft.storage.isEmpty { Text("Choose").tag("") }
                ForEach(Self.backupStorages(snapshot), id: \.self) { Text($0).tag($0) }
                if !draft.storage.isEmpty, !Self.backupStorages(snapshot).contains(draft.storage) { Text(draft.storage).tag(draft.storage) }
            }
            .accessibilityIdentifier("backupjob.storage")
            FieldError(message: errors["storage"])
            if let nodes = snapshot?.nodes, nodes.count > 1 {
                Picker("Node", selection: $draft.node) {
                    Text("All Nodes").tag("")
                    ForEach(nodes) { Text($0.name).tag($0.name) }
                }
            }
            LabeledContent("Comment") {
                TextField("Comment", text: $draft.comment, prompt: Text("None"))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("backupjob.comment")
            }
        }
    }

    private var scheduleSection: some View {
        Section {
            HStack {
                TextField("Schedule", text: $draft.schedule, prompt: Text("sat 02:00"))
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("backupjob.schedule")
                Menu {
                    ForEach(BackupJobDraft.schedulePresets, id: \.schedule) { preset in
                        Button(preset.title) { draft.schedule = preset.schedule }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("Schedule Presets")
                .accessibilityIdentifier("backupjob.presets")
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
        } footer: {
            Text("Calendar events like the web interface's: a time (21:00), weekdays (mon..fri 21:00), or repeats (*/6:00). The next runs are shown below the field.")
        }
    }

    @ViewBuilder
    private var selectionSection: some View {
        Section {
            Picker("Guests", selection: $draft.selectionMode) {
                Text("All").tag(BackupJobDraft.Mode.all)
                Text("Selected").tag(BackupJobDraft.Mode.guests)
                Text("All Except").tag(BackupJobDraft.Mode.exclude)
                Text("Pool").tag(BackupJobDraft.Mode.pool)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("backupjob.mode")
            switch draft.selectionMode {
            case .all:
                Text("Every guest, including ones added later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .guests, .exclude:
                ForEach(snapshot?.guests.sorted { $0.vmid < $1.vmid } ?? []) { guest in
                    Toggle(isOn: Binding(get: { draft.guests.contains(guest.vmid) }, set: { on in
                        if on { draft.guests.insert(guest.vmid) } else { draft.guests.remove(guest.vmid) }
                    })) {
                        Text("\(String(guest.vmid)) · \(guest.name)")
                    }
                    .accessibilityIdentifier("backupjob.guest.\(guest.vmid)")
                }
                FieldError(message: errors["vmid"] ?? errors["exclude"])
            case .pool:
                Picker("Pool", selection: $draft.pool) {
                    Text("Choose").tag("")
                    ForEach(pools) { Text($0.id).tag($0.id) }
                }
                FieldError(message: errors["pool"])
            }
        } header: {
            Text("Selection")
        } footer: {
            if draft.selectionMode == .exclude {
                Text("Every guest except the chosen ones, including guests added later.")
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Picker("Mode", selection: $draft.backupMode) {
                Text("Snapshot").tag("snapshot")
                Text("Suspend").tag("suspend")
                Text("Stop").tag("stop")
            }
            Picker("Compression", selection: $draft.compression) {
                Text("ZSTD").tag("zstd")
                Text("LZO").tag("lzo")
                Text("GZIP").tag("gzip")
                Text("None").tag("0")
            }
            LabeledContent("Notes") {
                TextField("Notes", text: $draft.notesTemplate, prompt: Text("{{guestname}}"))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Toggle("Protect Backups", isOn: $draft.isProtected)
            Toggle("Repeat Missed Runs", isOn: $draft.repeatMissed)
        } header: {
            Text("Backup")
        } footer: {
            Text("Notes may use {{guestname}}, {{vmid}}, {{node}} and {{cluster}}. Repeat Missed Runs starts a run that was missed while the node was off once it is back.")
        }
    }

    private var retentionSection: some View {
        Section {
            Toggle("Own Retention", isOn: $draft.customRetention)
            if draft.customRetention {
                RetentionFields(prune: $draft.prune, error: errors["prune-backups"])
            }
        } header: {
            Text("Retention")
        } footer: {
            Text(draft.customRetention
                ? "Older backups of these guests beyond the counts are removed after each run."
                : "Uses the retention of the target storage.")
        }
    }

    private func save() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems.isEmpty else {
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if let job {
                try await list.update(job.id, draft.changes(from: original))
            } else {
                try await list.create(draft)
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

/// Keep All plus the counts of `prune-backups`, shared by storages and backup jobs.
struct RetentionFields: View {
    @Binding var prune: PruneOptions
    var error: String?

    var body: some View {
        Toggle("Keep All Backups", isOn: $prune.keepAll)
        if !prune.keepAll {
            ForEach(PruneOptions.keys, id: \.self) { key in
                LabeledTextField(title: Self.title(key), prompt: "–", text: Binding(get: { prune.counts[key] ?? "" }, set: { prune.counts[key] = $0 }),
                                 keyboard: .numberPad, identifier: "prune.\(key)")
            }
        }
        FieldError(message: error)
    }

    static func title(_ key: String) -> LocalizedStringKey {
        switch key {
        case "keep-last": "Keep Last"
        case "keep-hourly": "Keep Hourly"
        case "keep-daily": "Keep Daily"
        case "keep-weekly": "Keep Weekly"
        case "keep-monthly": "Keep Monthly"
        default: "Keep Yearly"
        }
    }
}
