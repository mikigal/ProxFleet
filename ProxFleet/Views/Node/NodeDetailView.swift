import FleetCore
import ProxmoxConsole
import ProxmoxCore
import PVEKit
import SwiftUI

nonisolated enum NodeTab: String, DetailTab {
    case summary, shell, updates, more

    var title: LocalizedStringKey {
        switch self {
        case .summary: "Summary"
        case .shell: "Shell"
        case .updates: "Updates"
        case .more: "More"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "chart.xyaxis.line"
        case .shell: "apple.terminal"
        case .updates: "arrow.down.circle"
        case .more: "ellipsis"
        }
    }
}

/// A node: status and history, its shell, package updates, and services, log, tasks and power in More.
struct NodeDetailView: View {
    @State private var detail: NodeDetail
    @State private var tab: NodeTab = .summary
    @State private var metric: PerformanceMetric = .cpu
    @State private var shell: TerminalConsoleModel?
    @State private var isKeyboardVisible = false

    init(node: String, connection: ServerConnection) {
        _detail = State(initialValue: NodeDetail(node: node, connection: connection))
    }

    var body: some View {
        tabContent
            .safeAreaInset(edge: .bottom) {
                // The shell needs the space while typing.
                if !(tab == .shell && isKeyboardVisible) {
                    DetailTabBar(selection: $tab)
                        .padding(.bottom, 6)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            .onDisappear { shell?.disconnect() }
            .navigationTitle(detail.node)
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .task { await detail.load() }
            .task { await detail.keepRefreshing() }
            .sensoryFeedback(.selection, trigger: tab)
    }

    private var subtitle: String {
        [String(localized: "Node"), detail.summary?.ip].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .summary:
            NodeSummaryList(detail: detail, metric: $metric)
        case .shell:
            shellContent
        case .updates:
            NodeUpdatesList(detail: detail) { openUpgradeShell() }
        case .more:
            NodeMoreList(detail: detail)
        }
    }

    @ViewBuilder
    private var shellContent: some View {
        if !detail.isOnline {
            ContentUnavailableView("Shell Unavailable", systemImage: "apple.terminal", description: Text("The node is offline."))
        } else if !detail.can("Sys.Console") {
            ContentUnavailableView("Shell Unavailable", systemImage: "lock.fill", description: Text("The shell needs the Sys.Console privilege on /nodes/\(detail.node)."))
        } else if let shell {
            TerminalConsoleView(model: shell)
        } else {
            Color.black
                .onAppear {
                    shell = TerminalConsoleModel(target: .node(detail.node), session: detail.connection.apiSession)
                }
        }
    }

    /// Replaces the shell with one that runs `apt-get dist-upgrade`, as the web interface's Upgrade button does.
    private func openUpgradeShell() {
        shell?.disconnect()
        shell = TerminalConsoleModel(target: .node(detail.node), session: detail.connection.apiSession, command: "upgrade")
        tab = .shell
    }
}

// MARK: - Summary

private struct NodeSummaryList: View {
    let detail: NodeDetail
    @Binding var metric: PerformanceMetric

