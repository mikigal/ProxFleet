import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Storage replication jobs, like the web interface's Replication panels of the datacenter, a node and a guest:
/// add, edit, run now, remove and read the log of the last run.
struct ReplicationJobsView: View {
    @State private var list: ReplicationJobList
    @State private var creating = false
    @State private var removing: ReplicationJob?
    @State private var errorMessage: String?

    init(connection: ServerConnection, scope: ReplicationJobList.Scope) {
        _list = State(initialValue: ReplicationJobList(connection: connection, scope: scope))
    }

    private var guestNames: [Int: String] {
        Dictionary((list.connection.snapshot?.guests ?? []).map { ($0.vmid, $0.name) }) { first, _ in first }
    }

    var body: some View {
        List {
            if let jobs = list.jobs {
                Section {
                    if jobs.isEmpty {
                        Text("No replication jobs")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(jobs) { job in
                        NavigationLink {
                            ReplicationJobEditor(list: list, job: job)
                        } label: {
                            ReplicationJobRow(job: job, guestName: guestNames[job.guest], showsGuest: !isGuestScope)
                        }
                        .accessibilityIdentifier("replication.\(job.id)")
                        .swipeActions {
                            if job.removal == nil {
                                // Not `role: .destructive`: a full swipe would hide the row, but this only asks first.
                                Button("Remove", systemImage: "trash") { removing = job }
                                    .tint(.red)
                                Button("Run Now", systemImage: "play.fill") { Task { await runNow(job) } }
                                    .tint(.blue)
                            }
                        }
                    }
                } footer: {
                    Text("Jobs copy the guest's ZFS volumes to the target node on their schedule, so a migration or HA can start the guest there with little data to move. Only guests with all disks on ZFS can be replicated.")
                }
            }
        }
        .overlay {
            if !list.isAvailable {
                ContentUnavailableView("Replication Needs a Cluster", systemImage: "arrow.triangle.2.circlepath", description: Text("Jobs copy guests to another node of the cluster."))
            } else if let error = list.loadError, list.jobs == nil {
                ContentUnavailableView("Cannot Load Replication Jobs", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if list.jobs == nil {
                ProgressView()
            }
        }
        .navigationTitle("Replication")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!list.isAvailable)
                    .accessibilityIdentifier("replication.add")
            }
        }
        .refreshable { await list.load() }
        .task {
            guard list.isAvailable else { return }
            await list.load()
            await list.keepRefreshing()
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                ReplicationJobEditor(list: list, job: nil)
            }
        }
        .confirmationDialog("Remove this replication job?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { job in
            Button("Remove", role: .destructive) { Task { await remove(job, keepData: false) } }
                .accessibilityIdentifier("replication.remove.confirm")
            Button("Remove, Keep Copy on \(job.target)") { Task { await remove(job, keepData: true) } }
        } message: { job in
            Text("The job deletes its snapshots and the copy on \(job.target) on its last run, then disappears.")
        }
        .alert("Replication Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var isGuestScope: Bool {
        if case .guest = list.scope { return true }
        return false
    }

