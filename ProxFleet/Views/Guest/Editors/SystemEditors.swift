import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Sockets, cores, CPU type and limits.
struct CPUEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var sockets: Int
    @State private var cores: Int
    @State private var cpuType: String
    @State private var limit: Double
    @State private var numa: Bool
    @State private var models: [CPUModel] = []

    private var isVM: Bool { detail.reference.kind == .virtualMachine }

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        self.config = config
        _sockets = State(initialValue: config.sockets)
        _cores = State(initialValue: config.cores ?? 1)
        _cpuType = State(initialValue: config.cpuType ?? "")
        _limit = State(initialValue: config["cpulimit"].flatMap(Double.init) ?? 0)
        _numa = State(initialValue: config["numa"] == "1")
    }

    var body: some View {
        ConfigEditor(title: "Processor", detail: detail, makeUpdate: update) { errors in
            Section {
                if isVM {
                    NumberField(title: "Sockets", value: $sockets, range: 1...16)
                    FieldError(message: errors["sockets"])
                }
                NumberField(title: "Cores", value: $cores, range: 1...512)
                FieldError(message: errors["cores"])
            } footer: {
                if isVM { Text("Total: \(Format.cores(sockets * cores))") }
            }
            if isVM {
                Section {
                    Picker("Type", selection: $cpuType) {
                        Text("Default").tag("")
                        ForEach(modelNames, id: \.self) { Text($0).tag($0) }
                    }
                    FieldError(message: errors["cpu"])
                    Toggle("NUMA", isOn: $numa)
                } footer: {
                    Text("“host” gives the best performance but prevents live migration to nodes with a different CPU.")
                }
            }
            Section {
                LabeledContent("CPU Limit") {
                    TextField("Unlimited", value: $limit, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                FieldError(message: errors["cpulimit"])
            } footer: {
                Text("Maximum CPU time in cores, 0 for no limit.")
            }
        }
        .task {
            if isVM { models = await detail.load(PVE.cpuModels(node: detail.reference.node)) }
        }
    }

    private var modelNames: [String] {
        var names = Set(models.map(\.name))
        names.formUnion(["host", "x86-64-v2-AES", "x86-64-v3", "kvm64"])
        if !cpuType.isEmpty { names.insert(cpuType) }
        let preferred = ["host", "x86-64-v2-AES", "x86-64-v3", "x86-64-v4", "kvm64", "qemu64"]
        return preferred.filter(names.contains) + names.subtracting(preferred).sorted()
    }

    private func update() -> GuestConfigUpdate? {
        var update = GuestConfigUpdate()
        if isVM, sockets != config.sockets { update.set("sockets", String(sockets)) }
        if cores != (config.cores ?? 1) { update.set("cores", String(cores)) }
        if isVM, cpuType != (config.cpuType ?? "") {
            if cpuType.isEmpty {
                update.set("cpu", nil)
            } else {
                // Keep flags and other CPU options, only replace the model.
                var property = PropertyString(parsing: config["cpu"] ?? "")
                if property.items.first?.key == nil, !property.items.isEmpty {
                    property.items[0].value = cpuType
                } else if property["cputype"] != nil {
                    property["cputype"] = cpuType
                } else {
                    property.items.insert((key: nil, value: cpuType), at: 0)
                }
                update.set("cpu", property.stringValue)
            }
        }
        let currentLimit = config["cpulimit"].flatMap(Double.init) ?? 0
        if limit != currentLimit { update.set("cpulimit", limit > 0 ? String(limit) : nil) }
        if isVM, numa != (config["numa"] == "1") { update.set("numa", numa) }
        return update.isEmpty ? nil : update
    }
}

/// Memory, ballooning for VMs and swap for containers.
struct MemoryEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var memory: Int
    @State private var ballooning: Bool
    @State private var minimum: Int
    @State private var swap: Int

    private var isVM: Bool { detail.reference.kind == .virtualMachine }

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        self.config = config
        let memory = config.memoryMiB ?? 512
        _memory = State(initialValue: memory)
        _ballooning = State(initialValue: config.balloonMiB != 0)
        _minimum = State(initialValue: config.balloonMiB.flatMap { $0 > 0 ? $0 : nil } ?? memory)
        _swap = State(initialValue: config.swapMiB ?? 512)
    }

    var body: some View {
        ConfigEditor(title: "Memory", detail: detail, makeUpdate: update) { errors in
            Section {
                NumberField(title: "Memory", value: $memory, range: 16...4_194_304, step: 512, unit: "MiB")
                FieldError(message: errors["memory"])
            } footer: {
                Text(Format.bytes(Int64(memory) * 1_048_576))
            }
            if isVM {
                Section {
                    Toggle("Ballooning Device", isOn: $ballooning)
                    if ballooning {
                        NumberField(title: "Minimum", value: $minimum, range: 16...memory, step: 256, unit: "MiB")
                        FieldError(message: errors["balloon"])
                    }
                } footer: {
                    Text("With ballooning, the host can reclaim memory down to the minimum when it runs low. Needs the balloon driver in the guest.")
                }
            } else {
                Section {
                    NumberField(title: "Swap", value: $swap, range: 0...4_194_304, step: 256, unit: "MiB")
                    FieldError(message: errors["swap"])
                }
            }
        }
    }

    private func update() -> GuestConfigUpdate? {
        var update = GuestConfigUpdate()
        if memory != config.memoryMiB { update.set("memory", String(memory)) }
        if isVM {
            // No value means ballooning down to the full memory, 0 disables the device.
            // Without a minimum set, the minimum follows the memory size until the user changes it.
            let followsMemory = config.balloonMiB == nil && minimum == (config.memoryMiB ?? 512)
            let target: String? = !ballooning ? "0" : (followsMemory || minimum >= memory ? nil : String(minimum))
            if target != config["balloon"] { update.set("balloon", target) }
        } else if swap != config.swapMiB {
            update.set("swap", String(swap))
        }
        return update.isEmpty ? nil : update
    }
}

