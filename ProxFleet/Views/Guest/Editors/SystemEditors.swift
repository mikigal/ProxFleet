import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

extension CPUModel {
    /// CPU types for a picker: common ones first, then the rest of what the node offers.
    static func pickerNames(_ models: [CPUModel], including current: String) -> [String] {
        var names = Set(models.map(\.name))
        names.formUnion(["host", "x86-64-v2-AES", "x86-64-v3", "kvm64"])
        if !current.isEmpty { names.insert(current) }
        let preferred = ["host", "x86-64-v2-AES", "x86-64-v3", "x86-64-v4", "kvm64", "qemu64"]
        return preferred.filter(names.contains) + names.subtracting(preferred).sorted()
    }
}

/// Sockets, cores, CPU type, flags and scheduling limits.
struct CPUEditor: View {
    let detail: GuestDetail
    let original: CPUDraft
    @State private var draft: CPUDraft
    @State private var models: [CPUModel] = []

    private var isVM: Bool { detail.reference.kind == .virtualMachine }

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        let draft = CPUDraft(config, isVM: detail.reference.kind == .virtualMachine)
        original = draft
        _draft = State(initialValue: draft)
    }

    var body: some View {
        ConfigEditor(title: "Processor", detail: detail, makeUpdate: update, privilege: "VM.Config.CPU") { errors in
            Section {
                if isVM {
                    NumberField(title: "Sockets", value: $draft.sockets, range: 1...16)
                    FieldError(message: errors["sockets"])
                    NumberField(title: "Cores", value: $draft.cores, range: 1...512)
                } else {
                    Toggle("Limit Cores", isOn: Binding(get: { draft.cores > 0 }, set: { draft.cores = $0 ? 1 : 0 }))
                    if draft.cores > 0 {
                        NumberField(title: "Cores", value: $draft.cores, range: 1...8192)
                    }
                }
                FieldError(message: errors["cores"])
                if isVM {
                    Picker("vCPUs at Start", selection: $draft.vcpus) {
                        Text("All").tag(0)
                        ForEach(1...max(1, draft.sockets * draft.cores), id: \.self) { Text("\($0)").tag($0) }
                    }
                    FieldError(message: errors["vcpus"])
                }
            } footer: {
                if isVM {
                    Text("Total: \(Format.cores(draft.sockets * draft.cores)). With CPU hotplug, fewer vCPUs can be active at start.")
                } else {
                    Text("Without a limit the container can use all cores of the host.")
                }
            }
            if isVM {
                Section {
                    Picker("Type", selection: $draft.model) {
                        Text("Default (kvm64)").tag("")
                        ForEach(modelNames, id: \.self) { Text($0).tag($0) }
                    }
                    FieldError(message: errors["cpu"])
                    NavigationLink {
                        CPUFlagsEditor(flags: $draft.flags)
                    } label: {
                        LabeledContent("Extra CPU Flags", value: draft.flags.isEmpty ? String(localized: "None") : "\(draft.flags.count)")
                    }
                    Toggle("NUMA", isOn: $draft.numa)
                } footer: {
                    Text("“host” gives the best performance but prevents live migration to nodes with a different CPU.")
                }
            }
            Section {
                LabeledContent("CPU Limit") {
                    TextField("Unlimited", value: Binding(get: { draft.limit > 0 ? draft.limit : nil }, set: { draft.limit = $0 ?? 0 }), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                FieldError(message: errors["cpulimit"])
                LabeledContent("CPU Units") {
                    TextField("100", text: $draft.units)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                FieldError(message: errors["cpuunits"])
                if isVM {
                    LabeledContent("CPU Affinity") {
                        TextField("All Cores", text: $draft.affinity)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    FieldError(message: errors["affinity"])
                }
            } header: {
                Text("Scheduling")
            } footer: {
                Text("Limit is in cores, 0 for none. Units weigh this guest against others when the host is busy. Affinity pins the guest to host cores, e.g. 0-3,8.")
            }
        }
        .task {
            if isVM { models = await detail.load(PVE.cpuModels(node: detail.reference.node)) }
        }
    }

    private var modelNames: [String] { CPUModel.pickerNames(models, including: draft.model) }

    private func update() -> GuestConfigUpdate? {
        let update = draft.changes(from: original)
        return update.isEmpty ? nil : update
    }
}

/// CPU flags set on top of the CPU type.
struct CPUFlagsEditor: View {
    @Binding var flags: [String: Bool]

    private static let descriptions: [String: LocalizedStringKey] = [
        "md-clear": "MDS mitigation, needed on Intel CPUs",
        "pcid": "Meltdown fix cost reduction on Westmere, Sandy and Ivy Bridge",
        "spec-ctrl": "Spectre v1 and v2 protection, needed on Intel CPUs",
        "ssbd": "Spectre V4 protection on Intel CPUs",
        "ibpb": "Spectre v1 and v2 protection on AMD CPUs",
        "virt-ssbd": "Basis for Spectre V4 protection on AMD CPUs",
        "amd-ssbd": "Spectre V4 protection on AMD CPUs",
        "amd-no-ssb": "Tells the guest it is not affected by Spectre V4",
        "pdpe1gb": "1 GiB huge pages in the guest",
        "hv-tlbflush": "Faster TLB flushes for Windows guests",
        "hv-evmcs": "Faster nested virtualization for Windows guests on Intel",
        "aes": "Hardware AES, needed for fast encryption",
    ]

    var body: some View {
        Form {
            Section {
                ForEach(CPUDraft.knownFlags + flags.keys.filter { !CPUDraft.knownFlags.contains($0) }.sorted(), id: \.self) { flag in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(flag).font(.body.monospaced())
                            if let description = Self.descriptions[flag] {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Picker(flag, selection: Binding(get: { flags[flag] }, set: { flags[flag] = $0 })) {
                            Text("Default").tag(Bool?.none)
                            Text("On").tag(Bool?.some(true))
                            Text("Off").tag(Bool?.some(false))
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } footer: {
                Text("Default uses what the CPU type provides. Flags the host CPU lacks stop the VM from starting.")
            }
        }
        .navigationTitle("CPU Flags")
        .navigationBarTitleDisplayMode(.inline)
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
    @State private var shares: String

    private var isVM: Bool { detail.reference.kind == .virtualMachine }

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        self.config = config
        let memory = config.memoryMiB ?? 512
        _memory = State(initialValue: memory)
        _ballooning = State(initialValue: config.balloonMiB != 0)
        _minimum = State(initialValue: config.balloonMiB.flatMap { $0 > 0 ? $0 : nil } ?? memory)
        _swap = State(initialValue: config.swapMiB ?? 512)
        _shares = State(initialValue: config["shares"] ?? "")
    }

    var body: some View {
        ConfigEditor(title: "Memory", detail: detail, makeUpdate: update, privilege: "VM.Config.Memory") { errors in
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
                        LabeledContent("Shares") {
                            TextField("1000", text: $shares)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        FieldError(message: errors["shares"])
                    }
                } footer: {
                    Text("With ballooning, the host can reclaim memory down to the minimum when it runs low. Shares weigh this VM against others when memory is reclaimed. Needs the balloon driver in the guest.")
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
            let newShares = shares.trimmingCharacters(in: .whitespaces)
            if newShares != (config["shares"] ?? "") { update.set("shares", newShares.isEmpty ? nil : newShares) }
        } else if swap != config.swapMiB {
            update.set("swap", String(swap))
        }
        return update.isEmpty ? nil : update
    }
}

/// BIOS, machine type, SCSI controller and display of a VM.
struct VMSystemEditor: View {
    let detail: GuestDetail
    let original: VMSystemDraft
    @State private var draft: VMSystemDraft
    @State private var machines: [MachineType] = []

    init(detail: GuestDetail, config: GuestConfig) {
        self.detail = detail
        let draft = VMSystemDraft(config)
        original = draft
        _draft = State(initialValue: draft)
    }

    var body: some View {
        ConfigEditor(title: "System", detail: detail, makeUpdate: update, privilege: "VM.Config.HWType") { errors in
            Section {
                Picker("BIOS", selection: $draft.bios) {
                    Text("SeaBIOS").tag("seabios")
                    Text("OVMF (UEFI)").tag("ovmf")
                }
                FieldError(message: errors["bios"])
                Picker("Machine", selection: $draft.machineFamily) {
                    Text("i440fx").tag("i440fx")
                    Text("q35").tag("q35")
                    if !["i440fx", "q35"].contains(draft.machineFamily) {
                        Text(draft.machineFamily).tag(draft.machineFamily)
                    }
                }
                if ["i440fx", "q35"].contains(draft.machineFamily) {
                    Picker("Version", selection: $draft.machineVersion) {
                        Text("Latest").tag("")
                        ForEach(versions, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("vIOMMU", selection: $draft.viommu) {
                    Text("None").tag("")
                    Text("Intel (AMD Compatible)").tag("intel")
                    Text("VirtIO").tag("virtio")
                }
                FieldError(message: errors["machine"])
            } footer: {
                Text("UEFI needs an EFI disk to store its settings. Changing BIOS or machine type can stop the guest from booting. Pin a version to keep Windows guests from seeing new hardware after updates. The Intel vIOMMU needs q35.")
            }
            Section {
                Picker("SCSI Controller", selection: $draft.scsiController) {
                    ForEach(VMSystemDraft.scsiControllers, id: \.self) { Text($0).tag($0) }
                }
                FieldError(message: errors["scsihw"])
            }
            Section {
                Picker("Graphic Card", selection: $draft.display) {
                    ForEach(VMSystemDraft.displays, id: \.id) { Text($0.title).tag($0.id) }
                }
                if !draft.display.hasPrefix("serial"), draft.display != "none" {
                    Picker("Memory", selection: $draft.displayMemory) {
                        Text("Default").tag(0)
                        ForEach([4, 8, 16, 32, 64, 128, 256, 512], id: \.self) { Text("\($0) MiB").tag($0) }
                    }
                    Picker("Clipboard", selection: $draft.clipboard) {
                        Text("Default (SPICE)").tag("")
                        Text("VNC").tag("vnc")
                    }
                }
                FieldError(message: errors["vga"])
            } header: {
                Text("Display")
            } footer: {
                Text("VNC clipboard sharing needs the QEMU guest agent and spice-vdagent in the guest; it disables live migration.")
            }
        }
        .task { machines = await detail.load(PVE.machineTypes(node: detail.reference.node)) }
    }

    private var versions: [String] {
        var versions = machines.filter { $0.type == draft.machineFamily }.compactMap { machine in
            let prefix = draft.machineFamily == "q35" ? "pc-q35-" : "pc-i440fx-"
            return machine.id.hasPrefix(prefix) ? String(machine.id.dropFirst(prefix.count)) : nil
        }
        if !draft.machineVersion.isEmpty, !versions.contains(draft.machineVersion) { versions.insert(draft.machineVersion, at: 0) }
        return versions
    }

    private func update() -> GuestConfigUpdate? {
        let update = draft.changes(from: original)
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
