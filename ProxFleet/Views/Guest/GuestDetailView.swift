import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

struct GuestDetailView: View {
    @State private var detail: GuestDetail
    @State private var pendingAction: PowerAction?
    @State private var metric: PerformanceMetric = .cpu
    @State private var tab: GuestTab = .summary

    init(reference: GuestReference, connection: ServerConnection) {
        _detail = State(initialValue: GuestDetail(reference: reference, connection: connection))
    }

    private var kind: GuestKind { detail.reference.kind }

    var body: some View {
        List {
            Section {
                GuestHeader(detail: detail)
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

            Section {
                Picker("Section", selection: $tab) {
                    ForEach(GuestTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("guestTabs")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if let error = detail.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            switch tab {
            case .summary:
                summaryContent
            case .hardware:
                if let config = detail.config {
                    GuestHardwareSections(config: config, kind: kind)
                } else {
                    loadingRow
                }
            case .options:
                if let config = detail.config {
                    GuestOptionsSection(config: config, kind: kind)
                } else {
                    loadingRow
                }
            }
        }
        .navigationTitle(detail.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if !detail.hasLoaded && detail.status == nil {
                ProgressView()
            }
        }
        .refreshable { await detail.refresh() }
        .task { await detail.load() }
        .task { await detail.keepRefreshing() }
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

    @ViewBuilder
    private var summaryContent: some View {
        if let status = detail.status, status.powerState != .stopped {
            usageSection(status)
        }

        Section {
            Picker("Metric", selection: $metric) {
                ForEach(PerformanceMetric.allCases) { Text($0.title).tag($0) }
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

        networkSection

        if let notes = detail.config?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            Section("Notes") {
                Text(notes)
                    .textSelection(.enabled)
            }
        }

        if !detail.recentTasks.isEmpty {
            Section("Recent Tasks") {
                ForEach(detail.recentTasks.prefix(5)) { task in
                    NavigationLink(value: ServerRoute.task(node: task.node, upid: task.upid)) {
                        ClusterTaskRow(task: task, showsGuest: false)
                    }
                }
            }
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

private struct GuestHeader: View {
    let detail: GuestDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: detail.reference.kind == .virtualMachine ? "desktopcomputer" : "shippingbox.fill")
                    .font(.largeTitle)
                    .foregroundStyle(detail.powerState == .running ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.name)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PowerStateBadge(state: detail.powerState)
            }
            if let task = detail.runningTask {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(task.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("runningTask")
            } else if let status = detail.status, status.powerState == .running {
                Text("Up \(Format.uptime(status.uptime))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let kind = detail.reference.kind == .virtualMachine ? String(localized: "VM") : String(localized: "Container")
        let template = detail.isTemplate ? " · " + String(localized: "Template") : ""
        return "\(kind) \(detail.reference.vmid) · \(detail.reference.node)\(template)"
    }
}

enum GuestTab: String, CaseIterable, Identifiable {
    case summary, hardware, options

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .summary: "Summary"
        case .hardware: "Hardware"
        case .options: "Options"
        }
    }
}

private struct GuestHardwareSections: View {
    let config: GuestConfig
    let kind: GuestKind

    var body: some View {
        Section("System") {
            LabeledContent("Processor") {
                VStack(alignment: .trailing) {
                    Text(cores)
                    if let type = config.cpuType {
                        Text(type).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let memory = config.memoryMiB {
                LabeledContent("Memory", value: Format.bytes(Int64(memory) * 1_048_576))
            }
            if kind == .virtualMachine, let balloon = config.balloonMiB {
                LabeledContent("Minimum Memory", value: balloon == 0 ? String(localized: "Ballooning off") : Format.bytes(Int64(balloon) * 1_048_576))
            }
            if kind == .container, let swap = config.swapMiB {
                LabeledContent("Swap", value: Format.bytes(Int64(swap) * 1_048_576))
            }
            if kind == .virtualMachine {
                LabeledContent("BIOS", value: config.bios == "ovmf" ? "OVMF (UEFI)" : "SeaBIOS")
                LabeledContent("Machine", value: config.machine ?? "i440fx")
                if let controller = config["scsihw"] {
                    LabeledContent("SCSI Controller", value: controller)
                }
                if let display = config["vga"] {
                    LabeledContent("Display", value: PropertyString(parsing: display).defaultValue ?? display)
                }
            }
        }

        let disks = config.disks
        if !disks.isEmpty {
            Section(kind == .virtualMachine ? "Disks and Drives" : "Volumes") {
                ForEach(disks) { disk in
                    HardwareRow(
                        systemImage: disk.isCDROM ? "opticaldisc" : "internaldrive",
                        title: disk.key,
                        value: disk.mountPoint.map { "\(disk.volume) → \($0)" } ?? disk.volume,
                        detail: disk.size
                    )
                }
            }
        }

        let networks = config.networks
        if !networks.isEmpty {
            Section("Network") {
                ForEach(networks) { nic in
                    HardwareRow(
                        systemImage: "network",
                        title: nic.key,
                        value: [nic.model, nic.bridge, nic.vlanTag.map { "VLAN \($0)" }].compactMap { $0 }.joined(separator: " · "),
                        detail: [nic.macAddress, nic.ipv4.map { "IP \($0)" }, nic.firewall ? String(localized: "Firewall") : nil].compactMap { $0 }.joined(separator: " · ")
                    )
                }
            }
        }
    }

    private var cores: String {
        let total = (config.cores ?? 1) * config.sockets
        let text = Format.cores(total)
        return config.sockets > 1 ? "\(text) (\(config.sockets) × \(config.cores ?? 1))" : text
    }
}

/// Options as in the web interface, with Proxmox defaults where the key is not set.
private struct GuestOptionsSection: View {
    let config: GuestConfig
    let kind: GuestKind

    var body: some View {
        Section("Options") {
            LabeledContent("Name", value: config.name ?? "—")
            yesNo("Start at Boot", "onboot", default: false)
            LabeledContent("Start/Shutdown Order", value: config["startup"] ?? String(localized: "Default"))
            if let os = config.osTypeDescription {
                LabeledContent("OS Type", value: os)
            }
            yesNo("Protection", "protection", default: false)
            if kind == .virtualMachine {
                if !config.bootOrder.isEmpty {
                    LabeledContent("Boot Order", value: config.bootOrder.joined(separator: ", "))
                }
                LabeledContent("QEMU Guest Agent", value: config.agentEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                yesNo("Use Tablet for Pointer", "tablet", default: true)
                LabeledContent("Hotplug", value: config["hotplug"] ?? "network, disk, usb")
                yesNo("ACPI Support", "acpi", default: true)
                yesNo("KVM Hardware Virtualization", "kvm", default: true)
                yesNo("Freeze CPU at Startup", "freeze", default: false)
                yesNo("Use Local Time for RTC", "localtime", default: false)
            } else {
                if let arch = config["arch"] {
                    LabeledContent("Architecture", value: arch)
                }
                yesNo("Unprivileged", "unprivileged", default: false)
                LabeledContent("Features", value: config["features"] ?? String(localized: "None"))
                LabeledContent("Console Mode", value: config["cmode"] ?? "tty")
                LabeledContent("TTY Count", value: config["tty"] ?? "2")
            }
        }
    }

    private func yesNo(_ title: LocalizedStringKey, _ key: String, default value: Bool) -> some View {
        let enabled = config[key].map { $0 == "1" } ?? value
        return LabeledContent(title, value: enabled ? String(localized: "Yes") : String(localized: "No"))
    }
}

private struct HardwareRow: View {
    let systemImage: String
    let title: String
    let value: String
    let detail: String?

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
            }
        }
    }
}
