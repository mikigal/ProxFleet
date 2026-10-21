import FleetCore
import ProxmoxConsole
import ProxmoxCore
import PVEKit
import SwiftUI

struct GuestDetailView: View {
    @State private var detail: GuestDetail
    @State private var pendingAction: PowerAction?
    @State private var metric: PerformanceMetric = .cpu
    @State private var tab: GuestTab = .summary
    @State private var terminal: TerminalConsoleModel?
    @State private var vnc: VNCConsoleModel?
    @State private var isKeyboardVisible = false
    @State private var showsClone = false
    @State private var showsDelete = false
    /// Set by the clone sheet; opened once the sheet is gone, as pushing while it closes is unreliable.
    @State private var newClone: GuestReference?
    @State private var openedClone: GuestReference?
    @State private var wasDeleted = false
    @Environment(\.dismiss) private var dismiss

    init(reference: GuestReference, connection: ServerConnection) {
        _detail = State(initialValue: GuestDetail(reference: reference, connection: connection))
    }

    private var kind: GuestKind { detail.reference.kind }

    var body: some View {
        tabContent
            .safeAreaInset(edge: .bottom) {
                // The console needs the space while typing.
                if !(tab == .console && isKeyboardVisible) {
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
            .onDisappear {
                terminal?.disconnect()
                vnc?.disconnect()
            }
            .navigationTitle(detail.name)
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await detail.refresh() }
            .task { await detail.load() }
            .task { await detail.keepRefreshing() }
            .sensoryFeedback(.selection, trigger: tab)
            .sensoryFeedback(trigger: detail.runningTask?.id) { old, new in
                old != nil && new == nil ? (detail.actionError == nil ? .success : .error) : nil
            }
            .alert(
                pendingAction?.confirmationTitle(detail.name) ?? "",
                isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                presenting: pendingAction
            ) { action in
                Button("Cancel", role: .cancel) {}
                Button(action.title, role: action.isForceful ? .destructive : nil) {
                    Task { await detail.perform(action) }
                }
                .accessibilityIdentifier("confirm.\(action.rawValue)")
            } message: { action in
                Text(action.confirmationMessage)
            }
            .sheet(isPresented: $showsClone, onDismiss: {
                openedClone = newClone
                newClone = nil
            }) {
                NavigationStack {
                    CloneView(detail: detail) { newClone = $0 }
                }
                .serverDestinations(detail.connection)
            }
            .sheet(isPresented: $showsDelete, onDismiss: {
                if wasDeleted { dismiss() }
            }) {
                NavigationStack {
                    DeleteGuestView(detail: detail) { wasDeleted = true }
                }
            }
            .navigationDestination(item: $openedClone) { reference in
                GuestDetailView(reference: reference, connection: detail.connection)
            }
            .alert(
                "Action Failed",
                isPresented: Binding(get: { detail.actionError != nil }, set: { if !$0 { detail.dismissActionError() } }),
                presenting: detail.actionError
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
    }

    private var subtitle: String {
        let kind = kind == .virtualMachine ? String(localized: "VM") : String(localized: "CT")
        return "\(kind) \(detail.reference.vmid) · \(detail.reference.node)"
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .summary:
            List {
                Section {
                    GuestHeader(detail: detail)
                    if detail.isTemplate, detail.can("VM.Clone") {
                        Button {
                            showsClone = true
                        } label: {
                            Label("Clone Template", systemImage: "plus.square.on.square")
                                .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 14))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .accessibilityIdentifier("template.clone")
                    }
                    if !detail.availableActions.isEmpty {
                        PowerControls(actions: detail.availableActions, isBusy: detail.runningTask != nil) { action in
                            if action.needsConfirmation {
                                pendingAction = action
                            } else {
                                Task { await detail.perform(action) }
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                }
                if !detail.pendingChanges.isEmpty {
                    Section {
                        Button {
                            tab = .hardware
                        } label: {
                            Label("^[\(detail.pendingChanges.count) change](inflect: true) will apply at the next start", systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.orange)
                        }
                        .accessibilityIdentifier("pendingHint")
                    }
                }
                errorSection
                summaryContent
            }
            .overlay {
                if !detail.hasLoaded && detail.status == nil {
                    ProgressView()
                }
            }
        case .console:
            consoleContent
        case .hardware:
            List {
                errorSection
                if let config = detail.config {
                    GuestHardwareSections(detail: detail, config: config)
                } else {
                    loadingRow
                }
                networkSection
            }
        case .more:
            GuestMoreList(detail: detail, onClone: { showsClone = true }, onDelete: { showsDelete = true })
        }
    }

    @ViewBuilder
    private var consoleContent: some View {
        if detail.powerState != .running {
            ContentUnavailableView(
                "Console Unavailable",
                systemImage: "terminal",
                description: Text(detail.powerState == .paused ? "Resume the guest to use its console." : "Start the guest to use its console.")
            )
        } else if kind == .container {
            if let terminal {
                TerminalConsoleView(model: terminal)
            } else {
                Color.black
                    .onAppear {
                        terminal = TerminalConsoleModel(target: .container(detail.reference), session: detail.connection.apiSession)
                    }
            }
        } else if let vnc {
            VNCConsoleView(model: vnc)
        } else {
            Color.black
                .onAppear {
                    vnc = VNCConsoleModel(guest: detail.reference, session: detail.connection.apiSession)
                }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = detail.loadError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if let status = detail.status, status.powerState != .stopped {
            usageSection(status)
        }

        Section {
            Picker("Metric", selection: $metric) {
                ForEach(PerformanceMetric.guest) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            PerformanceChart(points: detail.history, metric: metric, timeframe: detail.timeframe)
            Picker("Timeframe", selection: $detail.timeframe) {
                ForEach(RRDTimeframe.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Performance")
        }
    }

    private var loadingRow: some View {
        Section {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
    }

    private func usageSection(_ status: GuestStatus) -> some View {
        Section("Usage") {
            HStack(spacing: 16) {
                UsageGauge(title: "CPU", fraction: status.cpuUsage, detail: Format.cores(status.cpuCount))
                UsageGauge(title: "Memory", fraction: Format.fraction(status.memoryUsed, of: status.memoryTotal), detail: "\(Format.bytes(status.memoryUsed)) of \(Format.bytes(status.memoryTotal))")
            }
            if kind == .container {
                HStack(spacing: 16) {
                    UsageGauge(title: "Root Disk", fraction: Format.fraction(status.diskUsed, of: status.diskTotal), detail: "\(Format.bytes(status.diskUsed)) of \(Format.bytes(status.diskTotal))")
                    if let swap = status.swapTotal, swap > 0 {
                        UsageGauge(title: "Swap", fraction: Format.fraction(status.swapUsed ?? 0, of: swap), detail: Format.bytes(swap))
                    }
                }
            }
            LabeledContent("Network In / Out", value: "\(Format.bytes(status.networkIn)) / \(Format.bytes(status.networkOut))")
            LabeledContent("Disk Read / Write", value: "\(Format.bytes(status.diskRead)) / \(Format.bytes(status.diskWrite))")
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        Section("IP Addresses") {
            if let interfaces = detail.interfaces, !interfaces.isEmpty {
                ForEach(interfaces) { interface in
                    LabeledContent(interface.name) {
                        VStack(alignment: .trailing) {
                            ForEach(interface.addresses, id: \.self) { address in
                                Text(address)
                                    .monospacedDigit()
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            } else {
                Text(addressesUnavailableReason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var addressesUnavailableReason: LocalizedStringKey {
        if detail.powerState != .running { return "Available while the guest is running." }
        if kind == .virtualMachine {
            return detail.config?.agentEnabled == false
                ? "Enable the QEMU guest agent in the VM options and install it in the guest to see IP addresses."
                : "The QEMU guest agent is not running in the guest."
        }
        return "The container reports no addresses."
    }
}

/// Status at a glance. Name and ID are in the navigation title and subtitle.
private struct GuestHeader: View {
    let detail: GuestDetail

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: detail.reference.kind == .virtualMachine ? "desktopcomputer" : "shippingbox.fill")
                .font(.system(size: 34))
                .foregroundStyle(detail.powerState == .running ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PowerStateBadge(state: detail.powerState)
                    if detail.isTemplate {
                        TagChip(tag: String(localized: "Template"))
                    }
                    if let task = detail.runningTask {
                        ProgressView()
                            .controlSize(.small)
                        Text(task.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("runningTask")
                    } else if let status = detail.status, status.powerState == .running {
                        Text("Up \(Format.uptime(status.uptime))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                let tags = detail.status?.tags ?? detail.summary?.tags ?? []
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { TagChip(tag: $0) }
                    }
                }
                if let lock = detail.status?.lock {
                    Label("Locked: \(lock)", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

nonisolated enum GuestTab: String, DetailTab {
    case summary, console, hardware, more

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .summary: "Summary"
        case .console: "Console"
        case .hardware: "Hardware"
        case .more: "More"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "chart.xyaxis.line"
        case .console: "terminal"
        case .hardware: "cpu"
        case .more: "ellipsis"
        }
    }
}

/// Sections that do not fit in the bar, as a Settings-style list.
private struct GuestMoreList: View {
    let detail: GuestDetail
    let onClone: () -> Void
    let onDelete: () -> Void
    @State private var confirmsTemplate = false
    @State private var isConverting = false
    @State private var errorMessage: String?

    private var kindName: String { detail.reference.kind == .virtualMachine ? String(localized: "VM") : String(localized: "CT") }
    private var isStopped: Bool { detail.powerState == .stopped }

    var body: some View {
        List {
            Section {
                if let config = detail.config {
                    NavigationLink {
                        OptionsEditor(detail: detail, config: config)
                    } label: {
                        MoreRow(title: "Options", systemImage: "slider.horizontal.3", color: .gray, hint: config.startsOnBoot ? String(localized: "Starts at boot") : nil)
                    }
                    .accessibilityIdentifier("more.options")
                    NavigationLink {
                        NotesEditor(detail: detail, config: config)
                    } label: {
                        MoreRow(title: "Notes", systemImage: "note.text", color: .yellow, hint: config.description?.isEmpty == false ? nil : String(localized: "None"))
                    }
                    .accessibilityIdentifier("more.notes")
                    if detail.reference.kind == .virtualMachine {
                        NavigationLink {
                            CloudInitEditor(detail: detail, config: config)
                        } label: {
                            MoreRow(title: "Cloud-Init", systemImage: "cloud", color: .cyan, hint: config.cloudInitDrive == nil ? String(localized: "No drive") : nil)
                        }
                        .accessibilityIdentifier("more.cloudinit")
                    }
                }
                NavigationLink {
                    AllSettingsView(detail: detail)
                } label: {
                    MoreRow(title: "All Settings", systemImage: "list.bullet.rectangle.portrait", color: .indigo, hint: nil)
                }
                .accessibilityIdentifier("more.allSettings")
                NavigationLink {
                    GuestTaskHistory(tasks: detail.recentTasks)
                } label: {
                    MoreRow(title: "Task History", systemImage: "list.bullet.rectangle", color: .blue, hint: detail.recentTasks.isEmpty ? nil : "\(detail.recentTasks.count)")
                }
                .accessibilityIdentifier("more.tasks")
            }
            Section {
                NavigationLink {
                    SnapshotsView(detail: detail)
                } label: {
                    MoreRow(title: "Snapshots", systemImage: "camera", color: .green, hint: nil)
                }
                .accessibilityIdentifier("more.snapshots")
                NavigationLink {
                    BackupsView(detail: detail)
                } label: {
                    MoreRow(title: "Backups", systemImage: "archivebox", color: .brown, hint: nil)
                }
                .accessibilityIdentifier("more.backups")
                Button(action: onClone) {
                    MoreRow(title: "Clone", systemImage: "plus.square.on.square", color: .teal, hint: nil)
                }
                .foregroundStyle(.primary)
                .disabled(!detail.can("VM.Clone"))
                .accessibilityIdentifier("more.clone")
                if !detail.isTemplate {
                    Button {
                        confirmsTemplate = true
                    } label: {
                        MoreRow(title: "Convert to Template", systemImage: "doc.on.doc", color: .orange, hint: isConverting ? String(localized: "Converting…") : isStopped ? nil : String(localized: "Stop first"))
                    }
                    .foregroundStyle(.primary)
                    .disabled(!isStopped || !detail.can("VM.Allocate") || isConverting)
                    .accessibilityIdentifier("more.template")
                }
            } footer: {
                if !detail.isTemplate {
                    Text("Templates cannot be started; clone them to create new guests, also as quick linked clones.")
                }
            }
            Section {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete \(kindName)", systemImage: "trash")
                }
                .disabled(!detail.can("VM.Allocate"))
                .accessibilityIdentifier("more.delete")
            } footer: {
                if !detail.can("VM.Allocate") {
                    Text("Converting and deleting need the VM.Allocate privilege on /vms/\(String(detail.reference.vmid)).")
                }
            }
        }
        .alert("Convert \(detail.name) to a template?", isPresented: $confirmsTemplate) {
            Button("Cancel", role: .cancel) {}
            Button("Convert") { Task { await convert() } }
                .accessibilityIdentifier("template.confirm")
        } message: {
            Text("A template cannot be started or turned back into a normal guest. Clone it to create new guests.")
        }
        .alert("Conversion Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func convert() async {
        isConverting = true
        defer { isConverting = false }
        do {
            try await detail.convertToTemplate()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MoreRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color
    let hint: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: .rect(cornerRadius: 8))
            Text(title)
            Spacer()
            if let hint {
                Text(hint)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct GuestTaskHistory: View {
    let tasks: [ClusterTask]

    var body: some View {
        List {
            ForEach(tasks) { task in
                NavigationLink(value: ServerRoute.task(node: task.node, upid: task.upid)) {
                    ClusterTaskRow(task: task, showsGuest: false)
                }
            }
        }
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "list.bullet.rectangle")
            }
        }
        .navigationTitle("Task History")
    }
}

/// Hardware of a guest. Rows open editors when the user may change them; pending changes are marked.
private struct GuestHardwareSections: View {
    let detail: GuestDetail
    let config: GuestConfig

    private var kind: GuestKind { detail.reference.kind }
    private var isVM: Bool { kind == .virtualMachine }

    var body: some View {
        if !detail.pendingChanges.isEmpty {
            PendingChangesSection(detail: detail)
        }

        Section("System") {
            editable(privilege: "VM.Config.CPU") {
                CPUEditor(detail: detail, config: config)
            } label: {
                LabeledContent("Processor") {
                    VStack(alignment: .trailing) {
                        Text(cores)
                        if let type = config.cpuType {
                            Text(type).font(.caption).foregroundStyle(.secondary)
                        }
                        pendingLabel("cores", "sockets", "cpu", "vcpus", "cpulimit", "cpuunits", "affinity", "numa")
                    }
                }
            }
            .accessibilityIdentifier("hardware.cpu")
            editable(privilege: "VM.Config.Memory") {
                MemoryEditor(detail: detail, config: config)
            } label: {
                LabeledContent("Memory") {
                    VStack(alignment: .trailing) {
                        Text(config.memoryMiB.map { Format.bytes(Int64($0) * 1_048_576) } ?? "—")
                        if isVM, let balloon = config.balloonMiB {
                            Text(balloon == 0 ? String(localized: "Ballooning off") : String(localized: "Minimum \(Format.bytes(Int64(balloon) * 1_048_576))"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !isVM, let swap = config.swapMiB {
                            Text("Swap \(Format.bytes(Int64(swap) * 1_048_576))").font(.caption).foregroundStyle(.secondary)
                        }
                        pendingLabel("memory", "balloon", "swap", "shares")
                    }
                }
            }
            .accessibilityIdentifier("hardware.memory")
            if isVM {
                editable(privilege: "VM.Config.HWType") {
                    VMSystemEditor(detail: detail, config: config)
                } label: {
                    LabeledContent("Firmware") {
                        VStack(alignment: .trailing) {
                            Text(config.bios == "ovmf" ? "OVMF (UEFI)" : "SeaBIOS")
                            Text([config.machine ?? "i440fx", config["scsihw"]].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            pendingLabel("bios", "machine", "scsihw", "vga")
                        }
                    }
                }
            }
        }

        let disks = config.disks
        Section(isVM ? "Disks and Drives" : "Volumes") {
            ForEach(disks) { disk in
                editable(privilege: disk.isCDROM ? "VM.Config.CDROM" : "VM.Config.Disk") {
                    if disk.isCDROM {
                        CDROMEditor(detail: detail, config: config, drive: disk)
                    } else {
                        DiskEditor(detail: detail, config: config, disk: disk)
                    }
                } label: {
                    HardwareRow(
                        systemImage: disk.isCDROM ? "opticaldisc" : disk.isUnused ? "externaldrive.badge.xmark" : "internaldrive",
                        title: disk.isUnused ? "\(disk.key) (\(String(localized: "unused")))" : disk.key,
                        value: disk.isCDROM && disk.volume == "none" ? String(localized: "No disc") : disk.mountPoint.map { "\(disk.volume) → \($0)" } ?? disk.volume,
                        detail: disk.size,
                        pending: detail.pendingChange(for: disk.key) != nil
                    )
                }
                .accessibilityIdentifier("hardware.\(disk.key)")
            }
            if isVM, detail.can("VM.Config.Disk") {
                NavigationLink {
                    AddDiskEditor(detail: detail, config: config)
                } label: {
                    Label("Add Hard Disk", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("hardware.addDisk")
            }
            if !isVM, detail.can("VM.Config.Disk") {
                NavigationLink {
                    AddMountPointEditor(detail: detail, config: config)
                } label: {
                    Label("Add Mount Point", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("hardware.addMountPoint")
            }
            if isVM, detail.can("VM.Config.CDROM") {
                NavigationLink {
                    CDROMEditor(detail: detail, config: config, drive: nil)
                } label: {
                    Label("Add CD/DVD Drive", systemImage: "plus.circle")
                }
            }
        }

        let networks = config.networks
        Section("Network") {
            ForEach(networks) { nic in
                editable(privilege: "VM.Config.Network") {
                    if isVM {
                        NetworkDeviceEditor(detail: detail, config: config, nic: nic)
                    } else {
                        ContainerNetworkEditor(detail: detail, config: config, nic: nic)
                    }
                } label: {
                    HardwareRow(
                        systemImage: "network",
                        title: nic.key,
                        value: [nic.model, nic.bridge, nic.vlanTag.map { "VLAN \($0)" }].compactMap { $0 }.joined(separator: " · "),
                        detail: [nic.macAddress, nic.ipv4.map { "IP \($0)" }, nic.firewall ? String(localized: "Firewall") : nil, nic.isLinkDown ? String(localized: "Disconnected") : nil].compactMap { $0 }.joined(separator: " · "),
                        pending: detail.pendingChange(for: nic.key) != nil
                    )
                }
                .accessibilityIdentifier("hardware.\(nic.key)")
            }
            if !isVM {
                editable(privilege: "VM.Config.Network") {
                    ContainerDNSEditor(detail: detail, config: config)
                } label: {
                    HardwareRow(
                        systemImage: "server.rack",
                        title: "DNS",
                        value: config["nameserver"] ?? String(localized: "Host settings"),
                        detail: config["searchdomain"],
                        pending: detail.pendingChange(for: "nameserver") != nil || detail.pendingChange(for: "searchdomain") != nil
                    )
                }
                .accessibilityIdentifier("hardware.dns")
            }
            if detail.can("VM.Config.Network") {
                NavigationLink {
                    if isVM {
                        NetworkDeviceEditor(detail: detail, config: config, nic: nil)
                    } else {
                        ContainerNetworkEditor(detail: detail, config: config, nic: nil)
                    }
                } label: {
                    Label("Add Network Device", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("hardware.addNetwork")
            }
        }

        if isVM {
            Section("Devices") {
                ForEach(config.otherDevices, id: \.key) { device in
                    editable(privilege: device.kind.privilege) {
                        VMDeviceEditor(detail: detail, config: config, kind: device.kind, key: device.key)
                    } label: {
                        HardwareRow(
                            systemImage: device.kind.systemImage,
                            title: device.key,
                            value: device.kind.summary(of: device.value),
                            detail: nil,
                            pending: detail.pendingChange(for: device.key) != nil
                        )
                    }
                    .accessibilityIdentifier("hardware.\(device.key)")
                }
                if detail.can("VM.Config.HWType") || detail.can("VM.Config.Disk") {
                    NavigationLink {
                        AddDeviceList(detail: detail, config: config)
                    } label: {
                        Label("Add Device", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("hardware.addDevice")
                }
            }
        }
    }

    /// A navigation row to an editor, or a locked row explaining why it cannot be changed.
    @ViewBuilder
    private func editable<Editor: View, Label: View>(privilege: String, enabled: Bool = true, @ViewBuilder editor: @escaping () -> Editor, @ViewBuilder label: () -> Label) -> some View {
        if !detail.can(privilege) {
            label().locked("You need the \(privilege) privilege on this guest to change this.")
        } else if enabled {
            NavigationLink(destination: editor, label: label)
        } else {
            label().locked("Editing this is not supported yet.")
        }
    }

    @ViewBuilder
    private func pendingLabel(_ keys: String...) -> some View {
        if keys.contains(where: { detail.pendingChange(for: $0) != nil }) {
            PendingBadge()
        }
    }

    private var cores: String {
        let total = (config.cores ?? 1) * config.sockets
        let text = Format.cores(total)
        return config.sockets > 1 ? "\(text) (\(config.sockets) × \(config.cores ?? 1))" : text
    }
}

/// Changes that wait for the next restart, with a way to drop them.
private struct PendingChangesSection: View {
    let detail: GuestDetail
    @State private var isReverting = false
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(detail.pendingChanges) { item in
                LabeledContent(item.key) {
                    if item.isPendingDeletion {
                        Text("Removed").foregroundStyle(.orange)
                    } else {
                        Text("\(item.value ?? "—") → \(item.pending ?? "—")")
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Button("Revert Pending Changes", role: .destructive) {
                Task {
                    isReverting = true
                    defer { isReverting = false }
                    do {
                        try await detail.revertPendingChanges()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .disabled(isReverting)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Label("Pending Changes", systemImage: "clock.arrow.circlepath")
        } footer: {
            Text("These changes take effect the next time the guest starts. A reboot from inside the guest is not enough; use Reboot or Stop and Start here.")
        }
        .accessibilityIdentifier("pendingChanges")
    }
}

private struct HardwareRow: View {
    let systemImage: String
    let title: String
    let value: String
    let detail: String?
    var pending = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if pending {
                    PendingBadge()
                }
            }
        }
    }
}

/// Marks a value that changes at the next start.
private struct PendingBadge: View {
    var body: some View {
        (Text(Image(systemName: "clock.arrow.circlepath")) + Text(" ") + Text("Pending restart"))
            .font(.caption2)
            .foregroundStyle(.orange)
            .fixedSize()
    }
}
