import FleetCore
import PBSKit
import ProxmoxCore
import SwiftUI

/// A job to create from the Add menu.
enum NewBackupServerJob: Identifiable {
    case sync(SyncDirection)
    case verify
    case prune

    var id: String {
        switch self {
        case .sync(let direction): "sync-\(direction.rawValue)"
        case .verify: "verify"
        case .prune: "prune"
        }
    }
}

/// A job a confirmation or deletion is about.
struct BackupServerJobReference: Identifiable, Equatable {
    let kind: BackupServerJobs.Kind
    let id: String
    let title: String
    let store: String
}

/// The scheduled jobs of a backup server, or of one datastore: sync, verification, prune and garbage collection.
struct BackupServerJobsView: View {
    let jobs: BackupServerJobs
    @State private var creating: NewBackupServerJob?
    @State private var deleting: BackupServerJobReference?
    @State private var message: (title: String, text: String)?

    private var connection: ServerConnection { jobs.connection }

    var body: some View {
        List {
            if let error = jobs.loadError, jobs.syncJobs != nil {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let sync = jobs.syncJobs, !sync.isEmpty {
                Section {
                    ForEach(sync) { job in
                        NavigationLink {
                            SyncJobEditor(jobs: jobs, job: job)
                        } label: {
                            BackupServerJobRow(title: job.comment ?? job.id, systemImage: job.direction == .push ? "arrow.up.circle" : "arrow.down.circle",
                                               detail: job.routeDescription, schedule: job.schedule, state: job.state)
                        }
                        .accessibilityIdentifier("job.sync.\(job.id)")
                        .jobActions(BackupServerJobReference(kind: .sync, id: job.id, title: job.comment ?? job.id, store: job.store),
                                    jobs: jobs, canChange: jobs.canChange(.sync, store: job.store, direction: job.direction),
                                    deleting: $deleting, message: $message)
                    }
                } header: {
                    Text("Sync Jobs")
                }
            }
            if let verify = jobs.verifyJobs, !verify.isEmpty {
                Section("Verification Jobs") {
                    ForEach(verify) { job in
                        NavigationLink {
                            VerifyJobEditor(jobs: jobs, job: job)
                        } label: {
                            BackupServerJobRow(title: job.comment ?? job.id, systemImage: "checkmark.shield",
                                               detail: Self.location(job.store, job.namespace), schedule: job.schedule, state: job.state)
                        }
                        .accessibilityIdentifier("job.verify.\(job.id)")
                        .jobActions(BackupServerJobReference(kind: .verify, id: job.id, title: job.comment ?? job.id, store: job.store),
                                    jobs: jobs, canChange: jobs.canChange(.verify, store: job.store), deleting: $deleting, message: $message)
                    }
                }
            }
            if let prune = jobs.pruneJobs, !prune.isEmpty {
                Section("Prune Jobs") {
                    ForEach(prune) { job in
                        NavigationLink {
                            PruneJobEditor(jobs: jobs, job: job)
                        } label: {
                            BackupServerJobRow(title: job.comment ?? job.id, systemImage: "scissors",
                                               detail: Self.location(job.store, job.namespace), schedule: job.isDisabled ? nil : job.schedule,
                                               state: job.state, isDisabled: job.isDisabled)
                        }
                        .accessibilityIdentifier("job.prune.\(job.id)")
                        .jobActions(BackupServerJobReference(kind: .prune, id: job.id, title: job.comment ?? job.id, store: job.store),
                                    jobs: jobs, canChange: jobs.canChange(.prune, store: job.store), deleting: $deleting, message: $message)
                    }
                }
            }
            if let collections = jobs.garbageCollection, !collections.isEmpty {
                Section {
                    ForEach(collections) { status in
                        let store = status.store ?? ""
                        NavigationLink {
                            GarbageCollectionJobView(jobs: jobs, store: store)
                        } label: {
                            BackupServerJobRow(title: store, systemImage: "trash",
                                               detail: status.lastRunEnd == nil ? nil : String(localized: "Removed \(status.removedBytes.formatted(.byteCount(style: .binary, spellsOutZero: false))), pending \(status.pendingBytes.formatted(.byteCount(style: .binary, spellsOutZero: false)))"),
                                               schedule: status.schedule, state: JobState(lastRunUPID: status.upid, lastRunState: status.lastRunState,
                                                                                          lastRunEnd: status.lastRunEnd, nextRun: status.nextRun))
                        }
                        .accessibilityIdentifier("job.gc.\(store)")
                        .jobActions(BackupServerJobReference(kind: .garbageCollection, id: store, title: store, store: store),
                                    jobs: jobs, canChange: jobs.canChange(.garbageCollection, store: store), deleting: $deleting, message: $message)
                    }
                } header: {
                    Text("Garbage Collection")
                } footer: {
                    Text("Removes chunks no backup uses anymore. Each datastore has its own schedule.")
                }
            }
        }
        .overlay {
            if jobs.syncJobs == nil {
                if let error = jobs.loadError {
                    ContentUnavailableView("Cannot Load Jobs", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            } else if jobs.isEmpty {
                ContentUnavailableView("No Jobs", systemImage: "calendar.badge.clock", description: Text("Sync, verification and prune jobs run on a schedule."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("Sync Job (Pull)", systemImage: "arrow.down.circle") { creating = .sync(.pull) }
                        .accessibilityIdentifier("job.add.pull")
                    if connection.supports(backupServer: .pushSync) {
                        Button("Sync Job (Push)", systemImage: "arrow.up.circle") { creating = .sync(.push) }
                            .accessibilityIdentifier("job.add.push")
                    }
                    Button("Verification Job", systemImage: "checkmark.shield") { creating = .verify }
                        .accessibilityIdentifier("job.add.verify")
                    Button("Prune Job", systemImage: "scissors") { creating = .prune }
                        .accessibilityIdentifier("job.add.prune")
                }
                .disabled(jobs.stores.isEmpty)
                .accessibilityIdentifier("job.add")
            }
        }
        .refreshable { await jobs.load() }
        .task { await jobs.load() }
        .sheet(item: $creating) { kind in
            NavigationStack {
                switch kind {
                case .sync(let direction): SyncJobEditor(jobs: jobs, direction: direction)
                case .verify: VerifyJobEditor(jobs: jobs, job: nil)
                case .prune: PruneJobEditor(jobs: jobs, job: nil)
                }
            }
        }
        .confirmationDialog("Delete \(deleting?.title ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { job in
            Button("Delete Job", role: .destructive) {
                Task {
                    do {
                        try await jobs.delete(job.kind, id: job.id)
                    } catch {
                        message = (String(localized: "Cannot Delete the Job"), error.localizedDescription)
                    }
                }
            }
        } message: { _ in
            Text("The job stops running. Backups it made stay.")
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message?.text ?? "")
        }
    }

    static func location(_ store: String, _ namespace: BackupNamespace) -> String {
        namespace.isRoot ? store : "\(store)/\(namespace.path)"
    }
}

private extension View {
    /// Run Now and Delete, by swipe and in the context menu.
    func jobActions(_ job: BackupServerJobReference, jobs: BackupServerJobs, canChange: Bool,
                    deleting: Binding<BackupServerJobReference?>, message: Binding<(title: String, text: String)?>) -> some View {
        let run = {
            Task {
                do {
                    try await jobs.run(job.kind, id: job.id)
                } catch {
                    message.wrappedValue = (String(localized: "Cannot Run the Job"), error.localizedDescription)
                }
            }
        }
        return swipeActions {
            if canChange, job.kind != .garbageCollection {
                // Not `role: .destructive`: a full swipe would hide the row, but this only asks first.
                Button("Delete", systemImage: "trash") { deleting.wrappedValue = job }
                    .tint(.red)
            }
            if canChange {
                Button("Run Now", systemImage: "play.fill") { _ = run() }
                    .tint(.blue)
            }
        }
        .contextMenu {
            if canChange {
                Button("Run Now", systemImage: "play.fill") { _ = run() }
                if job.kind != .garbageCollection {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting.wrappedValue = job }
                }
            }
        }
    }
}

/// A job with its target, schedule, and how the last run went.
struct BackupServerJobRow: View {
    let title: String
    let systemImage: String
    var detail: String?
    let schedule: String?
    let state: JobState
    var isDisabled = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if isDisabled {
                        Text("Disabled")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: .capsule)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(timing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            JobStateIcon(state: state)
        }
        .accessibilityElement(children: .combine)
    }

    private var timing: String {
        guard let schedule, !schedule.isEmpty else { return String(localized: "Not scheduled") }
        guard let next = state.nextRun else { return schedule }
        // Numeric: the named style says "next week", which reads badly after "next".
        return String(localized: "\(schedule) · next \(next.formatted(.relative(presentation: .numeric)))")
    }
}

/// How the last run of a job went: running, OK, with warnings or failed.
struct JobStateIcon: View {
    let state: JobState

