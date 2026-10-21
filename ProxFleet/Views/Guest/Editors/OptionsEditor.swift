import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The Options of a guest, editable in place like the web interface's Options panel.
struct OptionsEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var name: String
    @State private var startAtBoot: Bool
    @State private var startOrder: String
    @State private var startDelay: String
    @State private var shutdownTimeout: String
    @State private var osType: String
    @State private var protection: Bool
    @State private var agent: Bool
    @State private var tablet: Bool
    @State private var acpi: Bool
    @State private var kvm: Bool
    @State private var freeze: Bool
    @State private var localTime: Bool
    @State private var nesting: Bool

    private var isVM: Bool { detail.reference.kind == .virtualMachine }
    private var nameKey: String { isVM ? "name" : "hostname" }

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        self.config = config
        let startup = PropertyString(parsing: config["startup"] ?? "")
        _name = State(initialValue: config.name ?? "")
        _startAtBoot = State(initialValue: config.startsOnBoot)
        _startOrder = State(initialValue: startup["order"] ?? "")
        _startDelay = State(initialValue: startup["up"] ?? "")
        _shutdownTimeout = State(initialValue: startup["down"] ?? "")
        _osType = State(initialValue: config.osType ?? "other")
        _protection = State(initialValue: config["protection"] == "1")
        _agent = State(initialValue: config.agentEnabled)
        _tablet = State(initialValue: config["tablet"] != "0")
        _acpi = State(initialValue: config["acpi"] != "0")
        _kvm = State(initialValue: config["kvm"] != "0")
        _freeze = State(initialValue: config["freeze"] == "1")
        _localTime = State(initialValue: config["localtime"] == "1")
        _nesting = State(initialValue: PropertyString(parsing: config["features"] ?? "")["nesting"] == "1")
    }

    var body: some View {
        ConfigEditor(title: "Options", detail: detail, makeUpdate: update) { errors in
            Section {
                LabeledContent(isVM ? "Name" : "Hostname") {
                    TextField("Name", text: $name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("option.name")
                }
                FieldError(message: errors[nameKey])
                if isVM {
                    Picker("OS Type", selection: $osType) {
                        ForEach(Self.vmOSTypes, id: \.self) { Text(GuestConfig(values: ["ostype": $0]).osTypeDescription ?? $0).tag($0) }
                    }
                }
                Toggle("Protection", isOn: $protection)
            } footer: {
                Text("Protection prevents removing the guest or its disks by accident.")
            }

            Section {
                Toggle("Start at Boot", isOn: $startAtBoot)
                    .accessibilityIdentifier("option.onboot")
                LabeledContent("Start Order") {
                    TextField("Any", text: $startOrder).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                LabeledContent("Startup Delay") {
                    TextField("Default", text: $startDelay).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                LabeledContent("Shutdown Timeout") {
                    TextField("Default", text: $shutdownTimeout).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                FieldError(message: errors["startup"])
            } header: {
                Text("Start and Shutdown")
            } footer: {
                Text("Lower order numbers start first and shut down last. Delay and timeout are in seconds.")
            }

            if isVM {
                Section {
                    NavigationLink {
                        BootOrderEditor(detail: detail, config: config)
                    } label: {
                        LabeledContent("Boot Order", value: config.bootOrder.joined(separator: ", "))
                    }
                    Toggle("QEMU Guest Agent", isOn: $agent)
                    Toggle("Use Tablet for Pointer", isOn: $tablet)
                    Toggle("ACPI Support", isOn: $acpi)
                    Toggle("KVM Hardware Virtualization", isOn: $kvm)
                    Toggle("Freeze CPU at Startup", isOn: $freeze)
                    Toggle("Use Local Time for RTC", isOn: $localTime)
                } header: {
                    Text("Virtual Machine")
                }
            } else {
                Section {
                    LabeledContent("Unprivileged", value: config.isUnprivileged ? String(localized: "Yes") : String(localized: "No"))
                    Toggle("Nesting", isOn: $nesting)
                } header: {
                    Text("Container")
                } footer: {
                    Text("Nesting is needed for Docker and systemd features in unprivileged containers.")
                }
            }
        }
    }

    static let vmOSTypes = ["l26", "l24", "win11", "win10", "win8", "win7", "w2k8", "wxp", "w2k", "solaris", "other"]

    private func update() -> GuestConfigUpdate? {
        var update = GuestConfigUpdate()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != (config.name ?? "") { update.set(nameKey, trimmed.isEmpty ? nil : trimmed) }
        if startAtBoot != config.startsOnBoot { update.set("onboot", startAtBoot) }
        if protection != (config["protection"] == "1") { update.set("protection", protection) }

        var startup = PropertyString(parsing: config["startup"] ?? "")
        startup["order"] = startOrder.isEmpty ? nil : startOrder
        startup["up"] = startDelay.isEmpty ? nil : startDelay
        startup["down"] = shutdownTimeout.isEmpty ? nil : shutdownTimeout
        if startup.stringValue != (config["startup"] ?? "") { update.set("startup", startup.items.isEmpty ? nil : startup.stringValue) }

        if isVM {
            if osType != (config.osType ?? "other") { update.set("ostype", osType) }
            if agent != config.agentEnabled {
                var property = PropertyString(parsing: config["agent"] ?? "")
                if property.items.first?.key == nil, !property.items.isEmpty {
                    property.items[0].value = agent ? "1" : "0"
                } else {
                    property["enabled"] = agent ? "1" : "0"
                }
                update.set("agent", property.stringValue)
            }
            for (key, value, defaultValue) in [("tablet", tablet, true), ("acpi", acpi, true), ("kvm", kvm, true), ("freeze", freeze, false), ("localtime", localTime, false)] {
                let current = config[key].map { $0 == "1" } ?? defaultValue
                if value != current { update.set(key, value) }
            }
        } else {
            var features = PropertyString(parsing: config["features"] ?? "")
            if nesting != (features["nesting"] == "1") {
                features["nesting"] = nesting ? "1" : nil
                update.set("features", features.items.isEmpty ? nil : features.stringValue)
            }
        }
        return update.isEmpty ? nil : update
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
