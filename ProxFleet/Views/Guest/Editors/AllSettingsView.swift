import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Every configuration key the server's API schema knows, set or not, each editable with a form built from the schema.
struct AllSettingsView: View {
    let detail: GuestDetail
    @State private var parameters: [SchemaParameter]?
    @State private var loadError: String?
    @State private var search = ""

    private var config: GuestConfig { detail.config ?? GuestConfig(values: [:]) }

    var body: some View {
        List {
            if let parameters {
                let configured = configuredKeys(parameters)
                if !configured.isEmpty {
                    Section("Configured") {
                        ForEach(configured, id: \.key) { entry in
                            NavigationLink {
                                SchemaValueEditor(detail: detail, key: entry.key, parameter: entry.parameter)
                            } label: {
                                SettingRow(key: entry.key, value: config[entry.key])
                            }
                        }
                    }
                }
                let available = availableParameters(parameters)
                if !available.isEmpty {
                    Section("Not Set") {
                        ForEach(available) { parameter in
                            NavigationLink {
                                SchemaValueEditor(detail: detail, key: nil, parameter: parameter)
                            } label: {
                                SettingRow(key: parameter.isIndexed ? String(localized: "Add \(parameter.name)") : parameter.name, value: parameter.defaultValue.map { String(localized: "Default: \($0)") })
                            }
                        }
                    }
                }
            } else if let loadError {
                ContentUnavailableView("Settings Unavailable", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .searchable(text: $search, prompt: "Search Keys")
        .navigationTitle("All Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard parameters == nil else { return }
            do {
                parameters = try await detail.connection.apiSchema().config(for: detail.reference.kind)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func configuredKeys(_ parameters: [SchemaParameter]) -> [(key: String, parameter: SchemaParameter)] {
        config.values.keys
            .filter { $0 != "digest" && matchesSearch($0) }
            .compactMap { key in parameters.first { $0.matches(key: key) }.map { (key, $0) } }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    private func availableParameters(_ parameters: [SchemaParameter]) -> [SchemaParameter] {
        parameters.filter { parameter in
            matchesSearch(parameter.name) && (parameter.isIndexed || config[parameter.name] == nil)
        }
    }

    private func matchesSearch(_ key: String) -> Bool {
        search.isEmpty || key.localizedCaseInsensitiveContains(search)
    }
}

private struct SettingRow: View {
    let key: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.body.monospaced())
            if let value, !value.isEmpty {
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// Edits one configuration value with controls chosen from its schema: toggles, pickers, number and text fields,
/// or one field per key of a property string.
struct SchemaValueEditor: View {
    let detail: GuestDetail
    /// The key being edited, or nil to add a new value (indexed keys get the next free number).
    let key: String?
    let parameter: SchemaParameter
    @State private var draft: SchemaValueDraft
    @State private var confirmsRemoval = false
    @Environment(\.dismiss) private var dismiss

    init(detail: GuestDetail, key: String?, parameter: SchemaParameter) {
        self.detail = detail
        self.key = key
        self.parameter = parameter
        _draft = State(initialValue: SchemaValueDraft(parameter: parameter, value: key.flatMap { detail.config?[$0] }))
    }

    private var targetKey: String? { key ?? detail.config?.nextKey(for: parameter) }
    private var isRootOnly: Bool { Self.rootOnlyKeys.contains(parameter.name) }
    private var isRoot: Bool { detail.connection.profile.userID == "root@pam" }

    /// Keys only root@pam may change, because they run arbitrary code on the host.
    static let rootOnlyKeys: Set<String> = ["args", "hookscript", "lock"]

    var body: some View {
        ConfigEditor(title: LocalizedStringKey(targetKey ?? parameter.name), detail: detail, makeUpdate: update, privilege: Self.privilege(for: parameter.keyPrefix, kind: detail.reference.kind)) { errors in
            if isRootOnly, !isRoot {
                Section {
                    Text(draft.value ?? "—").font(.body.monospaced())
                        .locked("Only root@pam can change \(parameter.name).")
                }
            } else {
                if parameter.properties != nil, !parameter.hasKeyAliases {
                    Section {
                        Toggle("Edit as Text", isOn: Binding(get: { draft.editsAsText }, set: { setEditsAsText($0) }))
                    }
                }
                if draft.editsAsText {
                    Section {
                        ValueField(parameter: parameter, text: $draft.text)
                        FieldError(message: draft.validationMessage ?? targetKey.flatMap { errors[$0] })
                    } footer: {
                        footer(parameter)
                    }
                } else {
                    Section {
                        ForEach(parameter.properties ?? []) { property in
                            PropertyField(property: property, text: Binding(get: { draft.fields[property.name] ?? "" }, set: { draft.fields[property.name] = $0 }))
                        }
                        FieldError(message: targetKey.flatMap { errors[$0] })
                    } footer: {
                        footer(parameter)
                    }
                }
            }
            if let key, detail.config?[key] != nil, !isRootOnly || isRoot {
                Section {
                    Button(parameter.isIndexed ? "Remove \(key)" : "Reset to Default", role: .destructive) { confirmsRemoval = true }
                }
                .alert("Remove \(key)?", isPresented: $confirmsRemoval) {
                    Button("Cancel", role: .cancel) {}
                    Button("Remove", role: .destructive) { Task { await remove(key) } }
                } message: {
                    Text("The key is deleted from the configuration, so Proxmox uses its default.")
                }
            }
        }
    }

    @ViewBuilder
    private func footer(_ parameter: SchemaParameter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let description = parameter.description { Text(description) }
            if let typeText = parameter.typeText, parameter.properties == nil || draft.editsAsText {
                Text(typeText).font(.caption.monospaced())
            }
        }
    }

    private func setEditsAsText(_ asText: Bool) {
        if asText {
            draft.text = draft.value ?? ""
            draft.editsAsText = true
        } else {
            draft = SchemaValueDraft(parameter: parameter, value: draft.text)
        }
    }

    private func update() -> GuestConfigUpdate? {
        guard let targetKey, draft.validationMessage == nil else { return nil }
        let value = draft.value
        guard value != key.flatMap({ detail.config?[$0] }) else { return nil }
        var update = GuestConfigUpdate()
        update.set(targetKey, value)
        return update
    }

    private func remove(_ key: String) async {
        var update = GuestConfigUpdate()
        update.set(key, nil)
        try? await detail.apply(update)
        dismiss()
    }

    /// The privilege the server checks for a key, following its permission rules for guest configuration.
    static func privilege(for key: String, kind: GuestKind) -> String {
        switch key {
        case "ide", "sata", "scsi", "virtio", "efidisk", "tpmstate", "unused", "mp", "rootfs": "VM.Config.Disk"
        case "net": "VM.Config.Network"
        case "cores", "sockets", "cpu", "cpulimit", "cpuunits", "vcpus", "affinity", "numa", "smp": "VM.Config.CPU"
        case "memory", "balloon", "shares", "swap": "VM.Config.Memory"
        case "ciuser", "cipassword", "citype", "cicustom", "ciupgrade", "sshkeys", "ipconfig":
            "VM.Config.Cloudinit"
        case "nameserver", "searchdomain": kind == .virtualMachine ? "VM.Config.Cloudinit" : "VM.Config.Network"
        case "hostpci", "usb", "serial", "parallel", "audio", "rng", "virtiofs", "vga", "machine", "bios", "scsihw", "ivshmem", "dev":
            "VM.Config.HWType"
        default: "VM.Config.Options"
        }
    }
}

/// A field for a plain value of a schema parameter.
private struct ValueField: View {
    let parameter: SchemaParameter
    @Binding var text: String

    var body: some View {
        if parameter.type == "boolean" {
            Picker("Value", selection: $text) {
                Text("Default").tag("")
                Text("Yes").tag("1")
                Text("No").tag("0")
            }
        } else if let values = parameter.enumValues {
            Picker("Value", selection: $text) {
                Text("Default").tag("")
                ForEach(values, id: \.self) { Text($0).tag($0) }
                if !text.isEmpty, !values.contains(text) { Text(text).tag(text) }
            }
        } else {
            TextField(parameter.defaultValue ?? String(localized: "Not Set"), text: $text, axis: .vertical)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(parameter.type == "string" ? .default : .numbersAndPunctuation)
                .lineLimit(1...8)
        }
    }
}

/// A field for one key of a property string.
private struct PropertyField: View {
    let property: SchemaParameter
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if property.type == "boolean" || property.enumValues != nil {
                HStack {
                    label
                    Spacer(minLength: 8)
                    Picker(property.name, selection: $text) {
                        Text("Default").tag("")
                        if let values = property.enumValues {
                            ForEach(values, id: \.self) { Text($0).tag($0) }
                            if !text.isEmpty, !values.contains(text) { Text(text).tag(text) }
                        } else {
                            Text("Yes").tag("1")
                            Text("No").tag("0")
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } else {
                LabeledContent {
                    TextField(property.defaultValue ?? (property.isOptional ? String(localized: "Default") : String(localized: "Required")), text: $text)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(property.type == "string" ? .default : .numbersAndPunctuation)
                } label: { label }
                if !text.isEmpty, let message = SchemaValueDraft.validationMessage(text, for: property) {
                    FieldError(message: message)
                }
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(property.name).font(.body.monospaced())
            if let description = property.description {
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}

extension SchemaValueDraft {
    static func validationMessage(_ text: String, for parameter: SchemaParameter) -> String? {
        SchemaValueDraft(parameter: parameter, value: text).validationMessage
    }
}
