import FleetCore
import PVEKit
import SwiftUI

nonisolated enum ServerTab: String, DetailTab {
    case overview, storage, backup, more

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .storage: "Storage"
        case .backup: "Backup"
        case .more: "More"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .storage: "externaldrive"
        case .backup: "archivebox"
        case .more: "ellipsis"
        }
    }
}

/// A connected server: its nodes and guests, storage, backup jobs, and the datacenter settings in More.
struct ServerOverviewView: View {
    let connection: ServerConnection
    @State private var tab: ServerTab = .overview
    /// Kept here so coming back to a tab shows the last data while it reloads.
    @State private var backupJobs: BackupJobList
    @State private var storageDefinitions: DatacenterStorage
    @State private var creating: GuestKind?
    /// Set by the creation sheet; opened once the sheet is gone, as pushing while it closes is unreliable.
    @State private var newGuest: GuestReference?
    @State private var createdGuest: GuestReference?
    @State private var bulkAction: NodeBulkAction?

    init(connection: ServerConnection) {
        self.connection = connection
        _backupJobs = State(initialValue: BackupJobList(connection: connection))
        _storageDefinitions = State(initialValue: DatacenterStorage(connection: connection))
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
            }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .overview:
            ServerResourcesList(connection: connection)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Create", systemImage: "plus") {
                            Button("Virtual Machine", systemImage: "desktopcomputer") { creating = .virtualMachine }
                                .accessibilityIdentifier("create.vm")
                            Button("Container", systemImage: "shippingbox") { creating = .container }
                                .accessibilityIdentifier("create.ct")
                        }
                        .accessibilityIdentifier("create.menu")
                    }
                }
        case .storage:
            ServerStorageList(connection: connection, definitions: storageDefinitions)
        case .backup:
            BackupJobsView(list: backupJobs)
        case .more:
            ServerMoreList(connection: connection) { bulkAction = $0 }
        }
    }
}

/// The Overview tab: the cluster or standalone node, then its guests.
private struct ServerResourcesList: View {
    let connection: ServerConnection
    @State private var isWaking = false
    @State private var wakeResult: WakeOnLANResult?

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
            }
        }
        .refreshable { await connection.refresh() }
        .wakeOnLANAlert($wakeResult)
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

/// The Storage tab: every storage with its usage, disabled storages, and adding new ones. A storage's own screen
/// has its settings.
private struct ServerStorageList: View {
    let connection: ServerConnection
    let definitions: DatacenterStorage
    @State private var creating: StorageBackend?
    @State private var removing: StorageConfig?
    @State private var errorMessage: String?

    /// Disabled storages are not in the cluster's resources, so they come from the definitions.
    private var disabled: [StorageConfig] { definitions.configs?.filter(\.isDisabled) ?? [] }

    var body: some View {
        List {
            if let snapshot = connection.snapshot {
                StorageSection(connection: connection, snapshot: snapshot)
            }
            if !disabled.isEmpty {
                Section {
                    ForEach(disabled) { config in
                        NavigationLink {
                            StorageSettingsView(storage: definitions, name: config.storage)
                        } label: {
                            StorageConfigRow(config: config)
                        }
                        .accessibilityIdentifier("storageconfig.\(config.storage)")
                        .swipeActions {
                            // Not `role: .destructive`: a full swipe would hide the row, but this only asks first.
                            if definitions.canModify {
                                Button("Remove", systemImage: "trash") { removing = config }
                                    .tint(.red)
                            }
                        }
                    }
                } header: {
                    Text("Disabled")
                } footer: {
                    Text("No node uses a disabled storage. Turn it back on in its settings.")
                }
            }
        }
        .refreshable {
            async let snapshot: Void = connection.refresh()
            await definitions.load()
            await snapshot
        }
        .task { await definitions.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add Storage", systemImage: "plus") {
                    ForEach(StorageBackend.allCases) { type in
                        Button(type.title, systemImage: type.systemImage) { creating = type }
                    }
                }
                .disabled(!definitions.canModify)
                .accessibilityIdentifier("storageconfig.add")
            }
        }
        .sheet(item: $creating) { type in
            NavigationStack {
                StorageConfigEditor(storage: definitions, draft: StorageConfigDraft(type: type), digest: nil, isNew: true)
            }
        }
        .confirmationDialog("Remove \(removing?.storage ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { config in
            Button("Remove", role: .destructive) { Task { await remove(config) } }
                .accessibilityIdentifier("storageconfig.remove.confirm")
        } message: { _ in
            Text("Only the definition is removed; the data on the storage stays. Guests whose disks are on it cannot start until it is added again.")
        }
        .alert("Storage Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func remove(_ config: StorageConfig) async {
        do {
            try await definitions.delete(config.storage)
        } catch {
            errorMessage = error.localizedDescription
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
