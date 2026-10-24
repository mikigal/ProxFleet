import FleetCore
import PBSKit
import SwiftUI

// MARK: - Options editors

/// Comment and garbage collection schedule; the prune settings only when the datastore still has them from before
/// prune jobs existed.
struct DatastoreGeneralEditor: View {
    let detail: DatastoreDetail
    let original: DatastoreDraft
    let lockMessage: String?
    @State private var draft: DatastoreDraft

    init(detail: DatastoreDetail, original: DatastoreDraft, lockMessage: String?) {
        self.detail = detail
        self.original = original
        self.lockMessage = lockMessage
        _draft = State(initialValue: original)
    }

    private var hasLegacyPrune: Bool {
        !original.pruneSchedule.isEmpty || !original.retention.keepsEverything
    }

    var body: some View {
        BackupServerSettingsForm(title: "General", lockMessage: lockMessage, makeUpdate: makeUpdate, save: detail.save) { errors in
            Section {
                LabeledContent("Comment") {
                    TextField("Comment", text: $draft.comment, prompt: Text("None"))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("datastore.comment")
                }
                FieldError(message: errors["comment"])
            }
            Section {
                CalendarEventField(title: "GC Schedule", schedule: $draft.gcSchedule, identifier: "datastore.gcSchedule", error: errors["gc-schedule"])
            } footer: {
                Text("Garbage collection removes chunks no backup uses anymore and frees their space. Leave it empty to run it only by hand.")
            }
            if hasLegacyPrune {
                Section {
                    CalendarEventField(title: "Prune Schedule", schedule: $draft.pruneSchedule, identifier: "datastore.pruneSchedule", error: errors["prune-schedule"])
                    KeepRulesFields(retention: $draft.retention, errors: errors)
                } header: {
                    Text("Prune")
                } footer: {
                    Text("Pruning set on the datastore itself, from before prune jobs existed. Prune jobs can do the same per namespace.")
                }
            }
        }
    }

    private func makeUpdate() -> BackupServerConfigUpdate? {
        guard draft.problems(isNew: false).isEmpty else { return nil }
        let update = draft.changes(from: original)
        return update.isEmpty ? nil : update
    }
}

/// How the datastore reports finished jobs: through the notification system, or as mail to a user (legacy).
struct DatastoreNotificationEditor: View {
    let detail: DatastoreDetail
    let original: DatastoreDraft
    let lockMessage: String?
    @State private var draft: DatastoreDraft

    init(detail: DatastoreDetail, original: DatastoreDraft, lockMessage: String?) {
        self.detail = detail
        self.original = original
        self.lockMessage = lockMessage
        _draft = State(initialValue: original)
    }

    var body: some View {
        BackupServerSettingsForm(title: "Notifications", lockMessage: lockMessage, makeUpdate: makeUpdate, save: detail.save) { errors in
            Section {
                Picker("Mode", selection: $draft.notificationMode) {
                    Text("Notification System").tag("")
                    Text("Sendmail (Legacy)").tag("legacy-sendmail")
                }
                .accessibilityIdentifier("datastore.notificationMode")
            } footer: {
                if draft.usesSendmail {
                    Text("Mails go to the user's address with the system's sendmail, as before the notification system existed.")
                } else {
                    Text("Notification matchers decide who is told about the datastore's jobs, like for the rest of the server.")
                }
            }
            if draft.usesSendmail {
                Section {
                    LabeledContent("User") {
                        TextField("User", text: $draft.notifyUser, prompt: Text("root@pam"))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    FieldError(message: errors["notify-user"])
                }
                Section("Send For") {
                    ForEach(DatastoreDraft.notificationJobs, id: \.self) { job in
                        Picker(jobTitle(job), selection: Binding(get: { draft.notify[job] }, set: { draft.notify[job] = $0 })) {
                            Text("Default").tag(NotificationLevel?.none)
                            Text("Always").tag(NotificationLevel?.some(.always))
                            Text("Errors").tag(NotificationLevel?.some(.error))
                            Text("Never").tag(NotificationLevel?.some(.never))
                        }
                    }
                    FieldError(message: errors["notify"])
                }
            }
        }
    }

    private func jobTitle(_ job: String) -> LocalizedStringKey {
        switch job {
        case "gc": "Garbage Collection"
        case "verify": "Verification"
        case "sync": "Sync"
        default: "Prune"
        }
    }

    private func makeUpdate() -> BackupServerConfigUpdate? {
        let update = draft.changes(from: original)
        return update.isEmpty ? nil : update
    }
}

struct DatastoreVerifyNewEditor: View {
    let detail: DatastoreDetail
    let original: DatastoreDraft
    let lockMessage: String?
    @State private var draft: DatastoreDraft

