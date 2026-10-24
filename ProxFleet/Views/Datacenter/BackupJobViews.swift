import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Scheduled backup jobs of the datacenter, with Run Now and the guests no job covers. Shown as a server's Backup tab.
struct BackupJobsView: View {
    let list: BackupJobList
    @State private var creating = false
    @State private var running: BackupJob?
    @State private var removing: BackupJob?
    @State private var startedMessage: String?
    @State private var errorMessage: String?

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
                } header: {
                    Text("Backup Jobs")
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
                notificationSection
                advancedSection
            }
            .disabled(!list.canModify)
            if let job {
                Section {
                    NavigationLink {
                        BackupJobVolumesView(list: list, job: job)
                    } label: {
                        Label("Included Disks", systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("backupjob.volumes")
                } footer: {
                    Text("Which disks of the job's guests are backed up, and why.")
                }
            }
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
            if isNew {
                LabeledTextField(title: "Job ID", prompt: "Automatic", text: $draft.jobID, identifier: "backupjob.id")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                FieldError(message: errors["id"])
            }
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

    private var notificationSection: some View {
        Section {
            Picker("Notify", selection: $draft.usesLegacySendmail) {
                Text("Global Settings").tag(false)
                Text("Sendmail (Legacy)").tag(true)
            }
            .accessibilityIdentifier("backupjob.notification")
            if draft.usesLegacySendmail {
                LabeledTextField(title: "Recipients", prompt: "root@pam, ops@example.com", text: $draft.mailto, keyboard: .emailAddress, identifier: "backupjob.mailto")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                FieldError(message: errors["mailto"])
                Picker("When", selection: $draft.mailNotification) {
                    Text("Always").tag("always")
                    Text("On Failure Only").tag("failure")
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(draft.usesLegacySendmail
                ? "Mails the recipients with sendmail, as before notification targets existed. Users are mailed at the address of their account."
                : "Uses the datacenter's notification matchers and targets. Matchers can match this job by its ID.")
        }
    }

    private var advancedSection: some View {
        Section {
            LabeledContent("Bandwidth Limit") {
                HStack {
                    TextField("Default", text: $draft.bandwidthLimit)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("backupjob.bwlimit")
                    Text(verbatim: "KiB/s").foregroundStyle(.secondary)
                }
            }
            FieldError(message: errors["bwlimit"])
            LabeledTextField(title: "Zstd Threads", prompt: "1", text: $draft.zstdThreads, keyboard: .numberPad, identifier: "backupjob.zstd")
            FieldError(message: errors["zstd"])
            LabeledTextField(title: "IO Workers", prompt: "16", text: $draft.ioWorkers, keyboard: .numberPad, identifier: "backupjob.workers")
            FieldError(message: errors["performance"])
            Toggle("Fleecing", isOn: $draft.fleecing)
                .accessibilityIdentifier("backupjob.fleecing")
            if draft.fleecing {
                Picker("Fleecing Storage", selection: $draft.fleecingStorage) {
                    Text("Default").tag("")
                    ForEach(Self.imageStorages(snapshot), id: \.self) { Text($0).tag($0) }
                    if !draft.fleecingStorage.isEmpty, !Self.imageStorages(snapshot).contains(draft.fleecingStorage) {
                        Text(draft.fleecingStorage).tag(draft.fleecingStorage)
                    }
                }
                .accessibilityIdentifier("backupjob.fleecingStorage")
            }
            Picker("PBS Change Detection", selection: $draft.pbsChangeDetection) {
                Text("Default").tag("")
                Text("Legacy").tag("legacy")
                Text("Data").tag("data")
                Text("Metadata").tag("metadata")
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Empty fields use the datacenter's defaults. Zstd threads apply to backups not on a Backup Server; 0 uses half of the cores. IO workers and fleecing apply to VMs: fleecing keeps the VM's writes during the backup in a temporary image, so a slow backup target does not slow the VM. PBS change detection applies to container backups on a Proxmox Backup Server.")
        }
    }

    /// Storages for fleecing images.
    private static func imageStorages(_ snapshot: ClusterSnapshot?) -> [String] {
        Array(Set((snapshot?.storages ?? []).filter { $0.content.contains("images") }.map(\.name))).sorted()
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

/// The guests a job covers and which of their disks it backs up, like the web interface's Job Detail.
private struct BackupJobVolumesView: View {
    let list: BackupJobList
    let job: BackupJob
    @State private var volumes: BackupJobVolumes?
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(volumes?.guests ?? []) { guest in
                Section {
                    if guest.volumes.isEmpty {
                        Text("No disks").foregroundStyle(.secondary)
                    }
                    ForEach(guest.volumes) { volume in
                        HStack(spacing: 12) {
                            Image(systemName: volume.isIncluded ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(volume.isIncluded ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(volume.key).font(.body.monospaced())
                                Text([volume.name, volume.reason.map(Self.reasonTitle)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Label("\(String(guest.id)) · \(guest.name ?? String(localized: "Removed"))",
                          systemImage: guest.type == "lxc" ? "shippingbox" : guest.type == "qemu" ? "desktopcomputer" : "questionmark.square.dashed")
                }
            }
        }
        .overlay {
            if let errorMessage {
                ContentUnavailableView("Cannot Load the Disks", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if volumes == nil {
                ProgressView()
            } else if volumes?.guests.isEmpty == true {
                ContentUnavailableView("No Guests", systemImage: "internaldrive", description: Text("The job covers no guests right now."))
            }
        }
        .navigationTitle("Included Disks")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            volumes = try await list.connection.send(PVE.backupJobVolumes(job.id))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func reasonTitle(_ reason: String) -> String {
        switch reason {
        case "backup=yes": String(localized: "backup on")
        case "backup=no": String(localized: "backup off")
        case "rootfs": String(localized: "root disk")
        case "mountpoint": String(localized: "mount point")
        case "efidisk": String(localized: "EFI disk")
        case "tpmstate": String(localized: "TPM state")
        default: reason
        }
    }
}
