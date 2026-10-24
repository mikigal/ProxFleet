import FleetCore
import PBSKit
import PVEKit
import SwiftUI

/// The backup server's dashboard, with the panels of its web interface: server status, datastore usage, task
/// summary, running and longest tasks, and the subscription.
struct BackupServerDashboardView: View {
    let dashboard: BackupServerDashboard
    @State private var metric: PerformanceMetric = .cpu

    private var connection: ServerConnection { dashboard.connection }
    private var snapshot: BackupServerSnapshot? { connection.backupServer }

    var body: some View {
        List {
            Section {
                header
            }
            if let status = snapshot?.status {
                Section("Usage") {
                    HStack(spacing: 16) {
                        UsageGauge(title: "CPU", fraction: status.cpuUsage, detail: Format.cores(status.cpuCount))
                        UsageGauge(title: "Memory", fraction: Format.fraction(status.memoryUsed, of: status.memoryTotal), detail: "\(Format.bytes(status.memoryUsed)) of \(Format.bytes(status.memoryTotal))")
                    }
                    HStack(spacing: 16) {
                        UsageGauge(title: "Root Disk", fraction: Format.fraction(status.rootUsed, of: status.rootTotal), detail: "\(Format.bytes(status.rootUsed)) of \(Format.bytes(status.rootTotal))")
                        UsageGauge(title: "Swap", fraction: Format.fraction(status.swapUsed, of: status.swapTotal), detail: Format.bytes(status.swapTotal))
                    }
                    if !status.loadAverage.isEmpty {
                        LabeledContent("Load Average", value: status.loadAverage.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " · "))
                    }
                    LabeledContent("IO Delay", value: status.ioWait.formatted(.percent.precision(.fractionLength(1))))
                }
                Section("Performance") {
                    Picker("Metric", selection: $metric) {
                        ForEach(PerformanceMetric.node) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    PerformanceChart(points: dashboard.history, metric: metric, timeframe: dashboard.timeframe)
                    Picker("Timeframe", selection: Bindable(dashboard).timeframe) {
                        ForEach(RRDTimeframe.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            if let snapshot, !snapshot.datastores.isEmpty {
                Section("Datastores") {
                    ForEach(snapshot.datastores) { datastore in
                        DatastoreUsageRow(datastore: datastore, usage: snapshot.usage(of: datastore.store))
                    }
                }
            }
            taskSections
            if let subscription = dashboard.subscription {
                Section("Subscription") {
                    LabeledContent("Status", value: subscription.isActive ? String(localized: "Active") : subscription.status.capitalized)
                    if let product = subscription.productName {
                        Text(product)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !subscription.isActive {
                        Text("Without a subscription the server uses the no-subscription or test repositories for updates.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let status = snapshot?.status {
                Section("System") {
                    if let kernel = status.kernel {
                        LabeledContent("Kernel", value: kernel)
                    }
                    if let model = status.cpuModel {
                        LabeledContent("CPU", value: model)
                    }
                    LabeledContent("CPUs", value: "\(status.cpuCount)")
                    if let mode = status.bootMode {
                        LabeledContent("Boot Mode", value: mode == "efi" ? (status.secureBoot ? "EFI, Secure Boot" : "EFI") : "Legacy BIOS")
                    }
                }
            }
        }
        .refreshable {
            await connection.refresh()
            await dashboard.load()
        }
        .task {
            if !dashboard.hasLoaded { await dashboard.load() }
            await dashboard.keepRefreshing()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot?.nodeName ?? connection.profile.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    StatusDot(color: .green)
                    if let status = snapshot?.status {
                        Text("Online · Up \(Format.uptime(status.uptime))")
                    } else {
                        Text("Online")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let version = snapshot?.version {
                    Text("Proxmox Backup Server \(version.displayVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var taskSections: some View {
        if let error = dashboard.tasksError {
            Section("Tasks") {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Section {
                ForEach(dashboard.summary) { row in
                    TaskSummaryRowView(row: row)
                }
            } header: {
                HStack {
                    Text("Task Summary")
                    Spacer()
                    Menu {
                        Picker("Period", selection: Bindable(dashboard).days) {
                            Text("Last Day").tag(1)
                            Text("Last 7 Days").tag(7)
                            Text("Last 30 Days").tag(30)
                        }
                    } label: {
                        Text(dashboard.days == 1 ? "Last Day" : "Last \(dashboard.days) Days")
                            .textCase(nil)
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("dashboard.days")
                }
            }
            if !dashboard.runningTasks.isEmpty {
                Section("Running Tasks") {
                    ForEach(dashboard.runningTasks) { task in
                        NavigationLink(value: ServerRoute.task(node: task.node, upid: task.upid)) {
                            ClusterTaskRow(task: task, showsGuest: true, showsNode: false)
                        }
                    }
                }
            }
            if !dashboard.longestTasks.isEmpty {
                Section("Longest Tasks") {
                    ForEach(dashboard.longestTasks) { task in
                        NavigationLink(value: ServerRoute.task(node: task.node, upid: task.upid)) {
                            HStack {
                                ClusterTaskRow(task: task, showsGuest: true, showsNode: false)
                                Spacer()
                                Text(Format.duration(dashboard.duration(of: task)))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One kind of task with how many succeeded, had warnings and failed.
private struct TaskSummaryRowView: View {
    let row: TaskSummaryRow

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                count(row.succeeded, systemImage: "checkmark.circle.fill", color: .green)
                count(row.warnings, systemImage: "exclamationmark.circle.fill", color: .orange)
                count(row.failed, systemImage: "xmark.circle.fill", color: .red)
            }
            .font(.subheadline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("summary.\(row.kind.rawValue)")
    }

    private func count(_ value: Int, systemImage: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .foregroundStyle(value > 0 ? color : .secondary.opacity(0.5))
            Text(value, format: .number)
                .foregroundStyle(value > 0 ? .primary : .secondary)
        }
        .frame(minWidth: 38, alignment: .trailing)
    }

    private var title: LocalizedStringKey {
        switch row.kind {
        case .backup: "Backups"
        case .prune: "Prunes"
        case .garbageCollection: "Garbage Collections"
        case .sync: "Syncs"
        case .verify: "Verifications"
        }
    }

    private var systemImage: String {
        switch row.kind {
        case .backup: "archivebox"
        case .prune: "scissors"
        case .garbageCollection: "trash"
        case .sync: "arrow.triangle.2.circlepath"
        case .verify: "checkmark.shield"
        }
    }
}

/// A datastore with its usage and when it will be full, or why its usage is unknown.
struct DatastoreUsageRow: View {
    let datastore: DatastoreSummary
    let usage: DatastoreUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: datastore.mountStatus == .nonRemovable ? "cylinder.split.1x2" : "externaldrive")
                    .foregroundStyle(.tint)
                Text(datastore.store)
                    .font(.headline)
                if datastore.mountStatus == .notMounted {
                    DatastoreBadge(text: "Not Mounted", color: .secondary)
                }
                if let maintenance = datastore.maintenance {
                    DatastoreBadge(text: maintenance.kind == .offline ? "Offline" : "Read-Only", color: .orange)
                }
                if datastore.isS3 {
                    DatastoreBadge(text: "S3", color: .blue)
                }
                Spacer()
                if let usage, usage.error == nil, usage.total > 0 {
                    Text(usage.usedFraction, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospacedDigit())
                }
            }
            if let comment = datastore.comment {
                Text(comment)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let usage, usage.error == nil, usage.total > 0 {
                Gauge(value: min(max(usage.usedFraction, 0), 1)) {
                    EmptyView()
                }
                .gaugeStyle(.linearCapacity)
                .tint(usage.usedFraction > 0.9 ? .red : usage.usedFraction > 0.75 ? .orange : .accentColor)
                HStack {
                    Text("\(Format.bytes(usage.used)) of \(Format.bytes(usage.total))")
                    Spacer()
                    if let full = usage.estimatedFullDate {
                        Text("Full \(full, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let error = usage?.error {
                Text(error.prefix(1).capitalized + error.dropFirst())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("datastore.\(datastore.store)")
    }
}

struct DatastoreBadge: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }
}

/// The datastores of a backup server with their usage.
struct DatastoreListView: View {
    let connection: ServerConnection

    var body: some View {
        List {
            if let snapshot = connection.backupServer {
                ForEach(snapshot.datastores) { datastore in
                    DatastoreUsageRow(datastore: datastore, usage: snapshot.usage(of: datastore.store))
                }
            }
        }
        .overlay {
            if connection.backupServer?.datastores.isEmpty == true {
                ContentUnavailableView("No Datastores", systemImage: "cylinder.split.1x2", description: Text("Datastores hold the backups. You see the ones you have permission for."))
            }
        }
        .refreshable { await connection.refresh() }
    }
}

extension Format {
    /// "4 min 12 s", "2 h 5 min", for how long a task ran.
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(seconds, 0)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}
