import Charts
import FleetCore
import PBSKit
import ProxmoxCore
import PVEKit
import SwiftUI

nonisolated enum DatastoreTab: String, DetailTab {
    case summary, content, jobs, options, permissions

    var title: LocalizedStringKey {
        switch self {
        case .summary: "Summary"
        case .content: "Content"
        case .jobs: "Jobs"
        case .options: "Options"
        case .permissions: "Permissions"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "chart.bar.doc.horizontal"
        case .content: "archivebox"
        case .jobs: "calendar.badge.clock"
        case .options: "slider.horizontal.3"
        case .permissions: "person.badge.key"
        }
    }
}

/// One datastore: its summary, content, jobs, settings and permissions.
struct DatastoreDetailView: View {
    @State private var detail: DatastoreDetail
    @State private var jobs: BackupServerJobs
    @State private var tab: DatastoreTab = .summary
    @State private var actionError: String?
    @State private var verifying = false
    @State private var showsConnection = false
    @State private var confirmsS3Refresh = false
    @Environment(\.dismiss) private var dismiss

    private var isS3: Bool { detail.config?.isS3 == true || detail.status?.backendType == "s3" }

    init(store: String, connection: ServerConnection) {
        _detail = State(initialValue: DatastoreDetail(store: store, connection: connection))
        _jobs = State(initialValue: BackupServerJobs(connection: connection, store: store))
    }

