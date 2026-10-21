import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Edits a container network interface, or adds one when `nic` is nil.
struct ContainerNetworkEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let nic: GuestNIC?
    @State private var draft: ContainerNetworkDraft
    @State private var vlanText: String
    @State private var rateText: String
    @State private var mtuText: String
    @State private var bridges: [NodeNetworkInterface] = []
    @State private var confirmsRemoval = false
    @Environment(\.dismiss) private var dismiss

    init(detail: GuestDetail, config: GuestConfig, nic: GuestNIC?) {
        self.detail = detail
        self.config = config
        self.nic = nic
        let draft = nic.map(ContainerNetworkDraft.init) ?? ContainerNetworkDraft(name: Self.nextInterfaceName(config))
        _draft = State(initialValue: draft)
        _vlanText = State(initialValue: draft.vlanTag.map(String.init) ?? "")
        _rateText = State(initialValue: draft.rateLimit.map { $0.formatted(.number.grouping(.never)) } ?? "")
        _mtuText = State(initialValue: draft.mtu.map(String.init) ?? "")
    }

    private var key: String? { nic?.key ?? config.nextFreeKey(prefix: "net", slots: 32) }

    var body: some View {
        ConfigEditor(title: nic == nil ? "Add Network Device" : LocalizedStringKey(nic!.key), detail: detail, makeUpdate: update) { errors in
            Section {
                LabeledContent("Name") {
                    TextField("eth0", text: $draft.name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Picker("Bridge", selection: $draft.bridge) {
                    ForEach(bridgeNames, id: \.self) { name in
                        Text(bridges.first { $0.name == name }?.comment.flatMap { $0.isEmpty ? nil : "\(name) – \($0)" } ?? name).tag(name)
                    }
                }
                LabeledContent("VLAN Tag") {
                    TextField("None", text: $vlanText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Firewall", isOn: $draft.firewall)
                Toggle("Disconnected", isOn: $draft.isDisconnected)
            }

            Section("IPv4") {
                Picker("Configuration", selection: $draft.ipv4Mode) {
                    Text("None").tag(AddressMode.none)
                    Text("DHCP").tag(AddressMode.dhcp)
                    Text("Static").tag(AddressMode.static)
                    Text("Manual").tag(AddressMode.manual)
                }
                if draft.ipv4Mode == .static {
                    addressField("Address", placeholder: "192.168.1.10/24", text: $draft.ipv4Address)
                    addressField("Gateway", placeholder: "None", text: $draft.ipv4Gateway)
                }
            }

            Section {
                Picker("Configuration", selection: $draft.ipv6Mode) {
                    Text("None").tag(AddressMode.none)
                    Text("DHCP").tag(AddressMode.dhcp)
                    Text("SLAAC").tag(AddressMode.slaac)
                    Text("Static").tag(AddressMode.static)
                    Text("Manual").tag(AddressMode.manual)
                }
                if draft.ipv6Mode == .static {
                    addressField("Address", placeholder: "fd00::10/64", text: $draft.ipv6Address)
                    addressField("Gateway", placeholder: "None", text: $draft.ipv6Gateway)
                }
            } header: {
                Text("IPv6")
            } footer: {
                Text("Manual leaves the configuration to the container itself.")
            }

            Section {
                LabeledContent("MAC Address") {
                    TextField("Automatic", text: Binding(get: { draft.macAddress ?? "" }, set: { draft.macAddress = $0.isEmpty ? nil : $0.uppercased() }))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                }
                LabeledContent("Rate Limit") {
                    TextField("Unlimited", text: $rateText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("MTU") {
                    TextField("Same as Bridge", text: $mtuText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Host-Managed", isOn: $draft.isHostManaged)
                FieldError(message: key.flatMap { errors[$0] })
            } header: {
                Text("Advanced")
            } footer: {
                Text("Rate limit in MB/s. With Host-Managed, the host configures the addresses; the container must not run its own DHCP client on this interface.")
            }

            if let nic {
                Section {
                    Button("Remove Network Device", role: .destructive) { confirmsRemoval = true }
                }
                .alert("Remove \(nic.key)?", isPresented: $confirmsRemoval) {
                    Button("Cancel", role: .cancel) {}
                    Button("Remove", role: .destructive) { Task { await remove(nic.key) } }
                } message: {
                    Text("The container loses this network connection.")
                }
            }
        }
        .task { bridges = await detail.load(PVE.bridges(node: detail.reference.node)) }
    }

    private func addressField(_ title: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .font(.body.monospaced())
        }
    }

    private var bridgeNames: [String] {
        var names = bridges.map(\.name)
        if !names.contains(draft.bridge) { names.insert(draft.bridge, at: 0) }
        return names
    }

    private func update() -> GuestConfigUpdate? {
        guard let key else { return nil }
        var draft = draft
        draft.vlanTag = Int(vlanText)
        draft.rateLimit = Double(rateText.replacingOccurrences(of: ",", with: "."))
        draft.mtu = Int(mtuText)
        let value = draft.stringValue
        let original = nic.map { ContainerNetworkDraft($0).stringValue }
        guard value != original else { return nil }
        var update = GuestConfigUpdate()
        update.set(key, value)
        return update
    }

    private func remove(_ key: String) async {
        var update = GuestConfigUpdate()
        update.set(key, nil)
        try? await detail.apply(update)
        dismiss()
    }

    private static func nextInterfaceName(_ config: GuestConfig) -> String {
        let used = Set(config.networks.compactMap(\.model))
        return (0..<32).map { "eth\($0)" }.first { !used.contains($0) } ?? "eth0"
    }
}

/// DNS domain and servers of a container.
struct ContainerDNSEditor: View {
    let detail: GuestDetail
    let original: ContainerDNSDraft
    @State private var draft: ContainerDNSDraft

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        let draft = ContainerDNSDraft(config)
        original = draft
        _draft = State(initialValue: draft)
    }

    var body: some View {
        ConfigEditor(title: "DNS", detail: detail, makeUpdate: update, privilege: "VM.Config.Network") { errors in
            Section {
                LabeledContent("Search Domain") {
                    TextField("Use Host Settings", text: $draft.searchDomain)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                FieldError(message: errors["searchdomain"])
            }
            Section {
                ForEach($draft.nameservers.indices, id: \.self) { index in
                    TextField("Address", text: $draft.nameservers[index])
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .font(.body.monospaced())
                }
                .onDelete { draft.nameservers.remove(atOffsets: $0) }
                Button("Add DNS Server", systemImage: "plus") { draft.nameservers.append("") }
                FieldError(message: errors["nameserver"])
            } header: {
                Text("DNS Servers")
            } footer: {
                Text("Without servers or a search domain the container uses the host's DNS settings.")
            }
        }
    }

    private func update() -> GuestConfigUpdate? {
        let update = draft.changes(from: original)
        return update.isEmpty ? nil : update
    }
}

/// Creates a volume on a storage, or bind-mounts a host directory, and mounts it in the container.
struct AddMountPointEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var isBindMount = false
    @State private var storage = ""
    @State private var hostPath = ""
    @State private var sizeGiB = 8
    @State private var path = ""
    @State private var includeInBackup = true
    @State private var readOnly = false
    @State private var storages: [StorageInfo] = []

    private var isRoot: Bool { detail.connection.profile.userID == "root@pam" }
    private var key: String? { config.nextFreeKey(prefix: "mp", slots: 256) }

    var body: some View {
        ConfigEditor(title: "Add Mount Point", detail: detail, makeUpdate: update) { errors in
            Section {
                if isRoot {
                    Picker("Source", selection: $isBindMount) {
                        Text("Storage").tag(false)
                        Text("Host Directory").tag(true)
                    }
                    .pickerStyle(.segmented)
                } else {
                    LabeledContent("Host Directory", value: String(localized: "Not Allowed"))
                        .locked("Only root@pam can bind-mount directories of the host.")
                }
                if isBindMount {
                    LabeledContent("Host Path") {
                        TextField("/mnt/data", text: $hostPath)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } else {
                    Picker("Storage", selection: $storage) {
                        ForEach(storages) { info in
                            Text(storageLabel(info)).tag(info.storage)
                        }
                    }
                    NumberField(title: "Size", value: $sizeGiB, range: 1...65_536, unit: "GiB")
                }
                LabeledContent("Path in Container") {
                    TextField("/data", text: $path)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let key { FieldError(message: errors[key]) }
            }
            Section {
                if !isBindMount {
                    Toggle("Include in Backups", isOn: $includeInBackup)
                }
                Toggle("Read Only", isOn: $readOnly)
            }
        }
        .task {
            storages = await detail.load(PVE.storages(node: detail.reference.node, content: "rootdir")).filter(\.isActive)
            if storage.isEmpty { storage = storages.first?.storage ?? "" }
        }
    }

    private func storageLabel(_ info: StorageInfo) -> String {
        guard let available = info.available else { return info.storage }
        return "\(info.storage) (\(Format.bytes(available)) free)"
    }

    private func update() -> GuestConfigUpdate? {
        guard let key, path.hasPrefix("/") else { return nil }
        let source = isBindMount ? hostPath : storage
        guard !source.isEmpty, !isBindMount || source.hasPrefix("/") else { return nil }
        var update = GuestConfigUpdate()
        update.set(key, MountPointDraft.newValue(
            source: source,
            sizeGiB: isBindMount ? nil : sizeGiB,
            path: path,
            includeInBackup: includeInBackup && !isBindMount,
            readOnly: readOnly
        ))
        return update
    }
}

/// Mount options of the root file system or a mount point, shown inside the disk editor.
struct MountPointOptionsSection: View {
    @Binding var draft: MountPointDraft
    let error: String?
    var footer: LocalizedStringKey = "Quotas need a privileged container. Changes to a running container apply at its next start."

    var body: some View {
        if !draft.isRootFS {
            Section {
                LabeledContent("Path in Container") {
                    TextField("/data", text: $draft.path)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle("Include in Backups", isOn: $draft.includeInBackup)
                Toggle("Read Only", isOn: $draft.readOnly)
                Toggle("Shared", isOn: $draft.shared)
            } footer: {
                Text("Shared marks a volume that is available on every node, so it does not block migration. It does not share it by itself.")
            }
        }
        MountOptionsSection(draft: $draft, error: error, footer: footer)
    }
}

/// ACLs, quotas, replication and mount options of a container volume.
struct MountOptionsSection: View {
    @Binding var draft: MountPointDraft
    let error: String?
    /// Defaults to "Mount Options"; the container wizard names the mount point.
    var title: String?
    var footer: LocalizedStringKey

    var body: some View {
        Section {
            Picker("ACLs", selection: $draft.acl) {
                Text("Default").tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
            Toggle("Quotas", isOn: $draft.quota)
            Toggle("Replicate", isOn: $draft.replicate)
            ForEach(MountPointDraft.availableMountOptions, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { draft.mountOptions.contains(option) },
                    set: { if $0 { draft.mountOptions.insert(option) } else { draft.mountOptions.remove(option) } }
                ))
                .font(.body.monospaced())
            }
            FieldError(message: error)
        } header: {
            if let title { Text(verbatim: title) } else { Text("Mount Options") }
        } footer: {
            Text(footer)
        }
    }
}
