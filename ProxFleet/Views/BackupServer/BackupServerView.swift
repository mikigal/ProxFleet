import FleetCore
import PBSKit
import SwiftUI

nonisolated enum BackupServerTab: String, DetailTab {
    case dashboard, datastores, jobs, more

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "Dashboard"
        case .datastores: "Datastores"
        case .jobs: "Jobs"
        case .more: "More"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .datastores: "cylinder.split.1x2"
        case .jobs: "calendar.badge.clock"
        case .more: "ellipsis"
        }
    }
}

/// A connected Proxmox Backup Server: its dashboard, datastores and settings.
struct BackupServerView: View {
    let connection: ServerConnection
    @State private var tab: BackupServerTab = .dashboard
    /// Kept here so coming back to the tab shows the last data while it reloads.
    @State private var dashboard: BackupServerDashboard
    @State private var jobs: BackupServerJobs
    /// The server itself, for the administration screens it shares with Proxmox VE nodes.
    @State private var node: NodeDetail

    init(connection: ServerConnection) {
        self.connection = connection
        _dashboard = State(initialValue: BackupServerDashboard(connection: connection))
        _jobs = State(initialValue: BackupServerJobs(connection: connection))
        _node = State(initialValue: NodeDetail(node: PBS.node, connection: connection))
    }

    var body: some View {
        tabContent
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let error = connection.refreshError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassEffect()
                    }
                    DetailTabBar(selection: $tab)
                }
                .padding(.bottom, 6)
            }
            .task { await connection.keepRefreshing() }
            .sensoryFeedback(.selection, trigger: tab)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: ServerRoute.tasks) {
                        Label("Tasks", systemImage: "list.bullet.rectangle")
                    }
                    .badge(connection.tasks.runningTasks.count)
                    .accessibilityIdentifier("tasks")
                }
            }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .dashboard:
            BackupServerDashboardView(dashboard: dashboard, node: node)
        case .datastores:
            DatastoreListView(connection: connection)
        case .jobs:
            BackupServerJobsView(jobs: jobs)
        case .more:
            BackupServerMoreList(connection: connection, node: node)
        }
    }
}