    var body: some View {
        content
            .navigationTitle(detail.store)
            .safeAreaInset(edge: .bottom) {
                DetailTabBar(selection: $tab)
                    .padding(.bottom, 6)
            }
            .sensoryFeedback(.selection, trigger: tab)
            .task {
                if !detail.hasLoaded { await detail.load() }
                await detail.keepRefreshing()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Actions", systemImage: "ellipsis.circle") {
                        if detail.summary?.mountStatus == .notMounted {
                            Button("Mount", systemImage: "externaldrive.badge.plus") { run { try await detail.mount() } }
                                .disabled(!detail.can("Datastore.Modify"))
                        } else {
                            Button("Start Garbage Collection", systemImage: "trash") { run { try await detail.startGarbageCollection() } }
                                .disabled(!detail.can("Datastore.Modify"))
                                .accessibilityIdentifier("datastore.gc")
                            Button("Verify All…", systemImage: "checkmark.shield") { verifying = true }
                                .disabled(!detail.can("Datastore.Verify"))
                                .accessibilityIdentifier("datastore.verify")
                            if detail.summary?.mountStatus == .mounted {
                                Button("Unmount", systemImage: "eject") { run { try await detail.unmount() } }
                                    .disabled(!detail.can("Datastore.Modify"))
                            }
                            if isS3 {
                                Button("Refresh from S3 Bucket…", systemImage: "arrow.triangle.2.circlepath.icloud") { confirmsS3Refresh = true }
                                    .disabled(!detail.can("Datastore.Modify"))
                                    .accessibilityIdentifier("datastore.s3Refresh")
                            }
                        }
                        Divider()
                        Button("Connection Information", systemImage: "info.circle") { showsConnection = true }
                            .accessibilityIdentifier("datastore.connection")
                    }
                    .accessibilityIdentifier("datastore.actions")
                }
            }
            .sheet(isPresented: $verifying) {
                NavigationStack {
                    VerifyAllView(detail: detail)
                }
            }
            .sheet(isPresented: $showsConnection) {
                NavigationStack {
                    DatastoreConnectionView(detail: detail)
                }
            }
            .alert("Refresh from the S3 Bucket?", isPresented: $confirmsS3Refresh) {
                Button("Cancel", role: .cancel) {}
                Button("Refresh") { run { try await detail.refreshFromS3() } }
            } message: {
                Text("The server reads the bucket's contents again, for example after objects changed outside of it. The datastore is in maintenance until the task finishes.")
            }
            .alert("Action Failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK") {}
            } message: {
                Text(actionError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .summary:
            DatastoreSummaryList(detail: detail)
        case .content:
            if detail.isMounted {
                DatastoreContentView(store: detail.store, connection: detail.connection)
            } else {
                ContentUnavailableView("Not Mounted", systemImage: "externaldrive.badge.xmark", description: Text("Mount the datastore to see its backups."))
            }
        case .jobs:
            BackupServerJobsView(jobs: jobs)
        case .options:
            DatastoreOptionsList(detail: detail, onRemoved: { dismiss() })
        case .permissions:
            DatastorePermissionsList(detail: detail)
        }
    }

    private func run(_ action: @escaping () async throws -> TaskCenter.TrackedTask) {
        Task {
            do {
                _ = try await action()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

// MARK: - Summary

private struct DatastoreSummaryList: View {
    let detail: DatastoreDetail
    @State private var metric: DatastoreHistoryMetric = .usage

    var body: some View {
        List {
            Section {
                header
            }
            if let maintenance = detail.summary?.maintenance {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(maintenance.kind == .offline ? "Offline for maintenance" : maintenance.kind == .readOnly ? "Read-only for maintenance" : "In maintenance (\(maintenance.rawKind))")
                                .font(.subheadline.weight(.semibold))
                            if let message = maintenance.message {
                                Text(message).font(.subheadline)
                            }
                        }
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                    }
                }
            }
            if let error = detail.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if detail.summary?.mountStatus == .notMounted {
                Section {
                    Label("The device of this removable datastore is not attached or not mounted. Mount it from the actions menu once it is connected.", systemImage: "externaldrive.badge.xmark")
                        .font(.subheadline)
                }
            }
            if let status = detail.status {
                Section("Usage") {
                    UsageGauge(title: "Used", fraction: status.usedFraction, detail: "\(Format.bytes(status.used)) of \(Format.bytes(status.total)) · \(Format.bytes(status.available)) free")
                    if let full = detail.usage?.estimatedFullDate {
                        LabeledContent("Estimated Full", value: full.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let operations = detail.operations, operations.read + operations.write > 0 {
                        LabeledContent("Active Operations", value: String(localized: "\(operations.read) reading · \(operations.write) writing"))
                    }
                }
                Section("Backups") {
                    ForEach(BackupType.allCases) { type in
                        if let counts = status.counts[type] {
                            LabeledContent {
                                Text("^[\(counts.groups) group](inflect: true) · ^[\(counts.snapshots) snapshot](inflect: true)")
                            } label: {
                                Label(type.title, systemImage: type.systemImage)
                            }
                        }
                    }
                    if status.counts.values.allSatisfy({ $0.groups == 0 }) {
                        Text("No backups yet.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let s3 = detail.status?.s3Statistics {
                Section {
                    LabeledContent("Uploaded", value: Format.bytes(s3.uploaded))
                    LabeledContent("Downloaded", value: Format.bytes(s3.downloaded))
                    LabeledContent("Requests") {
                        Text(verbatim: "GET \(s3.get) · PUT \(s3.put) · POST \(s3.post) · HEAD \(s3.head) · DELETE \(s3.delete)")
                            .font(.footnote.monospacedDigit())
                    }
                } header: {
                    Text("S3 Statistics")
                } footer: {
                    Text("Since the counters were last reset by the datastore's threshold reset schedule.")
                }
            }
            if let gc = detail.garbageCollection ?? detail.status?.garbageCollection {
                GarbageCollectionSection(status: gc)
            }
            if detail.isMounted {
                Section("History") {
                    Picker("Metric", selection: $metric) {
                        ForEach(metrics) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch metric {
                    case .usage:
                        PerformanceChart(points: detail.history.map(\.chartPoint), metric: .usage, timeframe: detail.timeframe)
                    case .transfer:
                        PerformanceChart(points: detail.history.map(\.chartPoint), metric: .disk, timeframe: detail.timeframe)
                    case .operations, .ioDelay, .s3:
                        DatastoreSeriesChart(points: detail.history, metric: metric, timeframe: detail.timeframe)
                    }
                    Picker("Timeframe", selection: Bindable(detail).timeframe) {
                        ForEach(RRDTimeframe.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .refreshable { await detail.load() }
        .overlay {
            if !detail.hasLoaded { ProgressView() }
        }
    }

    /// S3 traffic only for S3 datastores, IO delay only where the server records the busy time.
    private var metrics: [DatastoreHistoryMetric] {
        var metrics: [DatastoreHistoryMetric] = [.usage, .transfer, .operations]
        if detail.history.contains(where: { $0.ioTicks != nil }) { metrics.append(.ioDelay) }
        if detail.config?.isS3 == true || detail.status?.backendType == "s3" { metrics.append(.s3) }
        return metrics
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: detail.summary?.mountStatus == .nonRemovable || detail.summary == nil ? "cylinder.split.1x2" : "externaldrive")
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(detail.store)
                    .font(.headline)
                if let comment = detail.summary?.comment {
                    Text(comment)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let config = detail.config {
                    Text(verbatim: config.isS3 ? "S3 · \(config.backend?["bucket"] ?? "")" : config.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

extension BackupType {
    var title: LocalizedStringKey {
        switch self {
        case .vm: "Virtual Machines"
        case .ct: "Containers"
        case .host: "Hosts"
        }
    }

    var systemImage: String {
        switch self {
        case .vm: "desktopcomputer"
        case .ct: "shippingbox"
        case .host: "laptopcomputer"
        }
    }
}

enum DatastoreHistoryMetric: String, CaseIterable, Identifiable {
    case usage, transfer, operations, ioDelay, s3

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .usage: "Usage"
        case .transfer: "Transfer"
        case .operations: "IOPS"
        case .ioDelay: "IO Delay"
        case .s3: "S3"
        }
    }
}

/// Datastore history the shared performance chart does not draw: operations per second, IO delay and S3 traffic,
/// as the web interface's datastore summary shows them.
private struct DatastoreSeriesChart: View {
    let points: [DatastoreRRDPoint]
    let metric: DatastoreHistoryMetric
    let timeframe: RRDTimeframe

    private struct Sample: Identifiable {
        var time: Date
        var series: String
        var value: Double
        var id: String { "\(series)-\(time.timeIntervalSince1970)" }
    }

    private var samples: [Sample] {
        points.flatMap { point -> [Sample] in
            func sample(_ value: Double?, _ series: String) -> Sample? { value.map { Sample(time: point.time, series: series, value: $0) } }
            switch metric {
            case .operations:
                return [sample(point.readOperations, String(localized: "Read")), sample(point.writeOperations, String(localized: "Write"))].compactMap { $0 }
            case .ioDelay:
                return [sample(point.ioDelay, String(localized: "IO Delay"))].compactMap { $0 }
            case .s3:
                return [sample(point.s3Downloaded, String(localized: "Download")), sample(point.s3Uploaded, String(localized: "Upload"))].compactMap { $0 }
            case .usage, .transfer:
                return []
            }
        }
    }

    var body: some View {
        if samples.isEmpty {
            ContentUnavailableView("No Data Yet", systemImage: "chart.xyaxis.line", description: Text("The server records history while the datastore is in use."))
                .frame(height: 180)
        } else {
            Chart(samples) { sample in
                AreaMark(x: .value("Time", sample.time), y: .value("Value", sample.value))
                    .foregroundStyle(by: .value("Series", sample.series))
                    .opacity(0.15)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.time), y: .value("Value", sample.value))
                    .foregroundStyle(by: .value("Series", sample.series))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...max(samples.map(\.value).max() ?? 1, metric == .ioDelay ? 0.1 : 1) * 1.1)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(format(number)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: xAxisFormat)
                }
            }
            .chartLegend(Set(samples.map(\.series)).count > 1 ? .visible : .hidden)
            .chartForegroundStyleScale(range: [Color.accentColor, Color.teal])
            .frame(height: 180)
            .accessibilityLabel(Text(metric.title))
        }
    }

    private func format(_ value: Double) -> String {
        switch metric {
        case .operations: value.formatted(.number.precision(.fractionLength(0...1))) + "/s"
        case .ioDelay: value.formatted(.number.precision(.fractionLength(0...2))) + " ms"
        case .s3, .usage, .transfer: Int64(value).formatted(.byteCount(style: .binary)) + "/s"
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch timeframe {
        case .hour, .day: .dateTime.hour().minute()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day().month(.abbreviated)
        case .year: .dateTime.month(.abbreviated)
        }
    }
}

/// Where clients reach the datastore, like the web interface's Show Connection Information: the repository for
/// proxmox-backup-client and the settings a Proxmox VE storage needs.
private struct DatastoreConnectionView: View {
    let detail: DatastoreDetail
    @Environment(\.dismiss) private var dismiss

    private var address: ServerAddress { detail.connection.currentAddress }
    /// IPv6 addresses go in brackets, and a port other than 8007 after the host.
    private var server: String {
        let host = address.host.contains(":") ? "[\(address.host)]" : address.host
        return address.port == 8007 ? host : "\(host):\(address.port)"
    }
    private var repository: String { "\(server):\(detail.store)" }

    var body: some View {
        Form {
            Section {
                CopyableValueRow(title: "Datastore", value: detail.store, identifier: "connection.datastore")
                CopyableValueRow(title: "Hostname/IP", value: address.host, identifier: "connection.host")
                if let fingerprint = detail.connection.backupServer?.status?.certificateFingerprint {
                    CopyableValueRow(title: "Fingerprint", value: fingerprint, identifier: "connection.fingerprint")
                }
            }
            Section {
                CopyableValueRow(title: "Repository", value: repository, identifier: "connection.repository")
                CopyableValueRow(title: "With Current User", value: "\(detail.connection.profile.userID)@\(repository)", identifier: "connection.repositoryWithUser")
            } header: {
                Text("Repository for CLI and API")
            } footer: {
                Text("For proxmox-backup-client --repository or PBS_REPOSITORY. A Proxmox VE storage takes the host, datastore and fingerprint.")
            }
        }
        .navigationTitle("Connection Information")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

extension DatastoreRRDPoint {
    /// The sample in the shape the performance chart draws: usage as storage, transfer as disk I/O.
    var chartPoint: RRDPoint {
        var point = RRDPoint(time: time, diskRead: readBytes, diskWrite: writeBytes)
        point.storageUsed = used
        point.storageTotal = total
        return point
    }
}

/// The last garbage collection: what it found and removed, and when it runs next.
private struct GarbageCollectionSection: View {
    let status: GarbageCollectionStatus

    var body: some View {
        Section("Garbage Collection") {
            if let state = status.lastRunState, let end = status.lastRunEnd {
                LabeledContent("Last Run") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state == "OK" ? String(localized: "Succeeded") : state)
                            .foregroundStyle(state == "OK" ? .green : state.hasPrefix("WARNINGS") ? .orange : .red)
                        Text(end, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if status.upid != nil {
                LabeledContent("Last Run", value: String(localized: "Running"))
            } else {
                LabeledContent("Last Run", value: String(localized: "Never"))
            }
            if let schedule = status.schedule {
                LabeledContent("Schedule") { Text(verbatim: schedule).monospaced() }
            }
            if let next = status.nextRun {
                LabeledContent("Next Run", value: next.formatted(date: .abbreviated, time: .shortened))
            }
            if status.upid != nil {
                if let factor = status.deduplicationFactor {
                    LabeledContent("Deduplication Factor", value: factor.formatted(.number.precision(.fractionLength(2))))
                }
                LabeledContent("Data in Backups", value: Format.bytes(status.indexDataBytes))
                LabeledContent("On Disk", value: "\(Format.bytes(status.diskBytes)) · \(status.diskChunks.formatted()) chunks")
                LabeledContent("Removed", value: "\(Format.bytes(status.removedBytes)) · \(status.removedChunks.formatted()) chunks")
                LabeledContent("Pending Removal", value: "\(Format.bytes(status.pendingBytes)) · \(status.pendingChunks.formatted()) chunks")
                if status.removedBad + status.stillBad > 0 {
                    LabeledContent("Bad Chunks", value: String(localized: "\(status.removedBad) removed · \(status.stillBad) remaining"))
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

/// Verify All: every snapshot of the datastore, by default only those not verified recently.
private struct VerifyAllView: View {
    let detail: DatastoreDetail
    @State private var skipVerified = true
    @State private var reverifyAfterDays = 30
    @State private var reverifies = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle("Skip Verified Snapshots", isOn: $skipVerified)
                    .accessibilityIdentifier("verify.skip")
                if skipVerified {
                    Toggle("Re-Verify Old Verifications", isOn: $reverifies)
                    if reverifies {
                        NumberField(title: "Re-Verify After", value: $reverifyAfterDays, range: 1...3650, unit: String(localized: "days"))
                    }
                }
            } footer: {
                Text("Verification reads every chunk and checks it, which takes long on large datastores and loads the disks.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Verify All")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Verify", isWorking: isWorking) {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            try await detail.verifyAll(skipVerified: skipVerified, reverifyAfterDays: skipVerified && reverifies ? reverifyAfterDays : nil)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .accessibilityIdentifier("verify.start")
            }
        }
    }
}

// MARK: - Options

private struct DatastoreOptionsList: View {
    let detail: DatastoreDetail
    let onRemoved: () -> Void
    @State private var removing = false

    private var lockMessage: String? {
        detail.can("Datastore.Modify") ? nil : missingPrivilegeMessage("Datastore.Modify", on: detail.aclPath)
    }

    var body: some View {
        List {
            if let config = detail.config {
                let draft = DatastoreDraft(config)
                Section {
                    NavigationLink {
                        DatastoreGeneralEditor(detail: detail, original: draft, lockMessage: lockMessage)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Comment", value: config.comment ?? String(localized: "None"))
                            LabeledContent("GC Schedule") { Text(verbatim: config.gcSchedule ?? "—").monospaced() }
                            if let prune = config.pruneSchedule {
                                LabeledContent("Prune Schedule") { Text(verbatim: prune).monospaced() }
                            }
                        }
                    }
                    .accessibilityIdentifier("options.general")
                } header: {
                    Text("General")
                }
                Section("Notifications") {
                    NavigationLink {
                        DatastoreNotificationEditor(detail: detail, original: draft, lockMessage: lockMessage)
                    } label: {
                        LabeledContent("Notifications", value: draft.usesSendmail ? String(localized: "Sendmail") : String(localized: "Notification System"))
                    }
                    .accessibilityIdentifier("options.notifications")
                    if config.isS3, detail.connection.supports(backupServer: .s3Counters) {
                        NavigationLink {
                            DatastoreS3ThresholdsEditor(detail: detail, original: draft, lockMessage: lockMessage)
                        } label: {
                            LabeledContent("S3 Thresholds", value: draft.notificationThresholds.items.isEmpty
                                ? String(localized: "None") : String(localized: "\(draft.notificationThresholds.items.count) set"))
                        }
                        .accessibilityIdentifier("options.s3Thresholds")
                    }
                }
                Section("Verification") {
                    NavigationLink {
                        DatastoreVerifyNewEditor(detail: detail, original: draft, lockMessage: lockMessage)
                    } label: {
                        LabeledContent("Verify New Snapshots", value: config.verifyNew ? String(localized: "Yes") : String(localized: "No"))
                    }
                    .accessibilityIdentifier("options.verifyNew")
                }
                Section("Maintenance") {
                    NavigationLink {
                        DatastoreMaintenanceEditor(detail: detail, original: config.maintenance, lockMessage: lockMessage)
                    } label: {
                        LabeledContent("Maintenance Mode", value: config.maintenance.map(\.title) ?? String(localized: "None"))
                    }
                    .accessibilityIdentifier("options.maintenance")
                }
                Section("Advanced") {
                    NavigationLink {
                        DatastoreTuningEditor(detail: detail, original: draft, lockMessage: lockMessage)
                    } label: {
                        LabeledContent("Tuning Options", value: draft.tuning.items.isEmpty ? String(localized: "Defaults") : String(localized: "\(draft.tuning.items.count) changed"))
                    }
                    .accessibilityIdentifier("options.tuning")
                }
                Section {
                    Button(role: .destructive) {
                        removing = true
                    } label: {
                        Label("Remove Datastore…", systemImage: "trash")
                    }
                    .disabled(!detail.can("Datastore.Allocate"))
                    .accessibilityIdentifier("datastore.remove")
                }
            }
        }
        .task { await detail.loadConfig() }
        .refreshable { await detail.loadConfig() }
        .overlay {
            if detail.config == nil { ProgressView() }
        }
        .sheet(isPresented: $removing) {
            NavigationStack {
                RemoveDatastoreView(detail: detail, onRemoved: onRemoved)
            }
        }
    }
}

extension DatastoreMaintenance {
    var title: String {
        switch kind {
        case .readOnly: String(localized: "Read-Only")
        case .offline: String(localized: "Offline")
        default: rawKind
        }
    }
}

/// Removes a datastore after the user typed its name, as the web interface asks.
private struct RemoveDatastoreView: View {
    let detail: DatastoreDetail
    let onRemoved: () -> Void
    @State private var destroyData = false
    @State private var keepJobs = false
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle("Delete All Data", isOn: $destroyData)
                    .accessibilityIdentifier("remove.destroy")
                Toggle("Keep Job Configurations", isOn: $keepJobs)
            } footer: {
                if destroyData {
                    Text("Every backup in **\(detail.store)** is deleted for good.")
                } else {
                    Text("The backups stay on the disk; the datastore can be added again later with Reuse Existing Datastore.")
                }
            }
            Section {
                TextField(detail.store, text: $confirmation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("remove.confirm")
            } header: {
                Text("Type the name to confirm")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Remove \(detail.store)")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Remove", isWorking: isWorking) { Task { await remove() } }
                    .tint(.red)
                    .disabled(confirmation != detail.store)
                    .accessibilityIdentifier("remove.submit")
            }
        }
    }

    private func remove() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let task = try await detail.delete(destroyData: destroyData, keepJobs: keepJobs)
            if case .failed(let message) = await detail.connection.tasks.result(of: task.id) {
                errorMessage = message
                return
            }
            await detail.connection.refresh()
            dismiss()
            onRemoved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Permissions

private struct DatastorePermissionsList: View {
    let detail: DatastoreDetail
    @State private var errorMessage: String?
    @State private var adding = false
    @State private var actionError: String?

    private var canEdit: Bool { detail.can("Permissions.Modify") }

    var body: some View {
        List {
            if let permissions = detail.permissions {
                Section {
                    ForEach(permissions) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: entry.isToken ? "key" : "person")
                                    .foregroundStyle(.secondary)
                                Text(entry.authID)
                                Spacer()
                                Text(entry.role)
                                    .foregroundStyle(.secondary)
                            }
                            Text(verbatim: entry.path == detail.aclPath ? String(localized: "Whole datastore") + (entry.propagates ? "" : " · " + String(localized: "not inherited")) : entry.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .swipeActions {
                            if canEdit {
                                Button("Remove", systemImage: "trash") {
                                    Task {
                                        do { try await detail.removePermission(entry) } catch { actionError = error.localizedDescription }
                                    }
                                }
                                .tint(.red)
                            }
                        }
                    }
                } footer: {
                    Text("Permissions given on this datastore and its namespaces. Those given on / or /datastore apply too.")
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .overlay {
            if detail.permissions == nil, errorMessage == nil {
                ProgressView()
            } else if detail.permissions?.isEmpty == true {
                ContentUnavailableView("No Permissions", systemImage: "person.badge.key", description: Text("No user or token has a role on this datastore itself."))
            }
        }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Permission", systemImage: "plus") { adding = true }
                        .accessibilityIdentifier("permissions.add")
                }
            }
        }
        .task { errorMessage = await detail.loadPermissions() }
        .refreshable { errorMessage = await detail.loadPermissions() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                AddDatastorePermissionView(detail: detail)
            }
        }
        .alert("Cannot Change the Permission", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }
}

/// Gives a user or API token a role on the datastore or one of its namespaces.
private struct AddDatastorePermissionView: View {
    let detail: DatastoreDetail
    @State private var authID = ""
    @State private var role = "DatastoreReader"
    @State private var namespace = ""
    @State private var propagates = true
    @State private var users: [BackupServerUser] = []
    @State private var roles: [BackupServerRole] = []
    @State private var namespaces: [BackupNamespace] = []
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Picker("User or Token", selection: $authID) {
                    Text("Choose").tag("")
                    ForEach(users) { user in
                        ForEach(user.authIDs, id: \.self) { id in
                            Text(verbatim: id).tag(id)
                        }
                    }
                }
                .accessibilityIdentifier("permission.user")
                Picker("Role", selection: $role) {
                    ForEach(roles.filter { $0.id.hasPrefix("Datastore") || ["Admin", "Audit", "NoAccess"].contains($0.id) }) { role in
                        Text(verbatim: role.id).tag(role.id)
                    }
                }
                .accessibilityIdentifier("permission.role")
                if let comment = roles.first(where: { $0.id == role })?.comment {
                    Text(comment)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Applies To", selection: $namespace) {
                    Text("Whole Datastore").tag("")
                    ForEach(namespaces.filter { !$0.isRoot }) { namespace in
                        Text(verbatim: namespace.path).tag(namespace.path)
                    }
                }
                Toggle("Inherit Below", isOn: $propagates)
            } footer: {
                Text("With Inherit Below, the role also applies to the namespaces underneath.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Add Permission")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Add", isWorking: isWorking) { Task { await add() } }
                    .disabled(authID.isEmpty)
                    .accessibilityIdentifier("permission.save")
            }
        }
        .task {
            async let users = try? detail.connection.send(PBS.users())
            async let roles = try? detail.connection.send(PBS.roles())
            async let namespaces = try? detail.connection.send(PBS.namespaces(detail.store))
            self.users = await users?.value ?? []
            self.roles = await roles ?? []
            self.namespaces = await namespaces ?? []
        }
    }

    private func add() async {
        isWorking = true
        defer { isWorking = false }
        let path = namespace.isEmpty ? detail.aclPath : "\(detail.aclPath)/\(namespace)"
        do {
            try await detail.addPermission(BackupServerACLEntry(path: path, authID: authID, role: role, propagates: propagates))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
