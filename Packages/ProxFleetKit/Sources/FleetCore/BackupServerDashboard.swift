import Foundation
import Observation
import PBSKit
import ProxmoxCore
import PVEKit

/// Task counts of one kind of work, as the web interface's Task Summary shows them.
public struct TaskSummaryRow: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case backup, prune, garbageCollection, sync, verify
        public var id: String { rawValue }
    }

    public var kind: Kind
    public var succeeded = 0
    public var warnings = 0
    public var failed = 0

    public var id: Kind { kind }
    public var total: Int { succeeded + warnings + failed }

    /// The category of a task type, or nil for tasks the summary leaves out. Sync jobs count as syncs, verification
    /// jobs and checks of single groups or snapshots as verifications, prune jobs as prunes, like the web interface.
    public static func kind(of type: String) -> Kind? {
        if type == "backup" { return .backup }
        if type.hasPrefix("prune") { return .prune }
        if type == "garbage_collection" { return .garbageCollection }
        if type == "sync" || type == "syncjob" { return .sync }
        if type.hasPrefix("verif") { return .verify }
        return nil
    }

    /// The task's API type to filter its list by: verification tasks are matched by prefix.
    public var typeFilter: String {
        switch kind {
        case .backup: "backup"
        case .prune: "prune"
        case .garbageCollection: "garbage_collection"
        case .sync: "sync"
        case .verify: "verif"
        }
    }
}

/// The dashboard of a backup server: history, recent tasks and the subscription. The server's status and datastores
/// come with the connection's snapshot.
@MainActor
@Observable
public final class BackupServerDashboard {
    public let connection: ServerConnection

    public private(set) var history: [RRDPoint] = []
    public private(set) var summary: [TaskSummaryRow] = TaskSummaryRow.Kind.allCases.map { TaskSummaryRow(kind: $0) }
    /// The ten tasks that took longest in the period, longest first.
    public private(set) var longestTasks: [ClusterTask] = []
    public private(set) var runningTasks: [ClusterTask] = []
    public private(set) var subscription: NodeSubscription?
    /// Set when the user may not read the server's tasks or history.
    public private(set) var tasksError: String?
    public private(set) var hasLoaded = false

    /// How far back the task summary goes; the web interface's default is 30 days.
    public var days = 30 {
        didSet {
            guard days != oldValue else { return }
            Task { await loadTasks() }
        }
    }

    public var timeframe: RRDTimeframe = .hour {
        didSet {
            guard timeframe != oldValue else { return }
            Task { await loadHistory() }
        }
    }

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    public func load() async {
        async let history: Void = loadHistory()
        async let tasks: Void = loadTasks()
        async let subscription = try? connection.send(PVE.subscription(node: PBS.node))
        _ = await (history, tasks)
        self.subscription = await subscription
        hasLoaded = true
    }

    /// Keeps the running tasks current while the screen is visible, like the web interface's 15-second refresh.
    public func keepRefreshing() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { break }
            await loadTasks()
        }
    }

    private func loadHistory() async {
        if let points = try? await connection.send(PBS.nodeRRD(timeframe: timeframe)) {
            history = points.filter(\.hasData)
        }
    }

    private func loadTasks() async {
        var filter = BackupServerTaskFilter(limit: 0)
        filter.since = Date().addingTimeInterval(-Double(days) * 86_400)
        do {
            let tasks = try await connection.send(PBS.tasks(filter))
            apply(tasks)
            tasksError = nil
        } catch is CancellationError {
        } catch {
            tasksError = error.localizedDescription
        }
    }

    func apply(_ tasks: [ClusterTask]) {
        var rows = Dictionary(uniqueKeysWithValues: TaskSummaryRow.Kind.allCases.map { ($0, TaskSummaryRow(kind: $0)) })
        for task in tasks {
            guard let kind = TaskSummaryRow.kind(of: task.type), let status = task.status else { continue }
            if status == "OK" {
                rows[kind]?.succeeded += 1
            } else if status.hasPrefix("WARNINGS") {
                rows[kind]?.warnings += 1
            } else if status != "unknown" {
                rows[kind]?.failed += 1
            }
        }
        summary = TaskSummaryRow.Kind.allCases.compactMap { rows[$0] }
        longestTasks = Array(tasks.filter { $0.endTime != nil }.sorted { duration(of: $0) > duration(of: $1) }.prefix(10))
        runningTasks = tasks.filter(\.isRunning)
    }

    public func duration(of task: ClusterTask) -> TimeInterval {
        (task.endTime ?? Date()).timeIntervalSince(task.startTime)
    }
}