    init(detail: DatastoreDetail, original: DatastoreDraft, lockMessage: String?) {
        self.detail = detail
        self.original = original
        self.lockMessage = lockMessage
        _draft = State(initialValue: original)
    }

    var body: some View {
        BackupServerSettingsForm(title: "Verification", lockMessage: lockMessage, makeUpdate: makeUpdate, save: detail.save) { _ in
            Section {
                Toggle("Verify New Snapshots", isOn: $draft.verifyNew)
                    .accessibilityIdentifier("datastore.verifyNew")
            } footer: {
                Text("Verifies every new backup right after it finished. This finds problems early but reads all its data once more.")
            }
        }
    }

    private func makeUpdate() -> BackupServerConfigUpdate? {
        let update = draft.changes(from: original)
        return update.isEmpty ? nil : update
    }
}

/// Puts the datastore into maintenance: read-only keeps restores working, offline blocks everything.
struct DatastoreMaintenanceEditor: View {
    let detail: DatastoreDetail
    let original: DatastoreMaintenance?
    let lockMessage: String?
    @State private var kind: DatastoreMaintenance.Kind?
    @State private var message: String

    init(detail: DatastoreDetail, original: DatastoreMaintenance?, lockMessage: String?) {
        self.detail = detail
        self.original = original
        self.lockMessage = lockMessage
        _kind = State(initialValue: original?.kind)
        _message = State(initialValue: original?.message ?? "")
    }

    /// Maintenance the server sets itself (unmounting, deleting, refreshing S3) is shown but not offered.
    private var isSetByServer: Bool {
        guard let kind = original?.kind else { return original != nil }
        return ![.readOnly, .offline].contains(kind)
    }

    private var maintenance: DatastoreMaintenance? {
        kind.map { DatastoreMaintenance(kind: $0, message: message.trimmingCharacters(in: .whitespaces).isEmpty ? nil : message) }
    }

    var body: some View {
        BackupServerSettingsForm(title: "Maintenance Mode", lockMessage: isSetByServer ? String(localized: "The server set this mode for an operation in progress.") : lockMessage,
                                 makeUpdate: makeUpdate, save: { update throws(ConfigUpdateError) in try await detail.save(update) }) { errors in
            Section {
                Picker("Mode", selection: $kind) {
                    Text("None").tag(DatastoreMaintenance.Kind?.none)
                    Text("Read-Only").tag(DatastoreMaintenance.Kind?.some(.readOnly))
                    Text("Offline").tag(DatastoreMaintenance.Kind?.some(.offline))
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("datastore.maintenance")
            } footer: {
                switch kind {
                case .readOnly: Text("Backups and anything that changes the datastore are refused; restores and downloads keep working.")
                case .offline: Text("Nothing can read or write the datastore, e.g. while its disks are replaced.")
                default: Text("The datastore works normally.")
                }
            }
            if kind != nil {
                Section {
                    TextField("Message", text: $message, prompt: Text("Why, for others to see"))
                        .accessibilityIdentifier("datastore.maintenanceMessage")
                    FieldError(message: errors["maintenance-mode"] ?? (message.count > 64 ? String(localized: "The message can be 64 characters long at most.") : nil))
                }
            }
        }
    }

    private func makeUpdate() -> BackupServerConfigUpdate? {
        guard message.count <= 64, maintenance != original else { return nil }
        var update = BackupServerConfigUpdate()
        update.set("maintenance-mode", maintenance?.stringValue)
        return update
    }
}

/// Performance settings of the datastore that the web interface keeps under Tuning Options.
struct DatastoreTuningEditor: View {
    let detail: DatastoreDetail
    let original: DatastoreDraft
    let lockMessage: String?
    @State private var draft: DatastoreDraft

    init(detail: DatastoreDetail, original: DatastoreDraft, lockMessage: String?) {
        self.detail = detail
        self.original = original
        self.lockMessage = lockMessage
        _draft = State(initialValue: original)
    }

