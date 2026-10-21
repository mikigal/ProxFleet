import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Moves a disk or container volume to another storage.
struct MoveDiskView: View {
    let detail: GuestDetail
    let disk: GuestDisk
    let onFinished: () -> Void
    @State private var storage = ""
    @State private var format = ""
    @State private var deleteSource = true
    @State private var storages: [StorageInfo] = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var isVM: Bool { detail.reference.kind == .virtualMachine }
    private var currentStorage: String { String(disk.volume.prefix { $0 != ":" }) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Volume", value: disk.volume)
                Picker("Target Storage", selection: $storage) {
                    ForEach(storages.filter { $0.storage != currentStorage }) { info in
                        Text(storageLabel(info)).tag(info.storage)
                    }
                }
                if isVM {
                    Picker("Format", selection: $format) {
                        Text("Keep Current").tag("")
                        Text("Raw").tag("raw")
                        Text("QEMU Image (qcow2)").tag("qcow2")
                        Text("VMware Image (vmdk)").tag("vmdk")
                    }
                }
                Toggle("Delete Source", isOn: $deleteSource)
            } footer: {
                Text("Without Delete Source, the old copy stays as an unused disk. Formats other than raw need a file-based storage.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Move \(disk.key)")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Move", isWorking: isWorking) { Task { await move() } }
                    .disabled(storage.isEmpty)
            }
        }
        .task {
            storages = await detail.load(PVE.storages(node: detail.reference.node, content: isVM ? "images" : "rootdir")).filter(\.isActive)
            if storage.isEmpty { storage = storages.first { $0.storage != currentStorage }?.storage ?? "" }
        }
    }

    private func storageLabel(_ info: StorageInfo) -> String {
        guard let available = info.available else { return info.storage }
        return "\(info.storage) (\(Format.bytes(available)) free)"
    }

    private func move() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await detail.run(PVE.moveDisk(detail.reference, disk: disk.key, storage: storage, format: format.isEmpty ? nil : format, deleteSource: deleteSource))
            onFinished()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Hands a disk over to another guest of the same kind on the same node.
struct ReassignDiskView: View {
    let detail: GuestDetail
    let disk: GuestDisk
    let onFinished: () -> Void
    @State private var target: Int?
    @State private var bus: DiskBus = .scsi
    @State private var targetConfig: GuestConfig?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var isVM: Bool { detail.reference.kind == .virtualMachine }

    private var candidates: [GuestSummary] {
        (detail.connection.snapshot?.guests ?? [])
            .filter { $0.node == detail.reference.node && $0.kind == detail.reference.kind && $0.vmid != detail.reference.vmid }
            .sorted { $0.vmid < $1.vmid }
    }

    private var targetKey: String? {
        guard let targetConfig else { return nil }
        if disk.isUnused { return targetConfig.nextFreeKey(prefix: "unused", slots: 256) }
        return isVM ? targetConfig.nextFreeKey(prefix: bus.rawValue, slots: bus.slots) : targetConfig.nextFreeKey(prefix: "mp", slots: 256)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Volume", value: disk.volume)
                Picker("Target Guest", selection: $target) {
                    Text("Choose").tag(Int?.none)
                    ForEach(candidates) { guest in
                        Text("\(guest.vmid) – \(guest.name)").tag(Int?.some(guest.vmid))
                    }
                }
                if isVM, !disk.isUnused {
                    Picker("Bus", selection: $bus) {
                        ForEach(DiskBus.allCases) { Text($0.title).tag($0) }
                    }
                }
                if let targetKey {
                    LabeledContent("Attached As", value: targetKey)
                }
            } footer: {
                Text("The disk is renamed for the target guest and removed from this one. Only guests on the same node are listed.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Reassign \(disk.key)")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Reassign", isWorking: isWorking) { Task { await reassign() } }
                    .disabled(targetKey == nil)
            }
        }
        .task(id: target) {
            targetConfig = nil
            guard let target else { return }
            let reference = GuestReference(node: detail.reference.node, vmid: target, kind: detail.reference.kind)
            targetConfig = try? await detail.connection.send(PVE.guestConfig(reference))
        }
    }

    private func reassign() async {
        guard let target, let targetKey else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await detail.run(PVE.reassignDisk(detail.reference, disk: disk.key, to: target, as: targetKey))
            onFinished()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Attaches an unused disk again, on a bus for VMs or at a path for containers.
struct AttachUnusedDiskEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    let disk: GuestDisk
    let onFinished: () -> Void
    @State private var bus: DiskBus = .scsi
    @State private var path = ""
    @State private var includeInBackup = true

    private var isVM: Bool { detail.reference.kind == .virtualMachine }
    private var key: String? {
        isVM ? config.nextFreeKey(prefix: bus.rawValue, slots: bus.slots) : config.nextFreeKey(prefix: "mp", slots: 256)
    }

    var body: some View {
        ConfigEditor(title: "Attach \(disk.key)", detail: detail, makeUpdate: update, onSaved: onFinished) { errors in
            Section {
                LabeledContent("Volume", value: disk.volume)
                if isVM {
                    Picker("Bus", selection: $bus) {
                        ForEach(DiskBus.allCases) { Text($0.title).tag($0) }
                    }
                } else {
                    LabeledContent("Path in Container") {
                        TextField("/data", text: $path)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Toggle("Include in Backups", isOn: $includeInBackup)
                }
                if let key {
                    LabeledContent("Attached As", value: key)
                    FieldError(message: errors[key])
                }
            }
        }
    }

    private func update() -> GuestConfigUpdate? {
        guard let key else { return nil }
        var update = GuestConfigUpdate()
        if isVM {
            update.set(key, disk.volume)
        } else {
            guard path.hasPrefix("/") else { return nil }
            update.set(key, MountPointDraft.newValue(source: disk.volume, sizeGiB: nil, path: path, includeInBackup: includeInBackup, readOnly: false))
        }
        return update
    }
}

/// Bandwidth and operation limits of a VM disk.
struct DiskLimitsEditor: View {
    @Binding var limits: [String: String]

    var body: some View {
        Form {
            Section {
                field("Read", "mbps_rd", unit: "MB/s")
                field("Write", "mbps_wr", unit: "MB/s")
                field("Read Burst", "mbps_rd_max", unit: "MB/s")
                field("Write Burst", "mbps_wr_max", unit: "MB/s")
            } header: {
                Text("Bandwidth")
            }
            Section {
                field("Read", "iops_rd", unit: "ops/s")
                field("Write", "iops_wr", unit: "ops/s")
                field("Read Burst", "iops_rd_max", unit: "ops/s")
                field("Write Burst", "iops_wr_max", unit: "ops/s")
            } header: {
                Text("Operations")
            } footer: {
                Text("Empty means unlimited.")
            }
        }
        .navigationTitle("Limits")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func field(_ title: LocalizedStringKey, _ key: String, unit: String) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("Unlimited", text: Binding(get: { limits[key] ?? "" }, set: { limits[key] = $0 }))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
