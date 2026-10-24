import FleetCore
import PBSKit
import PVEKit
import SwiftUI

/// The More tab of a backup server: administration of the server itself, its configuration, power and sign-out.
/// The node screens are the ones Proxmox VE nodes use, on the node `localhost`.
struct BackupServerMoreList: View {
    let connection: ServerConnection
    let node: NodeDetail
    @State private var access: BackupServerAccess
    @State private var settings: BackupServerSettings
    @State private var twoFactors: AccessControl
    @State private var upgrades = false
    @State private var pendingPower: NodePowerCommand?
    @State private var sentCommand: NodePowerCommand?
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(connection: ServerConnection, node: NodeDetail) {
        self.connection = connection
        self.node = node
        _access = State(initialValue: BackupServerAccess(connection: connection))
        _settings = State(initialValue: BackupServerSettings(connection: connection))
        _twoFactors = State(initialValue: AccessControl(connection: connection))
    }

    var body: some View {
        List {
            if let version = connection.backupServer?.version {
                Section {
                    LabeledContent("Proxmox Backup Server", value: version.displayVersion)
                }
            }
            Section("Administration") {
                NavigationLink {
                    BackupServerShellView(node: node)
                } label: {
                    MoreRow(title: "Shell", systemImage: "apple.terminal", color: .black)
                }
                .accessibilityIdentifier("more.shell")
                NavigationLink {
                    NodeUpdatesList(detail: node) { upgrades = true }
                        .navigationTitle("Updates")
                        .navigationDestination(isPresented: $upgrades) {
                            BackupServerShellView(node: node, command: "upgrade")
                        }
                } label: {
                    MoreRow(title: "Updates", systemImage: "arrow.down.circle", color: .green, hint: updatesHint)
                }
                .accessibilityIdentifier("more.updates")
                NavigationLink {
                    NodeServicesView(detail: node)
                } label: {
                    MoreRow(title: "Services", systemImage: "gearshape.2", color: .gray)
                }
                .accessibilityIdentifier("more.services")
                NavigationLink {
                    NodeLogView(detail: node)
                } label: {
                    MoreRow(title: "System Log", systemImage: "doc.text.magnifyingglass", color: .indigo)
                }
                .accessibilityIdentifier("more.log")
                NavigationLink {
                    SystemReportView(detail: node)
                } label: {
                    MoreRow(title: "System Report", systemImage: "doc.text", color: .brown)
                }
                .accessibilityIdentifier("more.report")
            }
            Section("System") {
                NavigationLink {
                    NodeNetworkView(detail: node)
                } label: {
                    MoreRow(title: "Network", systemImage: "point.3.filled.connected.trianglepath.dotted", color: .blue)
                }
                .accessibilityIdentifier("more.network")
                NavigationLink {
                    NodeDisksView(detail: node)
                } label: {
                    MoreRow(title: "Disks", systemImage: "internaldrive", color: .gray)
                }
                .accessibilityIdentifier("more.disks")
                NavigationLink {
                    NodeSettingLoader(detail: node, value: node.dns) { NodeDNSEditor(detail: node, dns: $0) }
                } label: {
                    MoreRow(title: "DNS", systemImage: "globe", color: .teal, hint: node.dns?.servers.first { !$0.isEmpty })
                }
                .accessibilityIdentifier("more.dns")
                NavigationLink {
                    NodeTimeZoneView(detail: node)
                } label: {
                    MoreRow(title: "Time Zone", systemImage: "clock", color: .orange, hint: node.time?.timeZone)
                }
                .accessibilityIdentifier("more.time")
                NavigationLink {
                    NodeCertificatesView(detail: node)
                } label: {
                    MoreRow(title: "Certificates", systemImage: "checkmark.seal", color: .green)
                }
                .accessibilityIdentifier("more.certificates")
                NavigationLink {
                    NodeSettingLoader(detail: node, value: node.backupServerOptions, load: { await node.loadOptions() }) {
                        BackupServerOptionsEditor(node: node, options: $0)
                    }
                } label: {
                    MoreRow(title: "Options", systemImage: "slider.horizontal.3", color: .gray)
                }
                .accessibilityIdentifier("more.options")
            }
            Section("Access") {
                NavigationLink {
                    BackupServerUsersView(access: access)
                } label: {
                    MoreRow(title: "Users", systemImage: "person.2", color: .blue)
                }
                .accessibilityIdentifier("more.users")
                NavigationLink {
                    BackupServerPermissionsView(access: access)
                } label: {
                    MoreRow(title: "Permissions", systemImage: "person.badge.key", color: .indigo)
                }
                .accessibilityIdentifier("more.permissions")
                NavigationLink {
                    TwoFactorListView(access: twoFactors)
                } label: {
                    MoreRow(title: "Two-Factor Authentication", systemImage: "lock.shield", color: .green)
                }
                .accessibilityIdentifier("more.tfa")
                NavigationLink {
                    BackupServerRealmsView(access: access)
                } label: {
                    MoreRow(title: "Realms", systemImage: "building.columns", color: .brown)
                }
                .accessibilityIdentifier("more.realms")
            }
            Section("Configuration") {
                NavigationLink {
                    BackupServerRemotesView(connection: connection)
                } label: {
                    MoreRow(title: "Remotes", systemImage: "server.rack", color: .teal)
                }
                .accessibilityIdentifier("more.remotes")
                NavigationLink {
                    TrafficControlView(settings: settings)
                } label: {
                    MoreRow(title: "Traffic Control", systemImage: "gauge.with.dots.needle.bottom.50percent", color: .orange)
                }
                .accessibilityIdentifier("more.traffic")
                NavigationLink {
                    NotificationsView(connection: connection)
                } label: {
                    MoreRow(title: "Notifications", systemImage: "bell.badge", color: .red)
                }
                .accessibilityIdentifier("more.notifications")
                NavigationLink {
                    BackupServerMetricServersView(settings: settings)
                } label: {
                    MoreRow(title: "Metric Servers", systemImage: "chart.xyaxis.line", color: .purple)
                }
                .accessibilityIdentifier("more.metrics")
                if connection.supports(backupServer: .s3Datastores) {
                    NavigationLink {
                        S3EndpointsView(settings: settings)
                    } label: {
                        MoreRow(title: "S3 Endpoints", systemImage: "cloud", color: .cyan)
                    }
                    .accessibilityIdentifier("more.s3")
                }
                if connection.supports(backupServer: .syncEncryption) {
                    NavigationLink {
                        EncryptionKeysView(settings: settings)
                    } label: {
                        MoreRow(title: "Encryption Keys", systemImage: "key", color: .yellow)
                    }
                    .accessibilityIdentifier("more.keys")
                }
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
                if !node.can("Sys.PowerMgmt") {
                    Text("Rebooting and shutting down need the \(node.privilegeName("Sys.PowerMgmt")) privilege on \(node.privilegePath).")
                } else {
                    Text("Running backups, syncs and other tasks are interrupted.")
                }
            }
            .disabled(!node.can("Sys.PowerMgmt") || isWorking)
            Section {
                Button(role: .destructive) {
                    Task { await connection.signOut() }
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityIdentifier("signOut")
            }
        }
        .task {
            if !node.hasLoaded { await node.load() }
            await node.loadSystemSettings()
        }
        .alert(pendingPower == .shutdown ? "Shut down \(serverName)?" : "Reboot \(serverName)?", isPresented: Binding(get: { pendingPower != nil }, set: { if !$0 { pendingPower = nil } }),
               presenting: pendingPower) { command in
            Button("Cancel", role: .cancel) {}
            Button(command == .shutdown ? "Shut Down" : "Reboot", role: .destructive) { Task { await power(command) } }
                .accessibilityIdentifier("node.power.confirm")
        } message: { command in
            Text(command == .shutdown
                ? "Starting the server again needs physical or out-of-band access."
                : "The server is unreachable while it restarts.")
        }
        .alert("Power Action Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(sentCommand == .shutdown ? "Shutting Down" : "Rebooting", isPresented: Binding(get: { sentCommand != nil }, set: { if !$0 { sentCommand = nil } })) {
            Button("OK") {}
        } message: {
            Text("\(serverName) received the command. It is unreachable until it is back.")
        }
    }

    private var serverName: String { connection.profile.name }

    private var updatesHint: String? {
        guard let count = node.updates?.count, count > 0 else { return nil }
        return count.formatted()
    }

    private func power(_ command: NodePowerCommand) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await node.power(command)
            sentCommand = command
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The backup server's shell, or `apt-get dist-upgrade` in it for `command: "upgrade"`.
struct BackupServerShellView: View {
    let node: NodeDetail
    var command: String?
    @State private var shell: TerminalConsoleModel?

    var body: some View {
        Group {
            if !node.can("Sys.Console") {
                ContentUnavailableView("Shell Unavailable", systemImage: "lock.fill",
                                       description: Text("The shell needs the Sys.Console privilege on \(node.privilegePath)."))
            } else if let shell {
                TerminalConsoleView(model: shell)
            } else {
                Color.black
                    .onAppear {
                        shell = TerminalConsoleModel(target: .node(node.node), session: node.connection.apiSession, command: command)
                    }
            }
        }
        .navigationTitle(command == "upgrade" ? "Upgrade" : "Shell")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .onDisappear { shell?.disconnect() }
    }
}

/// The server's options: HTTP proxy, mail sender, language, task log retention, consent banner and TLS ciphers.
struct BackupServerOptionsEditor: View {
    let node: NodeDetail
    private let original: BackupServerNodeOptionsDraft
    @State private var draft: BackupServerNodeOptionsDraft

    init(node: NodeDetail, options: BackupServerNodeOptions) {
        self.node = node
        original = BackupServerNodeOptionsDraft(options)
        _draft = State(initialValue: original)
    }

    private var lockMessage: String? {
        node.can("Sys.Modify") ? nil : missingPrivilegeMessage("Sys.Modify", on: node.privilegePath)
    }

    var body: some View {
        BackupServerSettingsForm(title: "Options", lockMessage: lockMessage) {
            let update = draft.changes(from: original)
            return update.isEmpty ? nil : update
        } save: { update throws(ConfigUpdateError) in
            if let problem = draft.problems.first {
                throw ConfigUpdateError.invalid(message: nil, fields: [problem.key: problem.value])
            }
            try await node.saveBackupServerOptions(update)
        } content: { errors in
            Section {
                LabeledTextField(title: "HTTP Proxy", prompt: "None", text: $draft.httpProxy, keyboard: .URL, identifier: "options.httpProxy")
                FieldError(message: errors["http-proxy"])
                LabeledTextField(title: "Email From", prompt: "root@$hostname", text: $draft.emailFrom, keyboard: .emailAddress, identifier: "options.emailFrom")
                FieldError(message: errors["email-from"])
            } footer: {
                Text("The proxy is used for updates, the subscription check and remotes that use it. Email From is the sender of notification mails.")
            }
            Section {
                Picker("Default Language", selection: $draft.defaultLanguage) {
                    Text("Browser's Language").tag("")
                    ForEach(BackupServerNodeOptionsDraft.languages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code.replacingOccurrences(of: "kr", with: "ko")) ?? code).tag(code)
                    }
                    if !draft.defaultLanguage.isEmpty, !BackupServerNodeOptionsDraft.languages.contains(draft.defaultLanguage) {
                        Text(draft.defaultLanguage).tag(draft.defaultLanguage)
                    }
                }
                OptionalNumberField(title: "Keep Task Logs (Days)", placeholder: "Forever", value: $draft.taskLogMaxDays)
                FieldError(message: errors["task-log-max-days"])
            } footer: {
                Text("The language of the web interface's login screen.")
            }
            Section {
                TextField("Consent Text", text: $draft.consentText, prompt: Text("None"), axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("options.consent")
            } header: {
                Text("Consent Banner")
            } footer: {
                Text("Shown before the web interface's login, e.g. a usage policy.")
            }
            Section("Description") {
                TextField("Description", text: $draft.description, prompt: Text("None"), axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("options.description")
            }
            Section {
                LabeledTextField(title: "TLS 1.2", prompt: "Default", text: $draft.ciphersTLS12, identifier: "options.ciphers12")
                FieldError(message: errors["ciphers-tls-1.2"])
                LabeledTextField(title: "TLS 1.3", prompt: "Default", text: $draft.ciphersTLS13, identifier: "options.ciphers13")
                FieldError(message: errors["ciphers-tls-1.3"])
            } header: {
                Text("Ciphers")
            } footer: {
                Text("OpenSSL cipher lists for the web interface and API. Wrong values can lock out clients.")
            }
        }
    }
}