    private func value(_ key: DatastoreDraft.TuningKey) -> Binding<String> {
        Binding(get: { draft.tuning[key.rawValue] ?? "" }, set: { draft.tuning[key.rawValue] = $0 })
    }

    var body: some View {
        BackupServerSettingsForm(title: "Tuning Options", lockMessage: lockMessage, makeUpdate: makeUpdate, save: detail.save) { errors in
            Section {
                Picker("Chunk Order", selection: value(.chunkOrder)) {
                    Text("Default (Inode)").tag("")
                    Text("Inode").tag("inode")
                    Text("None").tag("none")
                }
                Picker("Sync Level", selection: value(.syncLevel)) {
                    Text("Default (File System)").tag("")
                    Text("None").tag("none")
                    Text("File").tag("file")
                    Text("File System").tag("filesystem")
                }
            } footer: {
                Text("Chunk order sorts chunks by inode before reading, which is faster on spinning disks. The sync level sets how safely new chunks are written: per file system, per file, or not at all.")
            }
            if detail.connection.supports(backupServer: .garbageCollectionTuning) {
                Section {
                    Picker("Access Time Check", selection: value(.gcAtimeSafetyCheck)) {
                        Text("Default (On)").tag("")
                        Text("On").tag("true")
                        Text("Off").tag("false")
                    }
                    numberField("Access Time Cutoff", key: .gcAtimeCutoff, prompt: "1445", unit: String(localized: "minutes"))
                    numberField("Chunk Cache Capacity", key: .gcCacheCapacity, prompt: "1048576", unit: nil)
                } header: {
                    Text("Garbage Collection")
                } footer: {
                    Text("Garbage collection relies on the file system updating access times. The cutoff is how long unused chunks are kept; a cache of 0 turns the cache off.")
                }
            }
            if detail.connection.supports(backupServer: .verificationThreads) {
                Section("Verification") {
                    numberField("Reader Threads", key: .verificationReaders, prompt: "1", unit: nil)
                    numberField("Verify Threads", key: .verificationWorkers, prompt: "4", unit: nil)
                }
            }
            FieldError(message: errors["tuning"])
        }
    }

    private func numberField(_ title: LocalizedStringKey, key: DatastoreDraft.TuningKey, prompt: String, unit: String?) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: value(key), prompt: Text(verbatim: prompt))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("tuning.\(key.rawValue)")
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }

    private func makeUpdate() -> BackupServerConfigUpdate? {
        let update = draft.changes(from: original)
        return update.isEmpty ? nil : update
    }
}

// MARK: - Adding a datastore

