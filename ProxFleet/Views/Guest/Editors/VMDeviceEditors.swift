import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

extension VMDeviceKind {
    var title: LocalizedStringKey {
        switch self {
        case .efiDisk: "EFI Disk"
        case .tpmState: "TPM State"
        case .usb: "USB Device"
        case .pci: "PCI Device"
        case .serial: "Serial Port"
        case .parallel: "Parallel Port"
        case .audio: "Audio Device"
        case .rng: "VirtIO RNG"
        case .virtioFS: "VirtioFS"
        case .ivshmem: "Shared Memory (ivshmem)"
        }
    }

    var systemImage: String {
        switch self {
        case .efiDisk: "lock.shield"
        case .tpmState: "key"
        case .usb: "cable.connector"
        case .pci: "memorychip"
        case .serial: "terminal"
        case .parallel: "printer"
        case .audio: "speaker.wave.2"
        case .rng: "dice"
        case .virtioFS: "folder"
        case .ivshmem: "square.stack.3d.up"
        }
    }

    /// Short description of a configured device for its row.
    func summary(of value: String) -> String {
        switch self {
        case .usb:
            let draft = USBDeviceDraft(value)
            switch draft.source {
            case .spice: return String(localized: "SPICE port")
            case .host: return draft.host + (draft.usb3 ? " · USB 3" : "")
            case .mapping: return String(localized: "Mapping \(draft.mapping)")
            }
        case .pci:
            let draft = PCIDeviceDraft(value)
            return draft.usesMapping ? String(localized: "Mapping \(draft.mapping)") : draft.host
        case .audio: return AudioDeviceDraft(value).device
        case .rng: return RNGDeviceDraft(value).source
        case .virtioFS: return VirtioFSDraft(value).directory
        case .ivshmem: return Format.bytes(Int64(IVSHMEMDraft(value).sizeMiB) * 1_048_576)
        default: return value
        }
    }
}

/// Lists the kinds of devices that can still be added.
struct AddDeviceList: View {
    let detail: GuestDetail
    /// The configuration as it was when the list opened; the list follows later changes.
    let initialConfig: GuestConfig

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        initialConfig = config
    }

    private var config: GuestConfig { detail.config ?? initialConfig }

    var body: some View {
        List {
            ForEach(VMDeviceKind.allCases) { kind in
                if kind.nextKey(in: config) != nil, kind != .efiDisk || config.bios == "ovmf" {
                    NavigationLink {
                        VMDeviceEditor(detail: detail, config: config, kind: kind, key: nil)
                    } label: {
                        Label(kind.title, systemImage: kind.systemImage)
                    }
                    .accessibilityIdentifier("addDevice.\(kind.rawValue)")
                }
            }
        }
        .navigationTitle("Add Device")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Edits an existing device (`key`) or adds a new one of a kind.
struct VMDeviceEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let kind: VMDeviceKind
    let key: String?

    var body: some View {
        switch kind {
        case .efiDisk: EFIDiskEditor(detail: detail, config: config)
        case .tpmState: TPMStateEditor(detail: detail, config: config)
        case .usb: USBDeviceEditor(detail: detail, config: config, key: key)
        case .pci: PCIDeviceEditor(detail: detail, config: config, key: key)
        case .serial, .parallel: PortEditor(detail: detail, config: config, kind: kind, key: key)
        case .audio: AudioDeviceEditor(detail: detail, config: config, key: key)
        case .rng: RNGDeviceEditor(detail: detail, config: config, key: key)
        case .virtioFS: VirtioFSEditor(detail: detail, config: config, key: key)
        case .ivshmem: IVSHMEMEditor(detail: detail, config: config, key: key)
        }
    }
}

/// Shared form for device editors: saving to the device's key and removing it.
private struct DeviceForm<Content: View>: View {
    let detail: GuestDetail
    let config: GuestConfig
    let kind: VMDeviceKind
    let key: String?
    /// The device's value, or nil while the form is incomplete.
    let value: String?
    /// The current value in the same normalized form, to detect changes.
    let original: String?
    var footer: LocalizedStringKey?
    @ViewBuilder let content: (_ fieldErrors: [String: String]) -> Content
    @State private var confirmsRemoval = false
    @Environment(\.dismiss) private var dismiss

