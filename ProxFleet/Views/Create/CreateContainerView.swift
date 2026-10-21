import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Creates a container from a template, which can also be downloaded from here.
struct CreateContainerView: View {
    let connection: ServerConnection
    let onCreated: (GuestReference) -> Void
    @State private var pools: [ResourcePool] = []
    @State private var draft: ContainerCreationDraft
    @State private var templatesReloadID = 0

    init(connection: ServerConnection, onCreated: @escaping (GuestReference) -> Void) {
        self.connection = connection
        self.onCreated = onCreated
        _draft = State(initialValue: ContainerCreationDraft(node: NodePicker.defaultNode(connection), vmid: 0))
    }

    var body: some View {
        CreationForm(
            title: "New Container",
            connection: connection,
            reference: GuestReference(node: draft.node, vmid: draft.vmid, kind: .container),
            problems: draft.problems,
            makeRequest: { PVE.createContainer(draft) },
            onCreated: onCreated
        ) { errors in
            Section("General") {
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
                PoolPicker(pools: pools, selection: $draft.pool)
            }
            .task { pools = await connection.load(PVE.pools()) }

            Section {
                VolumePicker(title: "Template", connection: connection, node: draft.node, content: "vztmpl", selection: $draft.template, reloadID: templatesReloadID)
                    .accessibilityIdentifier("template")
                FieldError(message: errors["ostemplate"])
                NavigationLink("Download Templates") {
                    TemplateDownloadView(connection: connection, node: draft.node) { volume in
                        templatesReloadID += 1
                        draft.template = volume
                    }
                }
            } header: {
                Text("Template")
            } footer: {
                Text("The operating system of the container comes from its template.")
            }

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

            Section("Root Disk") {
                NodeStoragePicker(title: "Storage", connection: connection, node: draft.node, content: "rootdir", selection: $draft.rootStorage)
                NumberField(title: "Size", value: $draft.rootSizeGiB, range: 1...65_536, unit: "GiB")
                FieldError(message: errors["rootfs"])
            }

            Section("Resources") {
                NumberField(title: "Cores", value: $draft.cores, range: 1...8192)
                FieldError(message: errors["cores"])
                NumberField(title: "Memory", value: $draft.memoryMiB, range: 16...4_194_304, step: 256, unit: "MiB")
                FieldError(message: errors["memory"])
                NumberField(title: "Swap", value: $draft.swapMiB, range: 0...4_194_304, step: 256, unit: "MiB")
                FieldError(message: errors["swap"])
            }

            Section {
                Toggle("Network Device", isOn: $draft.hasNetwork)
                if draft.hasNetwork {
                    BridgePicker(connection: connection, node: draft.node, selection: $draft.network.bridge)
                    OptionalNumberField(title: "VLAN Tag", placeholder: "None", value: $draft.network.vlanTag)
                    Toggle("Firewall", isOn: $draft.network.firewall)
                    Picker("IPv4", selection: $draft.network.ipv4Mode) {
                        Text("DHCP").tag(AddressMode.dhcp)
                        Text("Static").tag(AddressMode.static)
                        Text("None").tag(AddressMode.none)
                    }
                    if draft.network.ipv4Mode == .static {
                        addressField("Address", placeholder: "192.168.1.10/24", text: $draft.network.ipv4Address)
                        addressField("Gateway", placeholder: "None", text: $draft.network.ipv4Gateway)
                    }
                    Picker("IPv6", selection: $draft.network.ipv6Mode) {
                        Text("None").tag(AddressMode.none)
                        Text("DHCP").tag(AddressMode.dhcp)
                        Text("SLAAC").tag(AddressMode.slaac)
                        Text("Static").tag(AddressMode.static)
                    }
                    if draft.network.ipv6Mode == .static {
                        addressField("Address", placeholder: "fd00::10/64", text: $draft.network.ipv6Address)
                        addressField("Gateway", placeholder: "None", text: $draft.network.ipv6Gateway)
                    }
                    FieldError(message: errors["net0"])
                }
            } header: {
                Text("Network")
            }

            Section {
                addressField("DNS Domain", placeholder: "Use Host Settings", text: $draft.searchDomain, keyboard: .URL)
                FieldError(message: errors["searchdomain"])
                addressField("DNS Servers", placeholder: "Use Host Settings", text: $draft.nameservers)
                FieldError(message: errors["nameserver"])
            } footer: {
                Text("Separate several DNS servers with spaces.")
            }

            Section {
                Toggle("Start at Boot", isOn: $draft.startOnBoot)
                Toggle("Start After Creation", isOn: $draft.startAfterCreation)
                    .accessibilityIdentifier("startAfterCreation")
            }
        }
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