/// Adds a datastore: a directory on the server, a removable device, or an S3 bucket.
struct AddDatastoreView: View {
    let connection: ServerConnection
    @State private var draft = DatastoreDraft()
    @State private var partitions: [(disk: BackupServerDisk, partition: BackupServerDisk.Partition)] = []
    @State private var endpoints: [S3Endpoint] = []
    @State private var buckets: [String] = []
    @State private var showsPrune = false
    @State private var serverErrors: [String: String] = [:]
    @State private var showsProblems = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: true) : [:]).merging(serverErrors) { _, server in server }
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $draft.kind) {
                    Text("Local").tag(DatastoreDraft.Kind.local)
                    if connection.supports(backupServer: .removableDatastores) {
                        Text("Removable").tag(DatastoreDraft.Kind.removable)
                    }
                    if connection.supports(backupServer: .s3Datastores) {
                        Text("S3").tag(DatastoreDraft.Kind.s3)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("datastore.kind")
                LabeledContent("Name") {
                    TextField("Name", text: $draft.name, prompt: Text("store1"))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("datastore.name")
                }
                FieldError(message: errors["name"])
            }
            locationSection
            Section {
                CalendarEventField(title: "GC Schedule", schedule: $draft.gcSchedule, identifier: "datastore.gcSchedule", error: errors["gc-schedule"])
                CalendarEventField(title: "Prune Schedule", schedule: $draft.pruneSchedule, identifier: "datastore.pruneSchedule", error: errors["prune-schedule"])
                DisclosureGroup("Prune Options", isExpanded: $showsPrune) {
                    KeepRulesFields(retention: $draft.retention, errors: errors)
                }
            } footer: {
                Text("The prune schedule and options become a prune job of the datastore. Without keep options, nothing is removed.")
            }
            Section {
                LabeledContent("Comment") {
                    TextField("Comment", text: $draft.comment, prompt: Text("None"))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("datastore.comment")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Add Datastore")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Add", isWorking: isWorking) { Task { await create() } }
                    .accessibilityIdentifier("datastore.create")
            }
        }
        .task {
            async let disks = try? connection.send(PBS.disks())
            async let endpoints = connection.supports(backupServer: .s3Datastores) ? try? connection.send(PBS.s3Endpoints()).value : nil
            partitions = (await disks ?? []).flatMap { disk in disk.datastorePartitions.map { (disk, $0) } }
            self.endpoints = await endpoints ?? []
        }
        .onChange(of: draft.s3Endpoint) {
            buckets = []
            guard !draft.s3Endpoint.isEmpty else { return }
            Task { buckets = (try? await connection.send(PBS.s3Buckets(draft.s3Endpoint)).names) ?? [] }
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        Section {
            switch draft.kind {
            case .local:
                pathField("Backing Path", prompt: "/mnt/datastore/store1")
                if connection.supports(backupServer: .reuseDatastore) {
                    Toggle("Reuse Existing Datastore", isOn: $draft.reuseExisting)
                        .accessibilityIdentifier("datastore.reuse")
                }
            case .removable:
                Picker("Device", selection: $draft.backingDevice) {
                    Text("Choose").tag("")
                    ForEach(partitions, id: \.partition.id) { item in
                        Text(verbatim: "\(item.partition.devicePath) · \(Format.bytes(item.partition.size))\(item.disk.model.map { " · \($0)" } ?? "")")
                            .tag(item.partition.uuid ?? "")
                    }
                }
                .accessibilityIdentifier("datastore.device")
                FieldError(message: errors["backing-device"] ?? (partitions.isEmpty ? String(localized: "No partition with a file system. Prepare the device under Disks first.") : nil))
                pathField("Path on Device", prompt: "backups")
                Toggle("Reuse Existing Datastore", isOn: $draft.reuseExisting)
            case .s3:
                Picker("S3 Endpoint", selection: $draft.s3Endpoint) {
                    Text("Choose").tag("")
                    ForEach(endpoints) { Text(verbatim: $0.id).tag($0.id) }
                }
                .accessibilityIdentifier("datastore.s3Endpoint")
                FieldError(message: errors["backend"] ?? (endpoints.isEmpty ? String(localized: "Add an S3 endpoint under S3 Endpoints first.") : nil))
                LabeledContent("Bucket") {
                    HStack {
                        TextField("Bucket", text: $draft.bucket, prompt: Text("backups"))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("datastore.bucket")
                        if !buckets.isEmpty {
                            Menu {
                                ForEach(buckets, id: \.self) { bucket in
                                    Button(bucket) { draft.bucket = bucket }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                        }
                    }
                }
                FieldError(message: errors["bucket"])
                pathField("Local Cache", prompt: "/mnt/datastore/cache")
                Toggle("Reuse Existing Datastore", isOn: $draft.reuseExisting)
                Toggle("Overwrite In-Use Marker", isOn: $draft.overwriteInUse)
            }
        } header: {
            Text("Location")
        } footer: {
            switch draft.kind {
            case .local: Text("A directory on the server, created when missing. It must be empty unless an existing datastore is reused.")
            case .removable: Text("A directory on a USB disk or other device that is detached at times. The datastore is found again by its file system.")
            case .s3: Text("The chunks go to the bucket; the local cache keeps recent ones. A bucket may hold the datastore of one server only.")
            }
        }
    }

    @ViewBuilder
    private func pathField(_ title: LocalizedStringKey, prompt: String) -> some View {
        LabeledContent(title) {
            TextField(title, text: $draft.path, prompt: Text(verbatim: prompt))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .accessibilityIdentifier("datastore.path")
        }
        FieldError(message: errors["path"])
    }

    private func create() async {
        showsProblems = true
        serverErrors = [:]
        errorMessage = nil
        guard draft.problems(isNew: true).isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let task = try await connection.createDatastore(draft)
            if case .failed(let message) = await connection.tasks.result(of: task.id) {
                errorMessage = message
                return
            }
            await connection.refresh()
            dismiss()
        } catch .invalid(let message, let fields) {
            serverErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