    /// New devices take the next free key of the latest configuration, so adding twice never reuses a key.
    private var targetKey: String? { key ?? kind.nextKey(in: detail.config ?? config) }

    var body: some View {
        ConfigEditor(title: key.map { LocalizedStringKey($0) } ?? kind.title, detail: detail, makeUpdate: update, footer: footer, privilege: kind.privilege) { errors in
            content(errors)
            if let targetKey, let message = errors[targetKey] {
                Section { FieldError(message: message) }
            }
            if let key {
                Section {
                    Button("Remove Device", role: .destructive) { confirmsRemoval = true }
                }
                .alert("Remove \(key)?", isPresented: $confirmsRemoval) {
                    Button("Cancel", role: .cancel) {}
                    Button("Remove", role: .destructive) { Task { await remove(key) } }
                }
            }
        }
    }

    private func update() -> GuestConfigUpdate? {
        guard let targetKey, let value, value != original else { return nil }
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
}

private extension GuestDetail {
    var isRoot: Bool { connection.profile.userID == "root@pam" }
}

// MARK: - EFI and TPM

private struct EFIDiskEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var storage = ""
    @State private var preEnrolledKeys = true
    @State private var storages: [StorageInfo] = []

    var body: some View {
        DeviceForm(detail: detail, config: config, kind: .efiDisk, key: nil, value: storage.isEmpty ? nil : GuestConfig.efiDiskValue(storage: storage, preEnrolledKeys: preEnrolledKeys), original: nil) { _ in
            Section {
                StoragePicker(storage: $storage, storages: storages)
                Toggle("Pre-Enroll Keys", isOn: $preEnrolledKeys)
            } footer: {
                Text("Stores the UEFI settings. Pre-enrolled keys turn on Secure Boot with the Microsoft keys, which Windows 11 expects.")
            }
        }
        .task { storages = await loadImageStorages(detail, into: $storage) }
    }
}

private struct TPMStateEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var storage = ""
    @State private var version = "v2.0"
    @State private var storages: [StorageInfo] = []

    var body: some View {
        DeviceForm(detail: detail, config: config, kind: .tpmState, key: nil, value: storage.isEmpty ? nil : GuestConfig.tpmStateValue(storage: storage, version: version), original: nil) { _ in
            Section {
                StoragePicker(storage: $storage, storages: storages)
                Picker("Version", selection: $version) {
                    Text("2.0").tag("v2.0")
                    Text("1.2").tag("v1.2")
                }
            } footer: {
                Text("A virtual TPM chip, needed by Windows 11 and for measured boot.")
            }
        }
        .task { storages = await loadImageStorages(detail, into: $storage) }
    }
}

private struct StoragePicker: View {
    @Binding var storage: String
    let storages: [StorageInfo]

    var body: some View {
        Picker("Storage", selection: $storage) {
            ForEach(storages) { info in
                Text(info.available.map { "\(info.storage) (\(Format.bytes($0)) free)" } ?? info.storage).tag(info.storage)
            }
        }
    }
}

@MainActor
private func loadImageStorages(_ detail: GuestDetail, into storage: Binding<String>) async -> [StorageInfo] {
    let storages = await detail.load(PVE.storages(node: detail.reference.node, content: "images")).filter(\.isActive)
    if storage.wrappedValue.isEmpty { storage.wrappedValue = storages.first?.storage ?? "" }
    return storages
}

// MARK: - USB and PCI