    private func runNow(_ job: ReplicationJob) async {
        do {
            try await list.runNow(job)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ job: ReplicationJob, keepData: Bool) async {
        do {
            try await list.delete(job, keepData: keepData)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ReplicationJobRow: View {
    let job: ReplicationJob
    let guestName: String?
    let showsGuest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: job.isEnabled ? "arrow.triangle.2.circlepath" : "pause.circle")
                    .foregroundStyle(job.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(showsGuest ? "\(guestName ?? String(job.guest)) → \(job.target)" : "→ \(job.target)")
                    .font(.headline)
                if !showsGuest || guestName != nil {
                    Text(showsGuest ? String(job.guest) : String(localized: "Job \(job.jobNumber)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(status)
                .font(.subheadline)
                .foregroundStyle(statusColor)
                .lineLimit(2)
            Text([job.schedule, job.comment].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        if job.removal != nil { return String(localized: "Removal scheduled") }
        if job.isRunning { return String(localized: "Syncing…") }
        if let error = job.error { return error }
        if !job.isEnabled { return String(localized: "Disabled") }
        if let last = job.lastSync {
            return String(localized: "Synced \(last.formatted(.relative(presentation: .named)))")
        }
        return job.guestType == nil ? job.target : String(localized: "Not synced yet")
    }

    private var statusColor: Color {
        if job.removal != nil { return .orange }
        if job.error != nil { return .red }
        return .secondary
    }
}

/// The web interface's Replication Job dialog, plus the job's state, Run Now, its log and removal when editing.
struct ReplicationJobEditor: View {
    let list: ReplicationJobList
    let job: ReplicationJob?
    @State private var draft: ReplicationJobDraft
    private let original: ReplicationJobDraft
    @State private var errors: [String: String] = [:]
    @State private var nextRuns: Result<[Date], ConfigUpdateError>?
    @State private var isSaving = false
    @State private var isRunning = false
    @State private var confirmsRemoval = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(list: ReplicationJobList, job: ReplicationJob?) {
        self.list = list
        self.job = job
        var draft: ReplicationJobDraft
        if let job {
            draft = ReplicationJobDraft(job)
        } else {
            switch list.scope {
            case .guest(let reference): draft = ReplicationJobDraft(guest: reference.vmid)
            default: draft = ReplicationJobDraft(guest: 0)
            }
        }
        original = draft
        if job == nil { draft.target = Self.targets(for: draft.guest, connection: list.connection).first ?? "" }
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { job == nil }
    private var connection: ServerConnection { list.connection }

    /// Guests that can get a job: those of the scope, without templates.
    private var guests: [GuestSummary] {
        let all = (connection.snapshot?.guests ?? []).filter { !$0.isTemplate }.sorted { $0.vmid < $1.vmid }
        switch list.scope {
        case .datacenter: return all
        case .node(let node): return all.filter { $0.node == node }
        case .guest(let reference): return all.filter { $0.vmid == reference.vmid }
        }
    }

    /// Online nodes other than the guest's.
    static func targets(for guest: Int, connection: ServerConnection) -> [String] {
        let node = connection.snapshot?.guests.first { $0.vmid == guest }?.node
        return connection.snapshot?.nodes.filter { $0.isOnline && $0.name != node }.map(\.name) ?? []
    }

    var body: some View {
        Form {
            Section {
                if isNew, guests.count != 1 || draft.guest == 0 {
                    Picker("Guest", selection: $draft.guest) {
                        if draft.guest == 0 { Text("Choose").tag(0) }
                        ForEach(guests) { guest in
                            Text("\(String(guest.vmid)) · \(guest.name)").tag(guest.vmid)
                        }
                    }
                    .accessibilityIdentifier("replication.guest")
                    .onChange(of: draft.guest) {
                        let targets = Self.targets(for: draft.guest, connection: connection)
                        if !targets.contains(draft.target) { draft.target = targets.first ?? "" }
                    }
                    FieldError(message: errors["guest"])
                } else {
                    LabeledContent("Guest", value: [String(draft.guest), connection.snapshot?.guests.first { $0.vmid == draft.guest }?.name].compactMap { $0 }.joined(separator: " · "))
                }
                if isNew {
                    Picker("Target", selection: $draft.target) {
                        if draft.target.isEmpty { Text("Choose").tag("") }
                        ForEach(Self.targets(for: draft.guest, connection: connection), id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("replication.target")
                    FieldError(message: errors["target"])
                } else {
                    LabeledContent("Target", value: draft.target)
                }
                Toggle("Enabled", isOn: $draft.isEnabled)
                    .accessibilityIdentifier("replication.enabled")
                LabeledContent("Comment") {
                    TextField("Comment", text: $draft.comment, prompt: Text("None"))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("replication.comment")
                }
            }
            scheduleSection
            Section {
                LabeledTextField(title: "Rate Limit (MB/s)", prompt: "Unlimited", text: $draft.rate, keyboard: .decimalPad, identifier: "replication.rate")
                FieldError(message: errors["rate"])
            } footer: {
                Text("Limits how fast the job copies to the target. Empty is unlimited.")
            }
            if let job {
                stateSection(job)
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? "Add Replication Job" : "Job \(job?.id ?? "")")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                    .disabled(!isNew && draft.changes(from: original).isEmpty)
                    .accessibilityIdentifier("save")
            }
        }
        .task(id: draft.schedule) {
            // Waits until typing pauses before asking the server.
            try? await Task.sleep(for: .milliseconds(400))
            let schedule = draft.schedule.trimmingCharacters(in: .whitespaces)
            guard !Task.isCancelled, !schedule.isEmpty else {
                nextRuns = nil
                return
            }
            nextRuns = await list.nextRuns(of: schedule)
        }
        .task {
            // Keeps the state current, e.g. while the job runs after Run Now.
            guard job != nil else { return }
            await list.keepRefreshing()
        }
        .confirmationDialog("Remove this replication job?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove(keepData: false) } }
            Button("Remove, Keep Copy on \(draft.target)") { Task { await remove(keepData: true) } }
        } message: {
            Text("The job deletes its snapshots and the copy on \(draft.target) on its last run, then disappears.")
        }
    }

    private var scheduleSection: some View {
        Section {
            HStack {
                TextField("Schedule", text: $draft.schedule, prompt: Text(ReplicationJob.defaultSchedule))
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("replication.schedule")
                Menu {
                    ForEach(ReplicationJobDraft.schedulePresets, id: \.schedule) { preset in
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
        } footer: {
            Text("Calendar events like the web interface's: */15 runs every 15 minutes, 21:00 every day. Empty is every 15 minutes.")
        }
    }

    /// The job as the list last loaded it, so the state stays current while the editor is open.
    private func current(_ job: ReplicationJob) -> ReplicationJob {
        list.jobs?.first { $0.id == job.id } ?? job
    }

    @ViewBuilder
    private func stateSection(_ initial: ReplicationJob) -> some View {
        let job = current(initial)
        Section {
            if job.removal != nil {
                Label("Removal scheduled", systemImage: "trash")
                    .foregroundStyle(.orange)
            } else if job.isRunning {
                LabeledContent("Status") { Text("Syncing…") }
            } else if let error = job.error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("replication.error")
            }
            if job.guestType != nil {
                LabeledContent("Last Sync", value: job.lastSync?.formatted(date: .abbreviated, time: .standard) ?? String(localized: "Never"))
                if let duration = job.duration {
                    LabeledContent("Duration", value: Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, fractionalPart: .show(length: 1))))
                }
                LabeledContent("Next Sync", value: job.isPending() ? String(localized: "Pending") : job.nextSync?.formatted(date: .abbreviated, time: .shortened) ?? "–")
                if job.failCount > 0 {
                    LabeledContent("Failures", value: String(job.failCount))
                }
            }
            NavigationLink {
                ReplicationLogView(list: list, job: job)
            } label: {
                Label("Log of Last Run", systemImage: "doc.text")
            }
            .accessibilityIdentifier("replication.log")
        } header: {
            Text("State")
        }
        if job.removal == nil {
            Section {
                Button {
                    Task { await runNow(job) }
                } label: {
                    HStack {
                        Label("Run Now", systemImage: "play.fill")
                        Spacer()
                        if isRunning { ProgressView() }
                    }
                }
                .disabled(isRunning || job.isRunning)
                .accessibilityIdentifier("replication.run")
                Button("Remove Job", systemImage: "trash", role: .destructive) { confirmsRemoval = true }
                    .accessibilityIdentifier("replication.remove")
            } footer: {
                Text("Run Now starts the job within about a minute, when the node's scheduler next looks.")
            }
        }
    }

    private func save() async {
        errors = draft.problems
        guard errors.isEmpty else { return }
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
            errors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runNow(_ job: ReplicationJob) async {
        isRunning = true
        defer { isRunning = false }
        do {
            try await list.runNow(job)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(keepData: Bool) async {
        guard let job else { return }
        do {
            try await list.delete(job, keepData: keepData)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The log of a job's last run, refreshed while it runs.
struct ReplicationLogView: View {
    let list: ReplicationJobList
    let job: ReplicationJob
    @State private var lines: [TaskLogLine]?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(lines ?? []) { line in
                    Text(line.text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .overlay {
            if let errorMessage, lines == nil {
                ContentUnavailableView("Cannot Load Log", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if lines?.isEmpty == true {
                ContentUnavailableView("No Log Yet", systemImage: "doc.text", description: Text("The job has not run on this node yet."))
            } else if lines == nil {
                ProgressView()
            }
        }
        .navigationTitle("Log \(job.id)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                do {
                    lines = try await list.log(of: job)
                    errorMessage = nil
                } catch is CancellationError {
                    break
                } catch {
                    errorMessage = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
