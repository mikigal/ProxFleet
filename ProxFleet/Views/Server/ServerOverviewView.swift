import FleetCore
import PVEKit
import SwiftUI

struct ServerOverviewView: View {
    let connection: ServerConnection
    @State private var creating: GuestKind?
    /// Set by the creation sheet; opened once the sheet is gone, as pushing while it closes is unreliable.
    @State private var newGuest: GuestReference?
    @State private var createdGuest: GuestReference?
    @State private var isWaking = false
    @State private var wakeResult: WakeOnLANResult?
    @State private var bulkAction: NodeBulkAction?
    @State private var showsLog = false

    var body: some View {
        List {
            if let snapshot = connection.snapshot {
                // A standalone node is shown as the server itself, without cluster information.
                if snapshot.topology == .standalone, let node = snapshot.nodes.first {
                    Section {
                        NavigationLink(value: ServerRoute.node(node.name)) {
                            NodeHeader(node: node, snapshot: snapshot)
                        }
                        .accessibilityIdentifier("node.\(node.name)")
                    }
                } else {
                    Section {
                        ClusterHeader(snapshot: snapshot)
                    }
                    Section("Nodes") {
                        ForEach(snapshot.nodes) { node in
                            NavigationLink(value: ServerRoute.node(node.name)) {
                                NodeRow(node: node)
                            }
                            .swipeActions {
                                if !node.isOnline {
                                    Button("Wake", systemImage: "power.circle") {
                                        Task { wakeResult = await WakeOnLANResult.send(to: node.name, connection: connection, isSending: $isWaking) }
                                    }
                                    .tint(.green)
                                    .disabled(isWaking)
                                }
                            }
                            .accessibilityIdentifier("node.\(node.name)")
                        }
                    }
                }
                let showsNode = snapshot.nodes.count > 1
                guestSection("Virtual Machines", guests: snapshot.virtualMachines.filter { !$0.isTemplate }, showsNode: showsNode)
                guestSection("Containers", guests: snapshot.containers.filter { !$0.isTemplate }, showsNode: showsNode)
                guestSection("Templates", guests: snapshot.guests.filter(\.isTemplate), showsNode: showsNode)
                StorageSection(connection: connection, snapshot: snapshot)
                Section("Datacenter") {
                    NavigationLink {
                        DatacenterStorageView(connection: connection)
                    } label: {
                        MoreRow(title: "Storage", systemImage: "externaldrive.badge.plus", color: .purple)
                    }
                    .accessibilityIdentifier("datacenter.storage")
                    NavigationLink {
                        BackupJobsView(connection: connection)
                    } label: {
                        MoreRow(title: "Backup Jobs", systemImage: "calendar.badge.clock", color: .teal)
                    }
                    .accessibilityIdentifier("datacenter.backupjobs")
                    NavigationLink {
                        PoolsView(connection: connection)
                    } label: {
                        MoreRow(title: "Pools", systemImage: "square.stack.3d.down.right", color: .orange)
                    }
                    .accessibilityIdentifier("datacenter.pools")
                    NavigationLink {
                        AccessHubView(connection: connection)
                    } label: {
                        MoreRow(title: "Users & Permissions", systemImage: "person.badge.key", color: .blue)
                    }
                    .accessibilityIdentifier("datacenter.access")
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
                    NavigationLink {
                        NotificationsView(connection: connection)
                    } label: {
                        MoreRow(title: "Notifications", systemImage: "bell", color: .pink)
                    }
                    .accessibilityIdentifier("datacenter.notifications")
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
                }
            }
        }
        .refreshable { await connection.refresh() }
        .wakeOnLANAlert($wakeResult)
        .task { await connection.keepRefreshing() }
        .safeAreaInset(edge: .bottom) {
            if let error = connection.refreshError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect()
                    .padding(.bottom, 8)
            }
        }
        .sheet(item: $creating, onDismiss: {
            createdGuest = newGuest
            newGuest = nil
        }) { kind in
            NavigationStack {
                switch kind {
                case .virtualMachine:
                    CreateVMView(connection: connection) { newGuest = $0 }
                case .container:
                    CreateContainerView(connection: connection) { newGuest = $0 }
                }
            }
            .serverDestinations(connection)
        }
        .sheet(item: $bulkAction) { action in
            NavigationStack {
                NodeBulkActionView(connection: connection, node: nil, action: action) { draft throws(ConfigUpdateError) in
                    try await connection.runBulkAction(draft)
                }
            }
        }
        .navigationDestination(isPresented: $showsLog) {
            ClusterLogView(connection: connection)
        }
        .navigationDestination(item: $createdGuest) { reference in
            GuestDetailView(reference: reference, connection: connection)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: ServerRoute.tasks) {
                    Label("Tasks", systemImage: "list.bullet.rectangle")
                }
                .badge(connection.tasks.runningTasks.count)
                .accessibilityIdentifier("tasks")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("Create", systemImage: "plus") {
                    Button("Virtual Machine", systemImage: "desktopcomputer") { creating = .virtualMachine }
                        .accessibilityIdentifier("create.vm")
                    Button("Container", systemImage: "shippingbox") { creating = .container }
                        .accessibilityIdentifier("create.ct")
                }
                .accessibilityIdentifier("create.menu")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") {
                    Section("Bulk Actions") {
                        Button("Bulk Start", systemImage: "play") { bulkAction = .start }
                            .accessibilityIdentifier("bulk.start")
                        Button("Bulk Shutdown", systemImage: "power") { bulkAction = .shutdown }
                            .accessibilityIdentifier("bulk.shutdown")
                        Button("Bulk Hibernate", systemImage: "moon.zzz") { bulkAction = .hibernate }
                            .accessibilityIdentifier("bulk.hibernate")
                    }
                    Button("Cluster Log", systemImage: "doc.text.magnifyingglass") { showsLog = true }
                        .accessibilityIdentifier("cluster.log")
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                        Task { await connection.signOut() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func guestSection(_ title: LocalizedStringKey, guests: [GuestSummary], showsNode: Bool) -> some View {
        if !guests.isEmpty {
            Section(title) {
                ForEach(guests) { guest in
                    NavigationLink(value: ServerRoute.guest(GuestReference(guest))) {
                        GuestRow(guest: guest, showsNode: showsNode)
                    }
                    .accessibilityIdentifier("guest.\(guest.vmid)")
                }
            }
        }
    }
}

private struct ClusterHeader: View {
    let snapshot: ClusterSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Cluster \(snapshot.clusterName ?? "")", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                Spacer()
                if case .cluster(_, let quorate) = snapshot.topology {
                    Text(quorate ? "Quorate" : "No Quorum")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((quorate ? Color.green : Color.red).opacity(0.15), in: .capsule)
                        .foregroundStyle(quorate ? .green : .red)
                }
            }
            HStack(spacing: 0) {
                Metric(value: "\(snapshot.nodes.filter(\.isOnline).count)/\(snapshot.nodes.count)", label: "Nodes online")
                Metric(value: runningCount(snapshot.virtualMachines), label: "VMs running")
                Metric(value: runningCount(snapshot.containers), label: "CTs running")
            }
        }
        .padding(.vertical, 4)
    }

}

