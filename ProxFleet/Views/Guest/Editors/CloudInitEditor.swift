import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Cloud-init user, SSH keys, network and DNS settings of a VM, and its cloud-init drive.
struct CloudInitEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let original: CloudInitDraft
    @State private var draft: CloudInitDraft
    @State private var isRegenerating = false
    @State private var regenerateMessage: String?

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        self.config = config
        let draft = CloudInitDraft(config)
        original = draft
        _draft = State(initialValue: draft)
    }

    var body: some View {
        ConfigEditor(title: "Cloud-Init", detail: detail, makeUpdate: update, footer: "Cloud-init settings apply when the VM boots with a regenerated image.", privilege: "VM.Config.Cloudinit") { errors in
            CloudInitDriveSection(detail: detail, config: config)

            Section {
                LabeledContent("User") {
                    TextField("Default", text: $draft.user)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("cloudinit.user")
                }
                FieldError(message: errors["ciuser"])
                LabeledContent("Password") {
                    SecureField(draft.hasPassword ? String(localized: "Unchanged") : String(localized: "None"), text: $draft.newPassword)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.newPassword)
                }
                if draft.hasPassword, draft.newPassword.isEmpty {
                    Toggle("Remove Password", isOn: $draft.removesPassword)
                }
                FieldError(message: errors["cipassword"])
                Toggle("Upgrade Packages on First Boot", isOn: $draft.upgradePackages)
            } header: {
                Text("User")
            }

            Section {
                ForEach($draft.sshKeys.indices, id: \.self) { index in
                    TextField("ssh-ed25519 AAAA… user@host", text: $draft.sshKeys[index], axis: .vertical)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                }
                .onDelete { draft.sshKeys.remove(atOffsets: $0) }
                Button("Add SSH Key", systemImage: "plus") { draft.sshKeys.append("") }
                FieldError(message: errors["sshkeys"])
            } header: {
                Text("SSH Public Keys")
            }

            ForEach(config.networks) { nic in
                if let binding = Binding($draft.ipConfigs[nic.key]) {
                    CloudInitAddressSection(nic: nic, ipConfig: binding, error: errors["ipconfig\(nic.key.dropFirst(3))"])
                }
            }

            Section {
                LabeledContent("Search Domain") {
                    TextField("Use Host Settings", text: $draft.searchDomain)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                ForEach($draft.nameservers.indices, id: \.self) { index in
                    TextField("DNS Server", text: $draft.nameservers[index])
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
                .onDelete { draft.nameservers.remove(atOffsets: $0) }
                Button("Add DNS Server", systemImage: "plus") { draft.nameservers.append("") }
                FieldError(message: errors["nameserver"] ?? errors["searchdomain"])
            } header: {
                Text("DNS")
            }

            Section {
                Picker("Type", selection: $draft.type) {
                    Text("Default").tag("")
                    Text("NoCloud").tag("nocloud")
                    Text("ConfigDrive v2").tag("configdrive2")
                    Text("OpenNebula").tag("opennebula")
                }
                ForEach(CloudInitDraft.customKinds, id: \.self) { kind in
                    LabeledContent("Custom \(kind.capitalized) Data") {
                        TextField("local:snippets/\(kind).yaml", text: Binding(get: { draft.custom[kind] ?? "" }, set: { draft.custom[kind] = $0 }))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                FieldError(message: errors["cicustom"] ?? errors["citype"])
            } header: {
                Text("Advanced")
            } footer: {
                Text("Custom data replaces the generated part with a snippet file. Windows guests with Cloudbase-Init use ConfigDrive v2.")
            }

            Section {
                ProgressButton("Regenerate Image", isWorking: isRegenerating) { Task { await regenerate() } }
                    .disabled(config.cloudInitDrive == nil)
                if let regenerateMessage {
                    Text(regenerateMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Rebuilds the cloud-init drive from the saved settings. The VM picks it up at its next boot.")
            }
        }
    }

    private func update() -> GuestConfigUpdate? {
        let update = draft.update(from: original)
        return update.isEmpty ? nil : update
    }

    private func regenerate() async {
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            _ = try await detail.connection.send(PVE.regenerateCloudInit(detail.reference))
            regenerateMessage = String(localized: "Image regenerated.")
        } catch {
            regenerateMessage = error.localizedDescription
        }
    }
}

private struct CloudInitAddressSection: View {
    let nic: GuestNIC
    @Binding var ipConfig: CloudInitIPConfig
    let error: String?

    var body: some View {
        Section {
            Picker("IPv4", selection: $ipConfig.ipv4Mode) {
                Text("None").tag(AddressMode.none)
                Text("DHCP").tag(AddressMode.dhcp)
                Text("Static").tag(AddressMode.static)
            }
            if ipConfig.ipv4Mode == .static {
                field("Address", "192.168.1.10/24", $ipConfig.ipv4Address)
                field("Gateway", "None", $ipConfig.ipv4Gateway)
            }
            Picker("IPv6", selection: $ipConfig.ipv6Mode) {
                Text("None").tag(AddressMode.none)
                Text("DHCP").tag(AddressMode.dhcp)
                Text("SLAAC").tag(AddressMode.slaac)
                Text("Static").tag(AddressMode.static)
            }
            if ipConfig.ipv6Mode == .static {
                field("Address", "fd00::10/64", $ipConfig.ipv6Address)
                field("Gateway", "None", $ipConfig.ipv6Gateway)
            }
            FieldError(message: error)
        } header: {
            Text(verbatim: "\(nic.key) · \(nic.bridge ?? "")")
        }
    }

    private func field(_ title: LocalizedStringKey, _ placeholder: String, _ text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
        }
    }
}

/// The cloud-init drive, or a way to add one.
private struct CloudInitDriveSection: View {
    let detail: GuestDetail
    let config: GuestConfig

    var body: some View {
        Section {
            if let drive = config.cloudInitDrive {
                LabeledContent("Drive", value: "\(drive.key) · \(drive.volume)")
            } else {
                NavigationLink {
                    AddCloudInitDriveEditor(detail: detail, config: config)
                } label: {
                    Label("Add Cloud-Init Drive", systemImage: "plus.circle")
                }
            }
        } footer: {
            if config.cloudInitDrive == nil {
                Text("The VM needs a cloud-init drive to receive these settings.")
            }
        }
    }
}

private struct AddCloudInitDriveEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var bus: DiskBus = .ide
    @State private var storage = ""
    @State private var storages: [StorageInfo] = []

    private var key: String? { config.nextFreeKey(prefix: bus.rawValue, slots: bus.slots) }

    var body: some View {
        ConfigEditor(title: "Add Cloud-Init Drive", detail: detail, makeUpdate: update, privilege: "VM.Config.Disk") { errors in
            Section {
                Picker("Bus", selection: $bus) {
                    ForEach(DiskBus.allCases.filter { $0 != .virtio }) { Text($0.title).tag($0) }
                }
                Picker("Storage", selection: $storage) {
                    ForEach(storages) { Text($0.storage).tag($0.storage) }
                }
                if let key {
                    LabeledContent("Attached As", value: key)
                    FieldError(message: errors[key])
                }
            }
        }
        .task {
            storages = await detail.load(PVE.storages(node: detail.reference.node, content: "images")).filter(\.isActive)
            if storage.isEmpty { storage = storages.first?.storage ?? "" }
        }
    }

    private func update() -> GuestConfigUpdate? {
        guard let key, !storage.isEmpty else { return nil }
        var update = GuestConfigUpdate()
        update.set(key, GuestConfig.cloudInitDriveValue(storage: storage))
        return update
    }
}