/// BIOS, machine type, SCSI controller and display of a VM.
struct VMSystemEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var bios: String
    @State private var machineFamily: String
    @State private var scsiController: String
    @State private var display: String

    static let scsiControllers = ["virtio-scsi-single", "virtio-scsi-pci", "lsi", "lsi53c810", "megasas", "pvscsi"]
    static let displays = ["": "Default", "std": "Standard VGA", "virtio": "VirtIO-GPU", "qxl": "SPICE (qxl)", "vmware": "VMware compatible", "serial0": "Serial terminal 0", "none": "None"]

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        self.config = config
        _bios = State(initialValue: config.bios ?? "seabios")
        _machineFamily = State(initialValue: (config.machine ?? "").contains("q35") ? "q35" : "i440fx")
        _scsiController = State(initialValue: config["scsihw"] ?? "lsi")
        _display = State(initialValue: config["vga"].map { PropertyString(parsing: $0).defaultValue ?? $0 } ?? "")
    }

    var body: some View {
        ConfigEditor(title: "System", detail: detail, makeUpdate: update) { errors in
            Section {
                Picker("BIOS", selection: $bios) {
                    Text("SeaBIOS").tag("seabios")
                    Text("OVMF (UEFI)").tag("ovmf")
                }
                FieldError(message: errors["bios"])
                Picker("Machine", selection: $machineFamily) {
                    Text("i440fx").tag("i440fx")
                    Text("q35").tag("q35")
                }
                FieldError(message: errors["machine"])
            } footer: {
                Text("UEFI needs an EFI disk to store its settings. Changing BIOS or machine type can stop the guest from booting.")
            }
            Section {
                Picker("SCSI Controller", selection: $scsiController) {
                    ForEach(Self.scsiControllers, id: \.self) { Text($0).tag($0) }
                }
                Picker("Display", selection: $display) {
                    ForEach(Self.displays.keys.sorted(), id: \.self) { key in
                        Text(Self.displays[key] ?? key).tag(key)
                    }
                }
            }
        }
    }

    private func update() -> GuestConfigUpdate? {
        var update = GuestConfigUpdate()
        if bios != (config.bios ?? "seabios") { update.set("bios", bios == "seabios" ? nil : bios) }
        let currentFamily = (config.machine ?? "").contains("q35") ? "q35" : "i440fx"
        if machineFamily != currentFamily { update.set("machine", machineFamily == "q35" ? "q35" : nil) }
        if scsiController != (config["scsihw"] ?? "lsi") { update.set("scsihw", scsiController) }
        let currentDisplay = config["vga"].map { PropertyString(parsing: $0).defaultValue ?? $0 } ?? ""
        if display != currentDisplay { update.set("vga", display.isEmpty ? nil : display) }
        return update.isEmpty ? nil : update
    }
}

/// Free-text notes, shown in the web interface's Summary.
struct NotesEditor: View {
    let detail: GuestDetail
    let config: GuestConfig
    @State private var notes: String

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        self.config = config
        _notes = State(initialValue: config.description ?? "")
    }

    var body: some View {
        ConfigEditor(title: "Notes", detail: detail, makeUpdate: update, footer: "Notes are saved immediately, even while the guest runs.", privilege: "VM.Config.Options") { _ in
            Section {
                TextEditor(text: $notes)
                    .frame(minHeight: 220)
                    .accessibilityIdentifier("notes")
            } footer: {
                Text("Markdown is supported in the web interface.")
            }
        }
    }

    private func update() -> GuestConfigUpdate? {
        guard notes != (config.description ?? "") else { return nil }
        var update = GuestConfigUpdate()
        update.set("description", notes.isEmpty ? nil : notes)
        return update
    }
}
