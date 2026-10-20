import FleetCore
import PVEKit
import SwiftUI

struct GuestDetailView: View {
    @State private var detail: GuestDetail
    @State private var pendingAction: PowerAction?
    @State private var metric: PerformanceMetric = .cpu

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

            if let error = detail.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

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

            if let config = detail.config {
                GuestHardwareSection(config: config, kind: kind)
                optionsSection(config)
                if let notes = config.description?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    Section("Notes") {
                        Text(notes)
                            .textSelection(.enabled)
                    }
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
        .confirmationDialog(
            pendingAction?.confirmationTitle(detail.name) ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
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

    private func optionsSection(_ config: GuestConfig) -> some View {
        Section("Options") {
            LabeledContent("Start at Boot", value: config.startsOnBoot ? String(localized: "Yes") : String(localized: "No"))
            if let os = config.osTypeDescription {
                LabeledContent("OS Type", value: os)
            }
            if kind == .virtualMachine {
                if !config.bootOrder.isEmpty {
                    LabeledContent("Boot Order", value: config.bootOrder.joined(separator: ", "))
                }
                LabeledContent("QEMU Guest Agent", value: config.agentEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
            } else {
                LabeledContent("Unprivileged", value: config.isUnprivileged ? String(localized: "Yes") : String(localized: "No"))
            }
        }
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

private struct GuestHardwareSection: View {
    let config: GuestConfig
    let kind: GuestKind

    var body: some View {
        Section("Hardware") {
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
            if kind == .container, let swap = config.swapMiB {
                LabeledContent("Swap", value: Format.bytes(Int64(swap) * 1_048_576))
            }
            if kind == .virtualMachine {
                LabeledContent("BIOS", value: config.bios == "ovmf" ? "OVMF (UEFI)" : "SeaBIOS")
                if let machine = config.machine {
                    LabeledContent("Machine", value: machine)
                }
            }
            ForEach(config.disks) { disk in
                HardwareRow(
                    systemImage: disk.isCDROM ? "opticaldisc" : "internaldrive",
                    title: disk.key,
                    value: disk.mountPoint.map { "\(disk.volume) → \($0)" } ?? disk.volume,
                    detail: disk.size
                )
            }
            ForEach(config.networks) { nic in
                HardwareRow(
                    systemImage: "network",
                    title: nic.key,
                    value: [nic.model, nic.bridge, nic.vlanTag.map { "VLAN \($0)" }].compactMap { $0 }.joined(separator: " · "),
                    detail: [nic.macAddress, nic.ipv4.map { "IP \($0)" }, nic.firewall ? String(localized: "Firewall") : nil].compactMap { $0 }.joined(separator: " · ")
                )
            }
        }
    }

    private var cores: String {
        let total = (config.cores ?? 1) * config.sockets
        let text = Format.cores(total)
        return config.sockets > 1 ? "\(text) (\(config.sockets) × \(config.cores ?? 1))" : text
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