    var body: some View {
        if state.isRunning {
            ProgressView()
                .accessibilityLabel("Running")
        } else if let succeeded = state.lastRunSucceeded {
            let warnings = state.lastRunState?.hasPrefix("WARNINGS") == true
            Image(systemName: !succeeded ? "xmark.octagon.fill" : warnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(!succeeded ? .red : warnings ? .orange : .green)
                .accessibilityLabel(state.lastRunState ?? "")
        }
    }
}

/// The last run of a job, with its log and Run Now.
struct JobLastRunSection: View {
    let connection: ServerConnection
    let state: JobState
    let canRun: Bool
    let run: () async throws(ConfigUpdateError) -> Void
    @State private var isRunning = false
    @State private var errorMessage: String?

    var body: some View {
        Section("Last Run") {
            if let end = state.lastRunEnd {
                LabeledContent("Finished", value: end.formatted(date: .abbreviated, time: .shortened))
            }
            if state.isRunning {
                LabeledContent("Status") { ProgressView() }
            } else if let result = state.lastRunState {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        JobStateIcon(state: state)
                        Text(result).lineLimit(2)
                    }
                }
            } else {
                Text("The job has not run yet.").foregroundStyle(.secondary)
            }
            if let next = state.nextRun {
                LabeledContent("Next Run", value: next.formatted(date: .abbreviated, time: .shortened))
            }
            if let raw = state.lastRunUPID, let upid = UPID(raw) {
                // A destination, not a `ServerRoute` value: this screen was itself pushed by destination, and a value
                // link from here does not push.
                NavigationLink {
                    TaskLogView(connection: connection, node: upid.node, upid: raw)
                } label: {
                    Label("Show Log", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("job.log")
            }
            if canRun {
                Button {
                    Task {
                        isRunning = true
                        defer { isRunning = false }
                        do {
                            try await run()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .disabled(isRunning || state.isRunning)
                .accessibilityIdentifier("job.run")
            }
            FieldError(message: errorMessage)
        }
    }
}

// MARK: - Garbage collection

/// A datastore's garbage collection: its schedule, the last run's results and Run Now.
struct GarbageCollectionJobView: View {
    let jobs: BackupServerJobs
    let store: String
    @State private var schedule: String
    private let original: String

    init(jobs: BackupServerJobs, store: String) {
        self.jobs = jobs
        self.store = store
        original = jobs.garbageCollection?.first { $0.store == store }?.schedule ?? ""
        _schedule = State(initialValue: original)
    }

    private var status: GarbageCollectionStatus? { jobs.garbageCollection?.first { $0.store == store } }

    var body: some View {
        BackupServerSettingsForm(title: "Garbage Collection", lockMessage: jobs.lockReason(.garbageCollection, store: store)) {
            schedule.trimmingCharacters(in: .whitespaces) == original ? nil : {
                var update = BackupServerConfigUpdate()
                update.set("gc-schedule", schedule.trimmingCharacters(in: .whitespaces).isEmpty ? nil : schedule.trimmingCharacters(in: .whitespaces))
                return update
            }()
        } save: { update throws(ConfigUpdateError) in
            try await jobs.update(.garbageCollection, id: store, update)
            await jobs.connection.refresh()
        } content: { errors in
            Section {
                LabeledContent("Datastore", value: store)
                CalendarEventField(title: "Schedule", schedule: $schedule, identifier: "gc.schedule", error: errors["gc-schedule"])
            } footer: {
                Text("Empty turns scheduled garbage collection off; it can still be started by hand.")
            }
            if let status {
                JobLastRunSection(connection: jobs.connection, state: JobState(lastRunUPID: status.upid, lastRunState: status.lastRunState, lastRunEnd: status.lastRunEnd, nextRun: status.nextRun),
                                  canRun: jobs.canChange(.garbageCollection, store: store)) { () async throws(ConfigUpdateError) in
                    _ = try await jobs.run(.garbageCollection, id: store)
                }
                if status.lastRunEnd != nil {
                    Section("Results") {
                        LabeledContent("Removed", value: "\(status.removedBytes.formatted(.byteCount(style: .binary, spellsOutZero: false))) · \(status.removedChunks.formatted()) chunks")
                        LabeledContent("Pending", value: "\(status.pendingBytes.formatted(.byteCount(style: .binary, spellsOutZero: false))) · \(status.pendingChunks.formatted()) chunks")
                        LabeledContent("On Disk", value: status.diskBytes.formatted(.byteCount(style: .binary, spellsOutZero: false)))
                        if let factor = status.deduplicationFactor {
                            LabeledContent("Deduplication", value: factor.formatted(.number.precision(.fractionLength(2))))
                        }
                        if status.removedBad > 0 || status.stillBad > 0 {
                            LabeledContent("Bad Chunks", value: "\(status.removedBad.formatted()) removed, \(status.stillBad.formatted()) left")
                        }
                        if let duration = status.duration {
                            LabeledContent("Duration", value: Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                        }
                    }
                }
            }
        }
    }
}
