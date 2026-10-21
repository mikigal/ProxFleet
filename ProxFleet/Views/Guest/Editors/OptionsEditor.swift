import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The Options panel of a guest, every option editable in place.
struct OptionsEditor: View {
    let detail: GuestDetail
    let config: GuestConfig

    var body: some View {
        if detail.reference.kind == .virtualMachine {
            VMOptionsEditor(detail: detail, config: config)
        } else {
            ContainerOptionsEditor(detail: detail, config: config)
        }
    }
}

private struct VMOptionsEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let original: VMOptionsDraft
    @State private var draft: VMOptionsDraft
    @State private var stateStorages: [StorageInfo] = []
    @State private var snippets: [StorageVolume] = []

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        self.config = config
        let draft = VMOptionsDraft(config)
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isRoot: Bool { detail.connection.profile.userID == "root@pam" }

    var body: some View {
        ConfigEditor(title: "Options", detail: detail, makeUpdate: update, privilege: "VM.Config.Options") { errors in
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $draft.name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("option.name")
                }
                FieldError(message: errors["name"])
                OSTypePicker(connection: detail.connection, kind: detail.reference.kind, selection: $draft.osType)
                Toggle("Protection", isOn: $draft.protection)
            } footer: {
                Text("Protection prevents removing the VM or its disks by accident.")
            }

            Section("Tags") {
                TagsEditor(tags: $draft.tags)
                FieldError(message: errors["tags"])
            }

            StartupSection(startAtBoot: $draft.startAtBoot, startup: $draft.startup, error: errors["startup"])

            Section("Boot") {
                NavigationLink {
                    BootOrderEditor(detail: detail, config: config)
                } label: {
                    LabeledContent("Boot Order", value: config.bootOrder.joined(separator: ", "))
                }
                Toggle("Start at Current Time", isOn: Binding(
                    get: { draft.rtcStartDate == nil },
                    set: { draft.rtcStartDate = $0 ? nil : Self.dateFormatter.string(from: Date()) }
                ))
                if let date = draft.rtcStartDate {
                    DatePicker("RTC Start Date", selection: Binding(
                        get: { Self.dateFormatter.date(from: date) ?? Self.dayFormatter.date(from: date) ?? Date() },
                        set: { draft.rtcStartDate = Self.dateFormatter.string(from: $0) }
                    ))
                }
                FieldError(message: errors["startdate"])
                Toggle("Use Local Time for RTC", isOn: $draft.localTime)
                Toggle("Freeze CPU at Startup", isOn: $draft.freezeCPU)
                Toggle("Allow Reboot", isOn: $draft.allowReboot)
            }

            Section {
                Toggle("Enabled", isOn: $draft.agentEnabled)
                    .accessibilityIdentifier("option.agent")
                if draft.agentEnabled {
                    Toggle("Freeze File Systems for Backups", isOn: $draft.agentFreezeFS)
                    Toggle("Trim Cloned Disks", isOn: $draft.agentTrimClonedDisks)
                    Picker("Type", selection: $draft.agentType) {
                        Text("VirtIO").tag("virtio")
                        Text("ISA").tag("isa")
                    }
                }
                FieldError(message: errors["agent"])
            } header: {
                Text("QEMU Guest Agent")
            } footer: {
                Text("The agent must also be installed in the guest. It reports IP addresses and allows clean shutdowns and consistent backups.")
            }

            Section {
                ForEach(VMOptionsDraft.hotplugFeatures, id: \.self) { feature in
                    Toggle(feature.capitalized, isOn: Binding(
                        get: { draft.hotplug.contains(feature) },
                        set: { if $0 { draft.hotplug.insert(feature) } else { draft.hotplug.remove(feature) } }
                    ))
                }
                FieldError(message: errors["hotplug"])
            } header: {
                Text("Hotplug")
            } footer: {
                Text("Devices of the selected kinds can be added or removed while the VM runs. Memory and CPU hotplug need support in the guest and NUMA enabled.")
            }

            Section("Devices") {
                Toggle("Use Tablet for Pointer", isOn: $draft.tablet)
                Toggle("ACPI Support", isOn: $draft.acpi)
                Toggle("KVM Hardware Virtualization", isOn: $draft.kvm)
                Picker("Keyboard Layout", selection: $draft.keyboard) {
                    Text("Default").tag("")
                    ForEach(VMOptionsDraft.keyboardLayouts, id: \.self) { Text($0).tag($0) }
                }
                Picker("Watchdog", selection: $draft.watchdogModel) {
                    Text("None").tag("")
                    Text("Intel 6300ESB").tag("i6300esb")
                    Text("iBase IB700").tag("ib700")
                }
                if !draft.watchdogModel.isEmpty {
                    Picker("Watchdog Action", selection: $draft.watchdogAction) {
                        Text("Default").tag("")
                        ForEach(VMOptionsDraft.watchdogActions, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                FieldError(message: errors["watchdog"])
            }

            Section("Memory") {
                Toggle("Allow KSM", isOn: $draft.allowKSM)
                Picker("Hugepages", selection: $draft.hugepages) {
                    Text("Off").tag("")
                    Text("Any").tag("any")
                    Text("2 MiB").tag("2")
                    Text("1 GiB").tag("1024")
                }
                if !draft.hugepages.isEmpty {
                    Toggle("Keep Hugepages After Shutdown", isOn: $draft.keepHugepages)
                }
                Picker("VM State Storage", selection: $draft.vmStateStorage) {
                    Text("Automatic").tag("")
                    ForEach(storageNames(stateStorages, current: draft.vmStateStorage), id: \.self) { Text($0).tag($0) }
                }
            }

            Section {
                NavigationLink {
                    SMBIOSEditor(smbios: $draft.smbios)
                } label: {
                    LabeledContent("SMBIOS (Type 1)", value: draft.smbios.manufacturer.isEmpty ? String(localized: "Default") : draft.smbios.manufacturer)
                }
                FieldError(message: errors["smbios1"])
                Toggle("SPICE Folder Sharing", isOn: $draft.spiceFolderSharing)
                Picker("SPICE Video Streaming", selection: $draft.spiceVideoStreaming) {
                    Text("Off").tag("off")
                    Text("All").tag("all")
                    Text("Filter").tag("filter")
                }
            } header: {
                Text("Advanced")
            }

            Section {
                Picker("AMD SEV", selection: $draft.sevType) {
                    Text("Off").tag("")
                    Text("SEV").tag("std")
                    Text("SEV-ES").tag("es")
                    Text("SEV-SNP").tag("snp")
                }
                if !draft.sevType.isEmpty {
                    Toggle("Disable Debugging", isOn: $draft.sevNoDebug)
                    Toggle("Disable Key Sharing", isOn: $draft.sevNoKeySharing)
                    Toggle("Kernel Hashes", isOn: $draft.sevKernelHashes)
                    Toggle("Allow SMT", isOn: $draft.sevAllowSMT)
                }
                FieldError(message: errors["amd-sev"])
                Toggle("Intel TDX", isOn: $draft.tdxEnabled)
                if draft.tdxEnabled {
                    Toggle("Attestation", isOn: $draft.tdxAttestation)
                }
                FieldError(message: errors["intel-tdx"])
            } header: {
                Text("Confidential Computing")
            } footer: {
                Text("Encrypts guest memory on supported AMD or Intel CPUs. Needs host support and OVMF.")
            }

            Section {
                LabeledContent("Max Downtime") {
                    TextField("0.1 s", text: $draft.migrateDowntime).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                LabeledContent("Max Speed") {
                    TextField("Unlimited", text: $draft.migrateSpeed).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                FieldError(message: errors["migrate_downtime"] ?? errors["migrate_speed"])
            } header: {
                Text("Migration")
            } footer: {
                Text("Downtime in seconds, speed in MB/s.")
            }

            HookscriptSection(hookscript: $draft.hookscript, snippets: snippets, isRoot: isRoot, error: errors["hookscript"])
        }
        .task {
            stateStorages = await detail.load(PVE.storages(node: detail.reference.node, content: "images"))
            snippets = await loadSnippets(detail)
        }
    }

    private func update() -> GuestConfigUpdate? {
        let update = draft.changes(from: original)
        return update.isEmpty ? nil : update
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct ContainerOptionsEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let original: ContainerOptionsDraft
    @State private var draft: ContainerOptionsDraft
    @State private var snippets: [StorageVolume] = []

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        self.config = config
        let draft = ContainerOptionsDraft(config)
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isRoot: Bool { detail.connection.profile.userID == "root@pam" }

    var body: some View {
        ConfigEditor(title: "Options", detail: detail, makeUpdate: update, privilege: "VM.Config.Options") { errors in
            Section {
                LabeledContent("Hostname") {
                    TextField("Hostname", text: $draft.hostname)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("option.name")
                }
                FieldError(message: errors["hostname"])
                OSTypePicker(connection: detail.connection, kind: detail.reference.kind, selection: $draft.osType)
                Picker("Architecture", selection: $draft.architecture) {
                    ForEach(ContainerOptionsDraft.architectures, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Protection", isOn: $draft.protection)
                LabeledContent("Unprivileged", value: draft.isUnprivileged ? String(localized: "Yes") : String(localized: "No"))
                    .locked("Whether a container is unprivileged is decided when it is created. To change it, back it up and restore the backup with the other setting.")
            }

            Section("Tags") {
                TagsEditor(tags: $draft.tags)
                FieldError(message: errors["tags"])
            }

            StartupSection(startAtBoot: $draft.startAtBoot, startup: $draft.startup, error: errors["startup"])

            Section {
                Toggle("Nesting", isOn: $draft.nesting)
                Toggle("keyctl", isOn: $draft.keyctl)
                Toggle("FUSE", isOn: $draft.fuse)
                Toggle("Create Device Nodes (mknod)", isOn: $draft.mknod)
                Toggle("Writable /sys", isOn: $draft.forceWritableSys)
                ForEach(ContainerOptionsDraft.mountableTypes, id: \.self) { type in
                    Toggle("Allow \(type.uppercased()) Mounts", isOn: Binding(
                        get: { draft.mountTypes.contains(type) },
                        set: { if $0 { draft.mountTypes.insert(type) } else { draft.mountTypes.remove(type) } }
                    ))
                }
                FieldError(message: errors["features"])
            } header: {
                Text("Features")
            } footer: {
                Text("Nesting and keyctl are needed for Docker in unprivileged containers. Some features are only allowed for root@pam.")
            }

            Section("Console") {
                Picker("Console Mode", selection: $draft.consoleMode) {
                    Text("TTY").tag("tty")
                    Text("/dev/console").tag("console")
                    Text("Shell").tag("shell")
                }
                Stepper("TTY Count: \(draft.ttyCount)", value: $draft.ttyCount, in: 0...6)
                Toggle("Console Device", isOn: $draft.consoleDevice)
            }

            Section {
                Picker("Time Zone", selection: $draft.timezone) {
                    Text("Not Managed").tag("")
                    Text("Same as Host").tag("host")
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.navigationLink)
                FieldError(message: errors["timezone"])
                Toggle("Debug Logging", isOn: $draft.debug)
            }

            Section {
                LabeledContent("Entrypoint") {
                    TextField("/sbin/init", text: $draft.entrypoint)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                FieldError(message: errors["entrypoint"])
                ForEach($draft.environment) { $variable in
                    HStack {
                        TextField("NAME", text: $variable.name)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        Text(verbatim: "=")
                        TextField("value", text: $variable.value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .onDelete { draft.environment.remove(atOffsets: $0) }
                Button("Add Variable", systemImage: "plus") {
                    draft.environment.append(.init(name: "", value: ""))
                }
                FieldError(message: errors["env"])
            } header: {
                Text("Application Container")
            } footer: {
                Text("For containers created from OCI images. Changes apply at the next start.")
            }

            HookscriptSection(hookscript: $draft.hookscript, snippets: snippets, isRoot: isRoot, error: errors["hookscript"])
        }
        .task { snippets = await loadSnippets(detail) }
    }

    private func update() -> GuestConfigUpdate? {
        let update = draft.changes(from: original)
        return update.isEmpty ? nil : update
    }
}

private struct StartupSection: View {
    @Binding var startAtBoot: Bool
    @Binding var startup: StartupOptions
    let error: String?

    var body: some View {
        Section {
            Toggle("Start at Boot", isOn: $startAtBoot)
                .accessibilityIdentifier("option.onboot")
            LabeledContent("Start Order") {
                TextField("Any", text: $startup.order).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("Startup Delay") {
                TextField("Default", text: $startup.startDelay).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("Shutdown Timeout") {
                TextField("Default", text: $startup.shutdownTimeout).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            FieldError(message: error)
        } header: {
            Text("Start and Shutdown")
        } footer: {
            Text("Lower order numbers start first and shut down last. Delay and timeout are in seconds.")
        }
    }
}

private struct HookscriptSection: View {
    @Binding var hookscript: String
    let snippets: [StorageVolume]
    let isRoot: Bool
    let error: String?

    var body: some View {
        Section {
            if isRoot {
                Picker("Hookscript", selection: $hookscript) {
                    Text("None").tag("")
                    ForEach(names, id: \.self) { Text($0).tag($0) }
                }
            } else {
                LabeledContent("Hookscript", value: hookscript.isEmpty ? String(localized: "None") : hookscript)
                    .locked("Only root@pam can set hookscripts, because they run as root on the host.")
            }
            FieldError(message: error)
        } footer: {
            Text("A script from a storage with snippets content, run at each step of the guest's lifecycle.")
        }
    }

    private var names: [String] {
        var names = snippets.map(\.volumeID)
        if !hookscript.isEmpty, !names.contains(hookscript) { names.insert(hookscript, at: 0) }
        return names
    }
}

/// SMBIOS type 1 fields reported to the guest.
private struct SMBIOSEditor: View {
    @Binding var smbios: SMBIOSOptions

    var body: some View {
        Form {
            Section {
                field("UUID", $smbios.uuid)
                field("Manufacturer", $smbios.manufacturer)
                field("Product", $smbios.product)
                field("Version", $smbios.version)
                field("Serial", $smbios.serial)
                field("SKU", $smbios.sku)
                field("Family", $smbios.family)
            } footer: {
                Text("The UUID identifies the VM to the guest; changing it can deactivate guest software licenses.")
            }
        }
        .navigationTitle("SMBIOS")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func field(_ title: LocalizedStringKey, _ value: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("Default", text: value)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

private func storageNames(_ storages: [StorageInfo], current: String) -> [String] {
    var names = storages.map(\.storage)
    if !current.isEmpty, !names.contains(current) { names.insert(current, at: 0) }
    return names
}

private func loadSnippets(_ detail: GuestDetail) async -> [StorageVolume] {
    let storages = await detail.load(PVE.storages(node: detail.reference.node, content: "snippets"))
    var volumes: [StorageVolume] = []
    for storage in storages {
        volumes += await detail.load(PVE.storageContent(node: detail.reference.node, storage: storage.storage, content: "snippets"))
    }
    return volumes
}

/// OS types the server knows, with its own labels when its API schema provides them.
struct OSTypePicker: View {
    let connection: ServerConnection
    let kind: GuestKind
    @Binding var selection: String
    @State private var offered: [String] = []
    @State private var labels: [String: String] = [:]

    private var choices: [String] {
        var types = GuestConfig.orderedOSTypes(offered, kind: kind)
        if !selection.isEmpty, !types.contains(selection) { types.insert(selection, at: 0) }
        return types
    }

    var body: some View {
        Picker("OS Type", selection: $selection) {
            if selection.isEmpty { Text("Not Set").tag("") }
            ForEach(choices, id: \.self) { type in
                Text(label(for: type)).tag(type)
            }
        }
        .task {
            guard let parameter = try? await connection.apiSchema().config(for: kind).first(where: { $0.name == "ostype" }) else { return }
            offered = parameter.enumValues ?? []
            labels = parameter.enumDescriptions
        }
    }

    private func label(for type: String) -> String {
        // The server's labels name Microsoft on every Windows entry; the list reads better without it.
        labels[type].map { $0.replacingOccurrences(of: "Microsoft ", with: "") } ?? GuestConfig.osTypeName(type)
    }
}

/// Reorderable list of boot devices; devices can be switched off.
struct BootOrderEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var devices: [BootDevice]

    struct BootDevice: Identifiable, Equatable {
        var key: String
        var detail: String
        var enabled: Bool
        var id: String { key }
    }

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        self.config = config
        let order = config.bootOrder
        let candidates = config.disks.filter { !$0.isUnused && !["efidisk0", "tpmstate0"].contains($0.key) }.map { ($0.key, $0.isCDROM ? $0.volume : ($0.size ?? $0.volume)) }
            + config.networks.map { ($0.key, $0.bridge ?? "") }
        let enabled = order.compactMap { key in candidates.first { $0.0 == key } }.map { BootDevice(key: $0.0, detail: $0.1, enabled: true) }
        let disabled = candidates.filter { !order.contains($0.0) }.map { BootDevice(key: $0.0, detail: $0.1, enabled: false) }
        _devices = State(initialValue: enabled + disabled)
    }

    var body: some View {
        ConfigEditor(title: "Boot Order", detail: detail, makeUpdate: update, footer: "The new boot order is used the next time the VM starts.") { errors in
            Section {
                ForEach($devices) { $device in
                    Toggle(isOn: $device.enabled) {
                        VStack(alignment: .leading) {
                            Text(device.key)
                            Text(device.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { devices.move(fromOffsets: $0, toOffset: $1) }
                FieldError(message: errors["boot"])
            } footer: {
                Text("Drag to reorder. The VM tries enabled devices from top to bottom.")
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    private func update() -> GuestConfigUpdate? {
        let order = devices.filter(\.enabled).map(\.key)
        guard order != config.bootOrder else { return nil }
        var update = GuestConfigUpdate()
        update.set("boot", "order=" + order.joined(separator: ";"))
        return update
    }
}