    var body: some View {
        List {
            Section {
                header
            }
            if let error = detail.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if let status = detail.status {
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
            }
            Section {
                Picker("Metric", selection: $metric) {
                    ForEach(PerformanceMetric.node) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                PerformanceChart(points: detail.history, metric: metric, timeframe: detail.timeframe)
                Picker("Timeframe", selection: Bindable(detail).timeframe) {
                    ForEach(RRDTimeframe.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Performance")
            }
            if let notes = detail.options?.notes, !notes.isEmpty, let options = detail.options {
                Section("Notes") {
                    NavigationLink {
                        NodeNotesEditor(detail: detail, options: options)
                    } label: {
                        NotesText(notes: notes)
                            .font(.subheadline)
                            .lineLimit(8)
                    }
                    .accessibilityIdentifier("summary.notes")
                }
            }
            if let status = detail.status {
                Section("System") {
                    if let version = status.pveVersion {
                        LabeledContent("Proxmox VE", value: version)
                    }
                    if let kernel = status.kernel {
                        LabeledContent("Kernel", value: kernel)
                    }
                    if let model = status.cpuModel {
                        LabeledContent("CPU", value: model)
                    }
                    LabeledContent("CPUs", value: "\(status.cpuCount) (\(status.sockets) × \(status.cores))")
                    if let mode = status.bootMode {
                        LabeledContent("Boot Mode", value: mode == "efi" ? (status.secureBoot ? "EFI, Secure Boot" : "EFI") : "Legacy BIOS")
                    }
                }
            }
        }
        .refreshable {
            await detail.load()
            await detail.loadOptions()
        }
        .task { if detail.isOnline { await detail.loadOptions() } }
        .overlay {
            if !detail.hasLoaded, detail.status == nil { ProgressView() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title)
                .foregroundStyle(detail.isOnline ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusDot(color: detail.isNotResponding ? .orange : detail.isOnline ? .green : .red)
                    Text(detail.isNotResponding ? "Not Responding" : detail.isOnline ? "Online" : "Offline")
                        .font(.subheadline.weight(.semibold))
                }
                if let status = detail.status, detail.isOnline, !detail.isNotResponding {
                    Text("Up \(Format.uptime(status.uptime))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Updates

private struct NodeUpdatesList: View {
    let detail: NodeDetail
    let onUpgrade: () -> Void
    @State private var isRefreshing = false
    @State private var confirmsUpgrade = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    HStack {
                        Label("Refresh Package List", systemImage: "arrow.clockwise")
                        Spacer()
                        if isRefreshing { ProgressView() }
                    }
                }
                .disabled(isRefreshing || !detail.can("Sys.Modify"))
                .accessibilityIdentifier("updates.refresh")
            } footer: {
                Text("Runs apt update on the node. This can take a minute.")
            }
            if let updates = detail.updates {
                if updates.isEmpty {
                    Section {
                        Label("The node is up to date.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Section {
                        ForEach(updates) { update in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(update.package)
                                    .font(.body.weight(.medium))
                                Text("\(update.oldVersion ?? "–") → \(update.version)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                if let title = update.title {
                                    Text(title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("^[\(updates.count) Update](inflect: true)")
                    }
                    Section {
                        Button("Upgrade in Shell…") { confirmsUpgrade = true }
                            .disabled(!detail.can("Sys.Console"))
                            .accessibilityIdentifier("updates.upgrade")
                    } footer: {
                        Text("Opens the node's shell and runs apt-get dist-upgrade, as the web interface does. Confirm the upgrade there.")
                    }
                }
            }
            Section {
                NavigationLink("Repositories") {
                    NodeRepositoriesView(detail: detail)
                }
                .accessibilityIdentifier("updates.repositories")
                if let versions = detail.versions, !versions.isEmpty {
                    NavigationLink("Installed Versions") {
                        PackageVersionsView(versions: versions)
                    }
                }
            }
        }
        .overlay {
            if detail.updates == nil { ProgressView() }
        }
        .refreshable { errorMessage = await detail.loadUpdates() }
        .task { errorMessage = await detail.loadUpdates() }
        .alert("Upgrade \(detail.node)?", isPresented: $confirmsUpgrade) {
            Button("Cancel", role: .cancel) {}
            Button("Open Shell", action: onUpgrade)
        } message: {
            Text("The shell runs apt-get dist-upgrade and asks for confirmation before installing anything.")
        }
        .alert("Updates Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await detail.refreshPackageIndex()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PackageVersionsView: View {
    let versions: [PackageVersion]

    var body: some View {
        List(versions) { package in
            LabeledContent {
                Text(package.version)
                    .font(.footnote.monospaced())
            } label: {
                Text(package.package)
                if let kernel = package.runningKernel {
                    Text("Running kernel: \(kernel)")
                }
            }
        }
        .navigationTitle("Installed Versions")
    }
}

// MARK: - More

private struct NodeMoreList: View {
    let detail: NodeDetail
    @State private var pendingPower: NodePowerCommand?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var sentCommand: NodePowerCommand?
    @State private var bulkAction: NodeBulkAction?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    NodeSettingLoader(detail: detail, value: detail.options, load: { await detail.loadOptions() }) { NodeNotesEditor(detail: detail, options: $0) }
                } label: {
                    MoreRow(title: "Notes", systemImage: "note.text", color: .yellow, hint: detail.options.map { $0.notes.isEmpty ? String(localized: "None") : nil } ?? nil)
                }
                .disabled(!detail.isOnline)
                .accessibilityIdentifier("more.notes")
                NavigationLink {
                    NodeServicesView(detail: detail)
                } label: {
                    MoreRow(title: "Services", systemImage: "gearshape.2", color: .gray)
                }
                .accessibilityIdentifier("more.services")
                NavigationLink {
                    NodeLogView(detail: detail)
                } label: {
                    MoreRow(title: "System Log", systemImage: "doc.text.magnifyingglass", color: .indigo)
                }
                .accessibilityIdentifier("more.log")
                NavigationLink {
                    NodeTaskHistory(detail: detail)
                } label: {
                    MoreRow(title: "Task History", systemImage: "list.bullet.rectangle", color: .blue)
                }
                .accessibilityIdentifier("more.tasks")
            }
            Section("System") {
                NavigationLink {
                    NodeNetworkView(detail: detail)
                } label: {
                    MoreRow(title: "Network", systemImage: "point.3.filled.connected.trianglepath.dotted", color: .blue)
                }
                .accessibilityIdentifier("more.network")
                NavigationLink {
                    FirewallView(connection: detail.connection, scope: .node(detail.node))
                } label: {
                    MoreRow(title: "Firewall", systemImage: "flame", color: .red)
                }
                .accessibilityIdentifier("more.firewall")
                NavigationLink {
                    NodeDisksView(detail: detail)
                } label: {
                    MoreRow(title: "Disks", systemImage: "internaldrive", color: .gray)
                }
                .accessibilityIdentifier("more.disks")
                NavigationLink {
                    NodeStorageList(detail: detail)
                } label: {
                    MoreRow(title: "Storage", systemImage: "externaldrive", color: .purple)
                }
                .accessibilityIdentifier("more.storage")
                NavigationLink {
                    NodeSettingLoader(detail: detail, value: detail.dns) { NodeDNSEditor(detail: detail, dns: $0) }
                } label: {
                    MoreRow(title: "DNS", systemImage: "globe", color: .teal, hint: detail.dns?.servers.first { !$0.isEmpty })
                }
                .accessibilityIdentifier("more.dns")
                NavigationLink {
                    NodeSettingLoader(detail: detail, value: detail.hosts) { NodeHostsEditor(detail: detail, hosts: $0) }
                } label: {
                    MoreRow(title: "Hosts", systemImage: "list.bullet.indent", color: .mint)
                }
                .accessibilityIdentifier("more.hosts")
                NavigationLink {
                    NodeTimeZoneView(detail: detail)
                } label: {
                    MoreRow(title: "Time Zone", systemImage: "clock", color: .orange, hint: detail.time?.timeZone)
                }
                .accessibilityIdentifier("more.time")
                NavigationLink {
                    NodeCertificatesView(detail: detail)
                } label: {
                    MoreRow(title: "Certificates", systemImage: "checkmark.seal", color: .green)
                }
                .accessibilityIdentifier("more.certificates")
                NavigationLink {
                    NodeSettingLoader(detail: detail, value: detail.options, load: { await detail.loadOptions() }) { NodeOptionsEditor(detail: detail, options: $0) }
                } label: {
                    MoreRow(title: "Options", systemImage: "slider.horizontal.3", color: .gray, hint: detail.options?.wakeOnLANAddress.map { _ in String(localized: "Wake on LAN") })
                }
                .accessibilityIdentifier("more.options")
            }
            .disabled(!detail.isOnline)
            if detail.isOnline {
                Section {
                    Button {
                        bulkAction = .start
                    } label: {
                        Label("Bulk Start…", systemImage: "play.circle")
                    }
                    .accessibilityIdentifier("node.bulk.start")
                    Button {
                        bulkAction = .shutdown
                    } label: {
                        Label("Bulk Shutdown…", systemImage: "stop.circle")
                    }
                    .accessibilityIdentifier("node.bulk.shutdown")
                    Button {
                        bulkAction = .hibernate
                    } label: {
                        Label("Bulk Hibernate…", systemImage: "moon.circle")
                    }
                    .accessibilityIdentifier("node.bulk.hibernate")
                } header: {
                    Text("Guests")
                }
                Section {
                    Button {
                        pendingPower = .reboot
                    } label: {
                        Label("Reboot", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("node.reboot")
                    Button(role: .destructive) {
                        pendingPower = .shutdown
                    } label: {
                        Label("Shut Down", systemImage: "power")
                    }
                    .accessibilityIdentifier("node.shutdown")
                } header: {
                    Text("Power")
                } footer: {
                    if !detail.can("Sys.PowerMgmt") {
                        Text("Rebooting and shutting down need the Sys.PowerMgmt privilege on /nodes/\(detail.node).")
                    } else {
                        Text("Running guests are shut down first. Guests set to start at boot start again after a reboot.")
                    }
                }
                .disabled(!detail.can("Sys.PowerMgmt") || isWorking)
            } else {
                Section {
                    WakeOnLANButton(node: detail.node, connection: detail.connection)
                        .disabled(!detail.can("Sys.PowerMgmt"))
                } header: {
                    Text("Power")
                } footer: {
                    Text("Another node of the cluster sends a magic packet to the MAC address set in this node's options.")
                }
            }
        }
        .task {
            await detail.loadSystemSettings()
            await detail.loadOptions()
        }
        .sheet(item: $bulkAction) { action in
            NavigationStack {
                NodeBulkActionView(detail: detail, action: action)
            }
        }
        .alert(pendingPower == .shutdown ? "Shut down \(detail.node)?" : "Reboot \(detail.node)?", isPresented: Binding(get: { pendingPower != nil }, set: { if !$0 { pendingPower = nil } }), presenting: pendingPower) { command in
            Button("Cancel", role: .cancel) {}
            Button(command == .shutdown ? "Shut Down" : "Reboot", role: .destructive) { Task { await power(command) } }
                .accessibilityIdentifier("node.power.confirm")
        } message: { command in
            Text(command == .shutdown
                ? "All guests on the node stop. Starting the node again needs physical or out-of-band access."
                : "All guests on the node stop while it restarts.")
        }
        .alert("Power Action Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(sentCommand == .shutdown ? "Shutting Down" : "Rebooting", isPresented: Binding(get: { sentCommand != nil }, set: { if !$0 { sentCommand = nil } })) {
            Button("OK") {}
        } message: {
            Text("\(detail.node) received the command. It is unreachable until it is back.")
        }
    }

    private func power(_ command: NodePowerCommand) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await detail.power(command)
            sentCommand = command
            await detail.connection.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Services, log and tasks

private struct NodeServicesView: View {
    let detail: NodeDetail
    @State private var selected: NodeService?
    @State private var working: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let services = detail.services {
                ForEach(services) { service in
                    Button {
                        selected = service
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                    .foregroundStyle(.primary)
                                Text(service.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if working == service.name {
                                ProgressView()
                            } else {
                                Text(service.isRunning ? "Running" : service.state.capitalized)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background((service.isRunning ? Color.green : Color.secondary).opacity(0.15), in: .capsule)
                                    .foregroundStyle(service.isRunning ? .green : .secondary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(working != nil || !detail.can("Sys.Modify"))
                    .accessibilityIdentifier("service.\(service.name)")
                }
            }
        }
        .overlay {
            if detail.services == nil { ProgressView() }
        }
        .navigationTitle("Services")
        .refreshable { errorMessage = await detail.loadServices() }
        .task { errorMessage = await detail.loadServices() }
        .confirmationDialog(selected?.name ?? "", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible, presenting: selected) { service in
            ForEach(ServiceAction.available(for: service)) { action in
                Button(action.title, role: action == .stop ? .destructive : nil) {
                    Task { await perform(action, on: service) }
                }
            }
        } message: { service in
            if service.isNeededForAccess {
                Text("This app and the web interface reach the node through \(service.name). Stopping it cuts off access until it is started again on the node itself.")
            } else {
                Text(service.description)
            }
        }
        .alert("Service Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func perform(_ action: ServiceAction, on service: NodeService) async {
        working = service.name
        defer { working = nil }
        do {
            try await detail.perform(action, on: service)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension ServiceAction {
    var title: LocalizedStringKey {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        case .reload: "Reload"
        }
    }
}

/// The latest entries of the node's system journal, newest at the bottom.
private struct NodeLogView: View {
    let detail: NodeDetail
    @State private var search = ""
    @State private var errorMessage: String?

    private var lines: [String] {
        let all = detail.journal ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .id(index)
                }
            }
            .listStyle(.plain)
            .onChange(of: detail.journal) {
                proxy.scrollTo(lines.count - 1, anchor: .bottom)
            }
        }
        .overlay {
            if let errorMessage, detail.journal == nil {
                ContentUnavailableView("Cannot Load the Log", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if detail.journal == nil {
                ProgressView()
            } else if lines.isEmpty, !search.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search)
        .navigationTitle("System Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { errorMessage = await detail.loadJournal() }
                }
            }
        }
        .task { errorMessage = await detail.loadJournal() }
    }
}

private struct NodeTaskHistory: View {
    let detail: NodeDetail
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(detail.tasks ?? []) { task in
                NavigationLink(value: ServerRoute.task(node: task.node, upid: task.upid)) {
                    ClusterTaskRow(task: task, showsGuest: true)
                }
            }
        }
        .overlay {
            if let errorMessage, detail.tasks == nil {
                ContentUnavailableView("Cannot Load Tasks", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if detail.tasks == nil {
                ProgressView()
            } else if detail.tasks?.isEmpty == true {
                ContentUnavailableView("No Tasks", systemImage: "list.bullet.rectangle")
            }
        }
        .navigationTitle("Task History")
        .refreshable { errorMessage = await detail.loadTasks() }
        .task { errorMessage = await detail.loadTasks() }
    }
}

/// The storages available on this node.
private struct NodeStorageList: View {
    let detail: NodeDetail

    var body: some View {
        List {
            if let snapshot = detail.connection.snapshot {
                StorageSection(connection: detail.connection, snapshot: snapshot, node: detail.node)
            }
        }
        .overlay {
            if detail.connection.snapshot?.storages.contains(where: { $0.node == detail.node }) != true {
                ContentUnavailableView("No Storage", systemImage: "externaldrive")
            }
        }
        .navigationTitle("Storage")
        .refreshable { await detail.connection.refresh() }
    }
}