/// Header for a standalone node: the node's own status and usage, plus guest counts.
private struct NodeHeader: View {
    let node: NodeSummary
    let snapshot: ClusterSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(node.name)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "server.rack")
                }
                .font(.headline)
                .layoutPriority(1)
                if let ip = node.ip {
                    Text(ip)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if node.isOnline {
                    Text("Up \(Format.uptime(node.uptime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 16) {
                UsageGauge(title: "CPU", fraction: node.cpuUsage, detail: Format.cores(node.cpuCount))
                UsageGauge(title: "Memory", fraction: Format.fraction(node.memoryUsed, of: node.memoryTotal), detail: Format.bytes(node.memoryTotal))
            }
            HStack(spacing: 0) {
                Metric(value: runningCount(snapshot.virtualMachines), label: "VMs running")
                Metric(value: runningCount(snapshot.containers), label: "CTs running")
            }
        }
        .padding(.vertical, 4)
    }
}

private func runningCount(_ guests: [GuestSummary]) -> String {
    let real = guests.filter { !$0.isTemplate }
    return "\(real.filter { $0.state == .running }.count)/\(real.count)"
}

private struct Metric: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NodeRow: View {
    let node: NodeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusDot(color: node.isOnline ? .green : .red)
                Text(node.name)
                    .font(.headline)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let ip = node.ip {
                    Text(ip)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if node.isOnline {
                    Text("Up \(Format.uptime(node.uptime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Offline")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            if node.isOnline {
                HStack(spacing: 16) {
                    UsageGauge(title: "CPU", fraction: node.cpuUsage, detail: Format.cores(node.cpuCount))
                    UsageGauge(title: "Memory", fraction: Format.fraction(node.memoryUsed, of: node.memoryTotal), detail: Format.bytes(node.memoryTotal))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct GuestRow: View {
    let guest: GuestSummary
    let showsNode: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: guest.kind == .virtualMachine ? "desktopcomputer" : "shippingbox")
                .font(.title3)
                .foregroundStyle(guest.state == .running ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(guest.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 4) {
                    Text(verbatim: "\(guest.vmid)")
                        .monospacedDigit()
                    if showsNode {
                        Text(verbatim: "·")
                        Text(guest.node)
                    }
                    ForEach(guest.tags, id: \.self) { tag in
                        TagChip(tag: tag)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if guest.state == .running {
                Text(guest.cpuUsage, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            PowerStateBadge(state: guest.state)
        }
        .accessibilityElement(children: .combine)
    }
}
