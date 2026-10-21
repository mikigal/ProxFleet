import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The pages of the Create CT wizard, in the order of the web interface.
nonisolated enum ContainerCreationStep: CreationStep {
    case general, template, disks, cpu, memory, network, dns, confirm

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .template: "Template"
        case .disks: "Disks"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .dns: "DNS"
        case .confirm: "Confirm"
        }
    }

    func owns(_ parameter: String) -> Bool {
        switch self {
        case .general: ["vmid", "hostname", "pool", "ha-managed", "unprivileged", "features", "password", "ssh-public-keys", "onboot", "startup", "tags"].contains(parameter)
        case .template: parameter == "ostemplate"
        case .disks: parameter == "rootfs" || parameter.hasPrefix("mp")
        case .cpu: ["cores", "cpulimit", "cpuunits"].contains(parameter)
        case .memory: ["memory", "swap"].contains(parameter)
        case .network: parameter.hasPrefix("net")
        case .dns: ["nameserver", "searchdomain"].contains(parameter)
        case .confirm: false
        }
    }

    /// Fields behind the web interface's Advanced checkbox. Root disk and network options are part of their value.
    func isAdvanced(_ parameter: String) -> Bool {
        ["onboot", "startup", "tags", "cpulimit", "cpuunits"].contains(parameter)
    }
}

/// Creates a container from a template step by step, like the web interface's wizard.
/// Templates can also be downloaded from here.
struct CreateContainerView: View {
    let connection: ServerConnection
    let onCreated: (GuestReference) -> Void
    @State private var pools: [ResourcePool] = []
    @State private var draft: ContainerCreationDraft
    @State private var templatesReloadID = 0
    @AppStorage(AdvancedCreationOptions.storageKey) private var showsAdvanced = false

    init(connection: ServerConnection, onCreated: @escaping (GuestReference) -> Void) {
        self.connection = connection
        self.onCreated = onCreated
        _draft = State(initialValue: ContainerCreationDraft(node: NodePicker.defaultNode(connection), vmid: 0))
    }

    var body: some View {
        CreationWizard<ContainerCreationStep, _>(
            title: "New Container",
            connection: connection,
            reference: GuestReference(node: draft.node, vmid: draft.vmid, kind: .container),
            problems: draft.problems,
            makeRequest: { PVE.createContainer(draft) },
            onCreated: onCreated,
            showsAdvancedOptions: $showsAdvanced
        ) { step, errors in
            switch step {
            case .general: general(errors)
            case .template: template(errors)
            case .disks: disks(errors)
            case .cpu: processor(errors)
            case .memory: memory(errors)
            case .network: network(errors)
            case .dns: dns(errors)
            case .confirm: confirm
            }
        }
    }

    @ViewBuilder
    private func general(_ errors: [String: String]) -> some View {
        Section {
            NodePicker(connection: connection, selection: $draft.node)
            GuestIDField(connection: connection, vmid: $draft.vmid, error: errors["vmid"])
            LabeledContent("Host Name") {
                TextField("Optional", text: $draft.hostname)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("hostname")
            }
            FieldError(message: errors["hostname"])
            if isCluster {
                Toggle("Add to HA", isOn: $draft.isHAManaged)
                FieldError(message: errors["ha-managed"])
            }
            PoolPicker(pools: pools, selection: $draft.pool)
        } footer: {
            if isCluster {
                Text("High availability starts the container on another node when its node fails.")
            }
        }
        .task { pools = await connection.load(PVE.pools()) }

        Section {
            // A password and its confirmation look like a sign-up form to iOS, which then offers a strong
            // password to keep in the Passwords app. This is a password inside the container, not an account
            // of the app, so the one-time-code type keeps that offer away.
            SecureField("Password", text: $draft.password)
                .textContentType(.oneTimeCode)
                .accessibilityIdentifier("password")
            SecureField("Confirm Password", text: $draft.passwordConfirmation)
                .textContentType(.oneTimeCode)
                .accessibilityIdentifier("passwordConfirmation")
            FieldError(message: errors["password"])
            ZStack(alignment: .topLeading) {
                if draft.sshPublicKeys.isEmpty {
                    Text("SSH Public Keys (optional)")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                }
                TextEditor(text: $draft.sshPublicKeys)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 80)
            }
            FieldError(message: errors["ssh-public-keys"])
        } header: {
            Text("Root Login")
        } footer: {
            Text("Set a password, add SSH keys (one per line), or both.")
        }

