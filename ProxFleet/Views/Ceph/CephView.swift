import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The web interface's node > Ceph: the setup wizard until Ceph runs, then the cluster's health with its services,
/// OSDs, pools, file systems, configuration and log.
struct CephView: View {
    @State private var manager: CephManager

    init(connection: ServerConnection, node: String) {
        _manager = State(initialValue: CephManager(connection: connection, node: node))
    }

    var body: some View {
        Group {
            switch manager.setupState {
            case .notInstalled:
                CephInstallView(manager: manager)
            case .notInitialized, .noMonitor:
                CephSetupView(manager: manager)
            case .ready:
                CephDashboard(manager: manager)
            case nil:
                if let error = manager.loadError {
                    ContentUnavailableView("Cannot Load Ceph", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Ceph")
        .task {
            await manager.load()
            await manager.keepRefreshing()
        }
    }
}

// MARK: - Installation

/// Installs the Ceph packages on the node in its shell, like the web interface's wizard.
private struct CephInstallView: View {
    let manager: CephManager
    @State private var releases: [CephRelease] = []
    @State private var release = ""
    @State private var repository = "no-subscription"

    var body: some View {
        Form {
            Section {
                Label("Ceph is not installed on \(manager.node).", systemImage: "shippingbox")
            } footer: {
                Text("Ceph gives the cluster distributed storage for VM disks (RBD) and files (CephFS). Install it on every node that runs Ceph services or uses its storage.")
            }
            Section {
                Picker("Release", selection: $release) {
                    ForEach(releases) { release in
                        Text(release.isDefault ? "\(release.name) (\(release.version), recommended)" : "\(release.name) (\(release.version))").tag(release.name)
                    }
                }
                .accessibilityIdentifier("ceph.release")
                Picker("Repository", selection: $repository) {
                    Text("Enterprise").tag("enterprise")
                    Text("No-Subscription").tag("no-subscription")
                    Text("Test").tag("test")
                    Text("Manual").tag("manual")
                }
                .accessibilityIdentifier("ceph.repository")
            } footer: {
                Text(repositoryHint)
            }
            Section {
                NavigationLink {
                    CephInstallConsole(manager: manager, options: CephRelease.installOptions(release: release, repository: repository))
                } label: {
                    Label("Install \(release)", systemImage: "arrow.down.circle")
                }
                .disabled(release.isEmpty)
                .accessibilityIdentifier("ceph.install")
            } footer: {
                Text("The node's shell downloads and installs the packages. Confirm with Y when asked.")
            }
        }
        .task {
            releases = await manager.releases()
            release = (releases.first(where: \.isDefault) ?? releases.last)?.name ?? ""
        }
    }

    private var repositoryHint: String {
        switch repository {
        case "enterprise": String(localized: "Needs an active subscription on every node.")
        case "no-subscription": String(localized: "Not the best choice for production setups.")
        case "test": String(localized: "Only for test setups.")
        default: String(localized: "Expects the repository to be configured already.")
        }
    }
}

private struct CephInstallConsole: View {
    let manager: CephManager
    let options: [String]
    @State private var console: TerminalConsoleModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let console {
                TerminalConsoleView(model: console)
            } else {
                Color.black
            }
        }
        .navigationTitle("Installing Ceph")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    console?.disconnect()
                    Task { await manager.load() }
                    dismiss()
                }
                .accessibilityIdentifier("ceph.install.done")
            }
        }
        .onAppear {
            guard console == nil else { return }
            console = TerminalConsoleModel(target: .node(manager.node), session: manager.connection.apiSession, command: "ceph_install", commandOptions: options)
        }
        .onDisappear { console?.disconnect() }
    }
}

/// Creates the Ceph configuration and the first monitor, or a monitor when none answers.
private struct CephSetupView: View {
    let manager: CephManager
    @State private var networks: [String] = []
    @State private var network = ""
    @State private var clusterNetwork = ""
    @State private var size = 3
    @State private var minSize = 2
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var needsConfiguration: Bool { manager.setupState == .notInitialized }

