import FleetCore
import PVEKit
import SwiftUI

/// The More tab of a server: datacenter settings, the cluster log, bulk actions and signing out.
struct ServerMoreList: View {
    let connection: ServerConnection
    let onBulkAction: (NodeBulkAction) -> Void

    private var nodes: [NodeSummary] { connection.snapshot?.nodes ?? [] }

    var body: some View {
        List {
            if nodes.count > 1 {
                Section {
                    NavigationLink {
                        ReplicationJobsView(connection: connection, scope: .datacenter)
                    } label: {
                        MoreRow(title: "Replication", systemImage: "arrow.triangle.2.circlepath", color: .cyan)
                    }
                    .accessibilityIdentifier("datacenter.replication")
                    NavigationLink {
                        HAView(connection: connection)
                    } label: {
                        MoreRow(title: "High Availability", systemImage: "shield.lefthalf.filled", color: .green)
                    }
                    .accessibilityIdentifier("datacenter.ha")
                    if let local = (nodes.first(where: \.isLocal) ?? nodes.first(where: \.isOnline))?.name {
                        NavigationLink {
                            CephView(connection: connection, node: local)
                        } label: {
                            MoreRow(title: "Ceph", systemImage: "circle.hexagongrid", color: .red)
                        }
                        .accessibilityIdentifier("datacenter.ceph")
                    }
                }
            }
            Section {
                NavigationLink {
                    AccessHubView(connection: connection)
                } label: {
                    MoreRow(title: "Users & Permissions", systemImage: "person.badge.key", color: .blue)
                }
                .accessibilityIdentifier("datacenter.access")
                NavigationLink {
                    PoolsView(connection: connection)
                } label: {
                    MoreRow(title: "Pools", systemImage: "square.stack.3d.down.right", color: .orange)
                }
                .accessibilityIdentifier("datacenter.pools")
                NavigationLink {
                    FirewallView(connection: connection, scope: .datacenter)
                } label: {
                    MoreRow(title: "Firewall", systemImage: "flame", color: .red)
                }
                .accessibilityIdentifier("datacenter.firewall")
                NavigationLink {
                    SDNView(connection: connection)
                } label: {
                    MoreRow(title: "SDN", systemImage: "point.3.connected.trianglepath.dotted", color: .green)
                }
                .accessibilityIdentifier("datacenter.sdn")
                NavigationLink {
                    ResourceMappingsView(connection: connection)
                } label: {
                    MoreRow(title: "Resource Mappings", systemImage: "cpu", color: .indigo)
                }
                .accessibilityIdentifier("datacenter.mappings")
            }
            Section {
                if connection.supports(.notifications) {
                    NavigationLink {
                        NotificationsView(connection: connection)
                    } label: {
                        MoreRow(title: "Notifications", systemImage: "bell", color: .pink)
                    }
                    .accessibilityIdentifier("datacenter.notifications")
                }
                NavigationLink {
                    MetricServersView(connection: connection)
                } label: {
                    MoreRow(title: "Metric Servers", systemImage: "chart.xyaxis.line", color: .mint)
                }
                .accessibilityIdentifier("datacenter.metrics")
                NavigationLink {
                    DatacenterOptionsView(connection: connection)
                } label: {
                    MoreRow(title: "Options", systemImage: "gearshape", color: .gray)
                }
                .accessibilityIdentifier("datacenter.options")
                NavigationLink {
                    ClusterLogView(connection: connection)
                } label: {
                    MoreRow(title: "Cluster Log", systemImage: "doc.text.magnifyingglass", color: .brown)
                }
                .accessibilityIdentifier("cluster.log")
            }
            // Older releases have bulk actions per node only.
            if connection.supports(.datacenterBulkActions) {
                Section("Bulk Actions") {
                    bulkButton(.start, title: "Bulk Start", systemImage: "play.fill", color: .green)
                    bulkButton(.shutdown, title: "Bulk Shutdown", systemImage: "power", color: .red)
                    bulkButton(.hibernate, title: "Bulk Hibernate", systemImage: "moon.zzz.fill", color: .indigo)
                    if nodes.count > 1 {
                        bulkButton(.migrate, title: "Bulk Migrate", systemImage: "arrow.left.arrow.right", color: .purple)
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    Task { await connection.signOut() }
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityIdentifier("signOut")
            }
        }
    }

    private func bulkButton(_ action: NodeBulkAction, title: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        Button {
            onBulkAction(action)
        } label: {
            MoreRow(title: title, systemImage: systemImage, color: color)
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("bulk.\(action.rawValue)")
    }
}