        Section {
            Toggle("Unprivileged", isOn: $draft.unprivileged)
            Toggle("Nesting", isOn: $draft.nesting)
            FieldError(message: errors["features"])
        } footer: {
            Text("Unprivileged containers map root to an ordinary user on the host, which is safer. Nesting is needed by recent systemd versions and to run containers inside.")
        }

        if showsAdvanced {
            StartupSection(startAtBoot: $draft.startOnBoot, startup: $draft.startup, error: errors["startup"])
            Section("Tags") {
                TagsEditor(tags: $draft.tags)
                FieldError(message: errors["tags"])
            }
        }
    }

    /// High availability needs a cluster.
    private var isCluster: Bool { (connection.snapshot?.nodes.count ?? 0) > 1 }

    @ViewBuilder
    private func template(_ errors: [String: String]) -> some View {
        Section {
            VolumePicker(title: "Template", connection: connection, node: draft.node, content: "vztmpl", selection: $draft.template, reloadID: templatesReloadID)
                .accessibilityIdentifier("template")
            FieldError(message: errors["ostemplate"])
        } footer: {
            Text("The operating system of the container comes from its template.")
        }
        Section {
            NavigationLink("Download Templates") {
                TemplateDownloadView(connection: connection, node: draft.node) { volume in
                    templatesReloadID += 1
                    draft.template = volume
                }
            }
        } footer: {
            Text("Distributions and TurnKey Linux appliances from the official repositories.")
        }
    }

    @ViewBuilder
    private func disks(_ errors: [String: String]) -> some View {
        Section {
            NodeStoragePicker(title: "Storage", connection: connection, node: draft.node, content: "rootdir", selection: $draft.rootStorage)
            NumberField(title: "Size", value: $draft.rootSizeGiB, range: 1...65_536, unit: "GiB")
            FieldError(message: errors["rootfs"])
        } header: {
            Text("Root Disk")
        }
        if showsAdvanced {
            MountPointOptionsSection(draft: $draft.rootFS, error: errors["rootfs"], footer: "Quotas need a privileged container.")
        }
        ForEach($draft.mountPoints) { $mountPoint in
            let key = draft.mountPoints.firstIndex { $0.id == mountPoint.id }.map { "mp\($0)" } ?? ""
            Section {
                NodeStoragePicker(title: "Storage", connection: connection, node: draft.node, content: "rootdir", selection: $mountPoint.storage)
                NumberField(title: "Size", value: $mountPoint.sizeGiB, range: 1...65_536, unit: "GiB")
                LabeledContent("Path in Container") {
                    TextField("/data", text: $mountPoint.options.path)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("mountPoint.path.\(key)")
                }
                Toggle("Include in Backups", isOn: $mountPoint.options.includeInBackup)
                if showsAdvanced {
                    Toggle("Read Only", isOn: $mountPoint.options.readOnly)
                }
                FieldError(message: errors[key])
                Button("Remove Mount Point", role: .destructive) {
                    withAnimation { draft.mountPoints.removeAll { $0.id == mountPoint.id } }
                }
            } header: {
                Text(verbatim: key)
            }
            if showsAdvanced {
                MountOptionsSection(draft: $mountPoint.options, error: nil, title: String(localized: "\(key) Mount Options"), footer: "Quotas need a privileged container.")
            }
        }
        Section {
            Button("Add Mount Point") {
                withAnimation { draft.addMountPoint() }
            }
            .disabled(draft.mountPoints.count >= ContainerCreationDraft.maximumMountPoints)
            .accessibilityIdentifier("mountPoint.add")
        } footer: {
            Text("Mount points are further volumes at a path inside the container.")
        }
    }

    @ViewBuilder
    private func processor(_ errors: [String: String]) -> some View {
        Section {
            NumberField(title: "Cores", value: $draft.cores, range: 1...8192)
            FieldError(message: errors["cores"])
        } footer: {
            Text("The container can use this many cores of the host.")
        }
        if showsAdvanced {
            Section {
                LabeledContent("CPU Limit") {
                    TextField("Unlimited", value: Binding(get: { draft.cpuLimit > 0 ? draft.cpuLimit : nil }, set: { draft.cpuLimit = $0 ?? 0 }), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                FieldError(message: errors["cpulimit"])
                LabeledContent("CPU Units") {
                    TextField("100", text: $draft.cpuUnits)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                FieldError(message: errors["cpuunits"])
            } header: {
                Text("Scheduling")
            } footer: {
                Text("Limit is in cores. Units weigh this container against others when the host is busy.")
            }
        }
    }

    @ViewBuilder
    private func memory(_ errors: [String: String]) -> some View {
        Section {
            NumberField(title: "Memory", value: $draft.memoryMiB, range: 16...4_194_304, step: 256, unit: "MiB")
            FieldError(message: errors["memory"])
            NumberField(title: "Swap", value: $draft.swapMiB, range: 0...4_194_304, step: 256, unit: "MiB")
            FieldError(message: errors["swap"])
        }
    }

    @ViewBuilder
    private func network(_ errors: [String: String]) -> some View {
        ForEach($draft.networks) { $network in
            let key = draft.networks.firstIndex { $0.id == network.id }.map { "net\($0)" } ?? ""
            Section {
                addressField("Name", placeholder: "eth0", text: $network.device.name, keyboard: .asciiCapable)
                BridgePicker(connection: connection, node: draft.node, selection: $network.device.bridge)
                OptionalNumberField(title: "VLAN Tag", placeholder: "None", value: $network.device.vlanTag)
                MACAddressField(address: $network.device.macAddress)
                Toggle("Firewall", isOn: $network.device.firewall)
            } header: {
                Text(verbatim: key)
            }
            Section("IPv4") {
                Picker("Configuration", selection: $network.device.ipv4Mode) {
                    Text("DHCP").tag(AddressMode.dhcp)
                    Text("Static").tag(AddressMode.static)
                    Text("None").tag(AddressMode.none)
                }
                if network.device.ipv4Mode == .static {
                    addressField("Address", placeholder: "192.168.1.10/24", text: $network.device.ipv4Address)
                    addressField("Gateway", placeholder: "None", text: $network.device.ipv4Gateway)
                }
            }
            Section("IPv6") {
                Picker("Configuration", selection: $network.device.ipv6Mode) {
                    Text("None").tag(AddressMode.none)
                    Text("DHCP").tag(AddressMode.dhcp)
                    Text("SLAAC").tag(AddressMode.slaac)
                    Text("Static").tag(AddressMode.static)
                }
                if network.device.ipv6Mode == .static {
                    addressField("Address", placeholder: "fd00::10/64", text: $network.device.ipv6Address)
                    addressField("Gateway", placeholder: "None", text: $network.device.ipv6Gateway)
                }
                if !showsAdvanced {
                    removeButton(for: network, key: key, error: errors[key])
                }
            }
            if showsAdvanced {
                Section {
                    Toggle("Disconnected", isOn: $network.device.isDisconnected)
                    RateLimitField(rate: $network.device.rateLimit)
                    OptionalNumberField(title: "MTU", placeholder: "Same as Bridge", value: $network.device.mtu)
                    Toggle("Host-Managed", isOn: $network.device.isHostManaged)
                    removeButton(for: network, key: key, error: errors[key])
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Rate limit in MB/s. With Host-Managed, the host configures the addresses; the container must not run its own DHCP client on this interface.")
                }
            }
        }
        Section {
            Button("Add Network Device") {
                withAnimation { draft.addNetworkDevice() }
            }
            .disabled(draft.networks.count >= ContainerCreationDraft.maximumNetworkDevices)
            .accessibilityIdentifier("network.add")
        } footer: {
            if draft.networks.isEmpty {
                Text("The container is created without a network device; you can add one later.")
            }
        }
    }

    /// The server's error and the Remove button, at the end of an interface's last section.
    @ViewBuilder
    private func removeButton(for network: NewNetworkDevice<ContainerNetworkDraft>, key: String, error: String?) -> some View {
        FieldError(message: error)
        Button("Remove Network Device", role: .destructive) {
            withAnimation { draft.networks.removeAll { $0.id == network.id } }
        }
        .accessibilityIdentifier("network.remove.\(key)")
    }

    @ViewBuilder
    private func dns(_ errors: [String: String]) -> some View {
        Section {
            addressField("DNS Domain", placeholder: "Use Host Settings", text: $draft.searchDomain, keyboard: .URL)
            FieldError(message: errors["searchdomain"])
            addressField("DNS Servers", placeholder: "Use Host Settings", text: $draft.nameservers)
            FieldError(message: errors["nameserver"])
        } footer: {
            Text("Leave empty to use the host's settings. Separate several DNS servers with spaces.")
        }
    }

    @ViewBuilder
    private var confirm: some View {
        Section {
            Toggle("Start After Creation", isOn: $draft.startAfterCreation)
                .accessibilityIdentifier("startAfterCreation")
        }
        CreationSummary(parameters: draft.parameters)
    }

    private func addressField(_ title: LocalizedStringKey, placeholder: LocalizedStringKey, text: Binding<String>, keyboard: UIKeyboardType = .numbersAndPunctuation) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
        }
    }
}