    var body: some View {
        Form {
            if needsConfiguration {
                Section {
                    Picker("Public Network", selection: $network) {
                        if network.isEmpty { Text("Choose").tag("") }
                        ForEach(networks, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("ceph.network")
                    Picker("Cluster Network", selection: $clusterNetwork) {
                        Text("Same as Public").tag("")
                        ForEach(networks, id: \.self) { Text($0).tag($0) }
                    }
                } header: {
                    Text("Configuration")
                } footer: {
                    Text("Clients and monitors use the public network; OSDs replicate over the cluster network. A separate fast network for the cluster traffic helps.")
                }
                Section {
                    Stepper("Replicas: \(size)", value: $size, in: 2...7)
                    Stepper("Minimum Replicas: \(minSize)", value: $minSize, in: 2...max(2, min(size, 4)))
                } footer: {
                    Text("Defaults for new pools: how many copies to keep, and how many must be available to write.")
                }
            } else {
                Section {
                    Label("Ceph is configured, but no monitor answers.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Button {
                    Task { await setUp() }
                } label: {
                    HStack {
                        Text(needsConfiguration ? "Create Configuration and Monitor" : "Create Monitor on \(manager.node)")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(isWorking || (needsConfiguration && network.isEmpty))
                .accessibilityIdentifier("ceph.setup")
            } footer: {
                Text("The first monitor and a manager run on \(manager.node). Add monitors on two more nodes for a reliable quorum.")
            }
            ErrorSection(message: errorMessage)
        }
        .disabled(isWorking)
        .onChange(of: size) { minSize = min(minSize, size) }
        .task {
            networks = await manager.networks()
            if network.isEmpty { network = networks.first ?? "" }
        }
    }

    private func setUp() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            if needsConfiguration {
                try await manager.initialize(network: network, clusterNetwork: clusterNetwork, size: size, minSize: minSize)
            } else {
                try await manager.create(.monitor, on: manager.node)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Dashboard

private struct CephDashboard: View {
    let manager: CephManager

    var body: some View {
        List {
            if let status = manager.status {
                Section {
                    HStack {
                        CephHealthBadge(health: status.health)
                        Spacer()
                        Text(status.fsid.prefix(8) + "…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(status.checks) { check in
                        DisclosureGroup {
                            ForEach(check.details, id: \.self) { detail in
                                Text(detail)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(check.summary)
                                    Text(check.code + (check.isMuted ? " · " + String(localized: "muted") : ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: check.severity == "HEALTH_ERR" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(check.severity == "HEALTH_ERR" ? .red : .orange)
                            }
                        }
                        .accessibilityIdentifier("ceph.check.\(check.code)")
                    }
                } header: {
                    Text("Health")
                }
                Section {
                    LabeledContent("OSDs", value: String(localized: "\(status.osdsUp) up, \(status.osdsIn) in of \(status.osdCount)"))
                    LabeledContent("Monitors", value: String(localized: "\(status.quorum.count) of \(status.monitors.count) in quorum"))
                    LabeledContent("Managers", value: [status.activeManager.map { String(localized: "\($0) active") }, status.standbyManagers.isEmpty ? nil : String(localized: "\(status.standbyManagers.count) standby")].compactMap { $0 }.joined(separator: ", "))
                    if status.metadataServersUp + status.metadataServersStandby > 0 {
                        LabeledContent("Metadata Servers", value: String(localized: "\(status.metadataServersUp) up, \(status.metadataServersStandby) standby"))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Usage")
                            Spacer()
                            Text("\(Format.bytes(status.bytesUsed)) of \(Format.bytes(status.bytesTotal))")
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Format.fraction(status.bytesUsed, of: status.bytesTotal))
                    }
                    LabeledContent("Placement Groups", value: String(status.placementGroups))
                    ForEach(status.placementGroupStates, id: \.state) { state in
                        LabeledContent(state.state, value: String(state.count))
                            .font(.subheadline)
                            .foregroundStyle(state.state == "active+clean" ? .secondary : Color.orange)
                    }
                    if status.degradedRatio > 0 {
                        LabeledContent("Degraded Objects", value: status.degradedRatio.formatted(.percent.precision(.fractionLength(1))))
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Cluster")
                }
            }
            Section {
                NavigationLink {
                    CephServicesView(manager: manager)
                } label: {
                    MoreRow(title: "Monitors & Managers", systemImage: "eye", color: .blue, hint: manager.services[.monitor].map { String($0.count) })
                }
                .accessibilityIdentifier("ceph.services")
                NavigationLink {
                    CephOSDsView(manager: manager)
                } label: {
                    MoreRow(title: "OSDs", systemImage: "internaldrive", color: .orange, hint: manager.osdTree.map { String($0.osds.count) })
                }
                .accessibilityIdentifier("ceph.osds")
                NavigationLink {
                    CephPoolsView(manager: manager)
                } label: {
                    MoreRow(title: "Pools", systemImage: "cylinder.split.1x2", color: .purple, hint: manager.pools.map { String($0.count) })
                }
                .accessibilityIdentifier("ceph.pools")
                NavigationLink {
                    CephFileSystemsView(manager: manager)
                } label: {
                    MoreRow(title: "CephFS", systemImage: "folder", color: .teal, hint: manager.fileSystems.map { String($0.count) })
                }
                .accessibilityIdentifier("ceph.fs")
                NavigationLink {
                    CephConfigurationView(manager: manager)
                } label: {
                    MoreRow(title: "Configuration", systemImage: "doc.text", color: .gray)
                }
                .accessibilityIdentifier("ceph.config")
                NavigationLink {
                    CephLogView(manager: manager)
                } label: {
                    MoreRow(title: "Log", systemImage: "list.bullet.rectangle", color: .indigo)
                }
                .accessibilityIdentifier("ceph.log")
            }
        }
        .refreshable { await manager.load() }
    }
}

struct CephHealthBadge: View {
    let health: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(color)
            .accessibilityIdentifier("ceph.health")
    }

    private var title: LocalizedStringKey {
        switch health {
        case "HEALTH_OK": "Healthy"
        case "HEALTH_WARN": "Warning"
        case "HEALTH_ERR": "Error"
        default: "Unknown"
        }
    }

    private var icon: String {
        switch health {
        case "HEALTH_OK": "checkmark.circle.fill"
        case "HEALTH_ERR": "xmark.octagon.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch health {
        case "HEALTH_OK": .green
        case "HEALTH_ERR": .red
        default: .orange
        }
    }
}