private struct USBDeviceEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let key: String?
    @State private var draft: USBDeviceDraft
    @State private var devices: [NodeUSBDevice] = []
    @State private var mappings: [ResourceMapping] = []

    init(detail: GuestDetail, config: GuestConfig, key: String?) {
        self.detail = detail
        self.config = config
        self.key = key
        _draft = State(initialValue: key.flatMap { config[$0] }.map(USBDeviceDraft.init) ?? USBDeviceDraft())
    }

    var body: some View {
        DeviceForm(detail: detail, config: config, kind: .usb, key: key, value: draft.isComplete ? draft.stringValue : nil, original: key.flatMap { config[$0] }.map { USBDeviceDraft($0).stringValue }) { _ in
            Section {
                Picker("Source", selection: $draft.source) {
                    Text("SPICE Port").tag(USBDeviceDraft.Source.spice)
                    Text("Host Device").tag(USBDeviceDraft.Source.host)
                    Text("Mapping").tag(USBDeviceDraft.Source.mapping)
                }
                switch draft.source {
                case .spice:
                    EmptyView()
                case .host:
                    if detail.isRoot {
                        Picker("Device", selection: $draft.host) {
                            Text("Choose").tag("")
                            ForEach(devices.filter { !$0.isHub }) { device in
                                Text(deviceLabel(device)).tag(device.deviceID)
                            }
                            ForEach(devices.filter { !$0.isHub }.compactMap(\.portID), id: \.self) { port in
                                Text("Port \(port)").tag(port)
                            }
                            if !draft.host.isEmpty, !knownHostIDs.contains(draft.host) {
                                Text(draft.host).tag(draft.host)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    } else {
                        LabeledContent("Device", value: draft.host.isEmpty ? "—" : draft.host)
                            .locked("Only root@pam can pass host devices directly. Ask an administrator for a resource mapping instead.")
                    }
                case .mapping:
                    Picker("Mapping", selection: $draft.mapping) {
                        Text("Choose").tag("")
                        ForEach(mappingNames, id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("USB 3", isOn: $draft.usb3)
            } footer: {
                Text("A SPICE port lets a SPICE client redirect a USB device. Passing by vendor and product follows the device to any port; passing a port passes whatever is plugged into it.")
            }
        }
        .task {
            if detail.isRoot { devices = await detail.load(PVE.usbDevices(node: detail.reference.node)) }
            mappings = await detail.load(PVE.resourceMappings("usb"))
        }
    }

    private var knownHostIDs: Set<String> {
        Set(devices.map(\.deviceID) + devices.compactMap(\.portID))
    }

    private var mappingNames: [String] {
        var names = mappings.map(\.id)
        if !draft.mapping.isEmpty, !names.contains(draft.mapping) { names.insert(draft.mapping, at: 0) }
        return names
    }

    private func deviceLabel(_ device: NodeUSBDevice) -> String {
        let name = [device.manufacturer, device.product].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? device.deviceID : "\(name) (\(device.deviceID))"
    }
}

private struct PCIDeviceEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let key: String?
    @State private var draft: PCIDeviceDraft
    @State private var devices: [NodePCIDevice] = []
    @State private var mappings: [ResourceMapping] = []

    init(detail: GuestDetail, config: GuestConfig, key: String?) {
        self.detail = detail
        self.config = config
        self.key = key
        var draft = key.flatMap { config[$0] }.map(PCIDeviceDraft.init) ?? PCIDeviceDraft()
        if key == nil {
            draft.usesMapping = detail.connection.profile.userID != "root@pam"
            draft.pcie = (config.machine ?? "").contains("q35")
        }
        _draft = State(initialValue: draft)
    }

    var body: some View {
        DeviceForm(detail: detail, config: config, kind: .pci, key: key, value: draft.isComplete ? draft.stringValue : nil, original: key.flatMap { config[$0] }.map { PCIDeviceDraft($0).stringValue }, footer: "PCI devices can only be added or removed while the VM is stopped.") { _ in
            Section {
                Picker("Source", selection: $draft.usesMapping) {
                    Text("Host Device").tag(false)
                    Text("Mapping").tag(true)
                }
                .pickerStyle(.segmented)
                if draft.usesMapping {
                    Picker("Mapping", selection: $draft.mapping) {
                        Text("Choose").tag("")
                        ForEach(mappingNames, id: \.self) { Text($0).tag($0) }
                    }
                } else if detail.isRoot {
                    Picker("Device", selection: $draft.host) {
                        Text("Choose").tag("")
                        ForEach(devices) { device in
                            VStack(alignment: .leading) {
                                Text(device.deviceName ?? device.id)
                                Text([device.id, device.vendorName, device.iommuGroup.flatMap { $0 >= 0 ? String(localized: "IOMMU group \($0)") : nil }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(device.id)
                        }
                        if !draft.host.isEmpty, !devices.contains(where: { $0.id == draft.host }) {
                            Text(draft.host).tag(draft.host)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Toggle("All Functions", isOn: $draft.allFunctions)
                } else {
                    LabeledContent("Device", value: draft.host.isEmpty ? "—" : draft.host)
                        .locked("Only root@pam can pass host devices directly. Ask an administrator for a resource mapping instead.")
                }
            } footer: {
                Text("The host needs IOMMU enabled. A device is unavailable to the host while the VM runs.")
            }
            Section("Options") {
                Toggle("PCI Express", isOn: $draft.pcie)
                Toggle("ROM-Bar", isOn: $draft.romBar)
                Toggle("Primary GPU", isOn: $draft.primaryGPU)
                LabeledContent("Mediated Device") {
                    TextField("None", text: $draft.mdev)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
        .task {
            if detail.isRoot { devices = await detail.load(PVE.pciDevices(node: detail.reference.node)) }
            mappings = await detail.load(PVE.resourceMappings("pci"))
        }
    }

    private var mappingNames: [String] {
        var names = mappings.map(\.id)
        if !draft.mapping.isEmpty, !names.contains(draft.mapping) { names.insert(draft.mapping, at: 0) }
        return names
    }
}

// MARK: - Ports

private struct PortEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let kind: VMDeviceKind
    let key: String?
    @State private var useSocket: Bool
    @State private var path: String

    init(detail: GuestDetail, config: GuestConfig, kind: VMDeviceKind, key: String?) {
        self.detail = detail
        self.config = config
        self.kind = kind
        self.key = key
        let value = key.flatMap { config[$0] } ?? (kind == .serial ? "socket" : "")
        _useSocket = State(initialValue: value == "socket")
        _path = State(initialValue: value == "socket" ? "" : value)
    }

    private var value: String? {
        if kind == .serial, useSocket { return "socket" }
        return path.hasPrefix("/dev/") ? path : nil
    }

    var body: some View {
        DeviceForm(detail: detail, config: config, kind: kind, key: key, value: value, original: key.flatMap { config[$0] }) { _ in
            Section {
                if kind == .serial {
                    Picker("Type", selection: $useSocket) {
                        Text("Socket").tag(true)
                        Text("Host Device").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                if kind == .parallel || !useSocket {
                    if detail.isRoot {
                        LabeledContent("Host Device") {
                            TextField(kind == .serial ? "/dev/ttyS0" : "/dev/parport0", text: $path)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    } else {
                        LabeledContent("Host Device", value: path.isEmpty ? "—" : path)
                            .locked("Only root@pam can pass host devices.")
                    }
                }
            } footer: {
                if kind == .serial {
                    Text("A socket serial port can be used as a text console, e.g. with Display set to Serial Terminal.")
                }
            }
        }
    }
}

// MARK: - Other devices

private struct AudioDeviceEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let key: String?
    @State private var draft: AudioDeviceDraft

    init(detail: GuestDetail, config: GuestConfig, key: String?) {
        self.detail = detail
        self.config = config
        self.key = key
        _draft = State(initialValue: key.flatMap { config[$0] }.map(AudioDeviceDraft.init) ?? AudioDeviceDraft())
    }

    var body: some View {
        DeviceForm(detail: detail, config: config, kind: .audio, key: key, value: draft.stringValue, original: key.flatMap { config[$0] }.map { AudioDeviceDraft($0).stringValue }) { _ in
            Section {
                Picker("Device", selection: $draft.device) {
                    Text("Intel HDA (ICH9)").tag("ich9-intel-hda")
                    Text("Intel HDA").tag("intel-hda")
                    Text("AC97").tag("AC97")
                }
                Picker("Backend", selection: $draft.driver) {
                    Text("SPICE").tag("spice")
                    Text("None").tag("none")
                }
            } footer: {
                Text("Sound is played through the SPICE console. Use ICH9 with q35 machines.")
            }
        }
    }
}

private struct RNGDeviceEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let key: String?
    @State private var draft: RNGDeviceDraft

    init(detail: GuestDetail, config: GuestConfig, key: String?) {
        self.detail = detail
        self.config = config
        self.key = key
        _draft = State(initialValue: key.flatMap { config[$0] }.map(RNGDeviceDraft.init) ?? RNGDeviceDraft())
    }

    var body: some View {
        DeviceForm(detail: detail, config: config, kind: .rng, key: key, value: draft.stringValue, original: key.flatMap { config[$0] }.map { RNGDeviceDraft($0).stringValue }) { _ in
            Section {
                Picker("Entropy Source", selection: $draft.source) {
                    ForEach(RNGDeviceDraft.sources, id: \.self) { Text($0).tag($0) }
                }
                NumberField(title: "Limit", value: $draft.maxBytes, range: 0...1_048_576, step: 256, unit: "bytes")
                NumberField(title: "Period", value: $draft.period, range: 1...60_000, step: 100, unit: "ms")
            } footer: {
                Text("Gives the guest entropy from the host. /dev/urandom is recommended; /dev/random can starve the host. A limit of 0 means unlimited.")
            }
        }
    }
}

private struct VirtioFSEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let key: String?
    @State private var draft: VirtioFSDraft
    @State private var mappings: [ResourceMapping] = []

    init(detail: GuestDetail, config: GuestConfig, key: String?) {
        self.detail = detail
        self.config = config
        self.key = key
        _draft = State(initialValue: key.flatMap { config[$0] }.map(VirtioFSDraft.init) ?? VirtioFSDraft())
    }

    var body: some View {
        DeviceForm(detail: detail, config: config, kind: .virtioFS, key: key, value: draft.directory.isEmpty ? nil : draft.stringValue, original: key.flatMap { config[$0] }.map { VirtioFSDraft($0).stringValue }) { _ in
            Section {
                Picker("Directory Mapping", selection: $draft.directory) {
                    Text("Choose").tag("")
                    ForEach(mappingNames, id: \.self) { Text($0).tag($0) }
                }
                if mappings.isEmpty {
                    Text("No directory mappings exist yet. An administrator creates them under Datacenter → Resource Mappings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Options") {
                Picker("Cache", selection: $draft.cache) {
                    Text("Default").tag("")
                    ForEach(VirtioFSDraft.cacheModes, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Toggle("Direct IO", isOn: $draft.directIO)
                Toggle("Extended Attributes", isOn: Binding(get: { draft.exposeXattr || draft.exposeACL }, set: { draft.exposeXattr = $0; if !$0 { draft.exposeACL = false } }))
                Toggle("POSIX ACLs", isOn: $draft.exposeACL)
            }
        }
        .task { mappings = await detail.load(PVE.resourceMappings("dir")) }
    }

    private var mappingNames: [String] {
        var names = mappings.map(\.id)
        if !draft.directory.isEmpty, !names.contains(draft.directory) { names.insert(draft.directory, at: 0) }
        return names
    }
}

private struct IVSHMEMEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let key: String?
    @State private var draft: IVSHMEMDraft

    init(detail: GuestDetail, config: GuestConfig, key: String?) {
        self.detail = detail
        self.config = config
        self.key = key
        _draft = State(initialValue: key.flatMap { config[$0] }.map(IVSHMEMDraft.init) ?? IVSHMEMDraft())
    }

    var body: some View {
        DeviceForm(detail: detail, config: config, kind: .ivshmem, key: key, value: draft.stringValue, original: key.flatMap { config[$0] }.map { IVSHMEMDraft($0).stringValue }) { _ in
            Section {
                NumberField(title: "Size", value: $draft.sizeMiB, range: 1...65_536, step: 32, unit: "MiB")
                LabeledContent("Name") {
                    TextField("pve-shm-\(detail.reference.vmid)", text: $draft.name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text("Memory shared with the host or other VMs under /dev/shm, e.g. for Looking Glass.")
            }
        }
    }
}
