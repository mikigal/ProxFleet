import Foundation
import ProxmoxCore

/// Processor settings of a VM or container.
public struct CPUDraft: OptionsDraft, Sendable {
    public let isVM: Bool
    public var sockets: Int
    /// For containers, 0 means all host cores.
    public var cores: Int
    /// VMs: vCPUs plugged in at start, 0 for all of sockets × cores.
    public var vcpus: Int
    /// Empty for the Proxmox default (kvm64).
    public var model: String
    /// CPU flags set explicitly: true adds the flag, false removes it.
    public var flags: [String: Bool]
    /// CPU time limit in cores, 0 for none.
    public var limit: Double
    /// Scheduler weight, empty for the default.
    public var units: String
    /// Host cores the guest may run on, e.g. `0-3,8`.
    public var affinity: String
    public var numa: Bool
    private var otherCPUOptions: PropertyString

    /// Flags the web interface offers, in its order.
    public static let knownFlags = [
        "md-clear", "pcid", "spec-ctrl", "ssbd", "ibpb", "virt-ssbd", "amd-ssbd", "amd-no-ssb", "pdpe1gb",
        "hv-tlbflush", "hv-evmcs", "aes",
    ]

    public init(_ config: GuestConfig, isVM: Bool) {
        self.isVM = isVM
        sockets = config["sockets"].flatMap { Int($0) } ?? 1
        cores = config["cores"].flatMap { Int($0) } ?? (isVM ? 1 : 0)
        vcpus = config["vcpus"].flatMap { Int($0) } ?? 0
        let cpu = PropertyString(parsing: config["cpu"] ?? "")
        model = cpu["cputype"] ?? cpu.defaultValue ?? ""
        flags = [:]
        for flag in (cpu["flags"] ?? "").split(separator: ";") {
            guard let sign = flag.first, sign == "+" || sign == "-" else { continue }
            flags[String(flag.dropFirst())] = sign == "+"
        }
        otherCPUOptions = PropertyString(items: cpu.items.filter { $0.key != nil && $0.key != "cputype" && $0.key != "flags" })
        limit = config["cpulimit"].flatMap { Double($0) } ?? 0
        units = config["cpuunits"] ?? ""
        affinity = config["affinity"] ?? ""
        numa = config["numa"] == "1"
    }

    public func serialized() -> [String: String?] {
        var values: [String: String?] = [
            "cpulimit": limit > 0 ? Self.number(limit) : nil,
            "cpuunits": units.trimmed.isEmpty ? nil : units.trimmed,
        ]
        guard isVM else {
            values["cores"] = cores > 0 ? String(cores) : nil
            return values
        }
        values["sockets"] = sockets == 1 ? nil : String(sockets)
        values["cores"] = cores == 1 ? nil : String(cores)
        values["vcpus"] = vcpus > 0 ? String(vcpus) : nil
        values["affinity"] = affinity.trimmed.isEmpty ? nil : affinity.trimmed
        values["numa"] = numa ? "1" : nil
        values["cpu"] = cpuValue
        return values
    }

    private var cpuValue: String? {
        guard !model.isEmpty || !flags.isEmpty || !otherCPUOptions.items.isEmpty else { return nil }
        var property = PropertyString(items: [(key: nil, value: model.isEmpty ? "kvm64" : model)])
        let ordered = Self.knownFlags.filter { flags[$0] != nil } + flags.keys.filter { !Self.knownFlags.contains($0) }.sorted()
        if !ordered.isEmpty {
            property["flags"] = ordered.map { (flags[$0]! ? "+" : "-") + $0 }.joined(separator: ";")
        }
        property.items += otherCPUOptions.items
        return property.stringValue
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// A QEMU machine version the node supports.
public struct MachineType: Decodable, Sendable, Hashable, Identifiable {
    /// For example `pc-q35-9.2+pve1`.
    public let id: String
    /// `q35` or `i440fx`.
    public let type: String
    public let version: String?
}

/// Firmware, machine, SCSI controller and display of a VM.
public struct VMSystemDraft: OptionsDraft, Sendable {
    public var bios: String
    /// `i440fx`, `q35`, or another machine as it is configured (e.g. `virt`).
    public var machineFamily: String
    /// Pinned machine version such as `9.2+pve1`, empty for the latest.
    public var machineVersion: String
    /// `intel`, `virtio` or empty.
    public var viommu: String
    public var scsiController: String
    /// Display type, empty for the default.
    public var display: String
    /// Display memory in MiB, 0 for the default.
    public var displayMemory: Int
    /// `vnc` to share the clipboard through the VNC console, empty for off.
    public var clipboard: String
    private var otherMachineOptions: PropertyString
    private var otherDisplayOptions: PropertyString

    public static let scsiControllers = ["virtio-scsi-single", "virtio-scsi-pci", "lsi", "lsi53c810", "megasas", "pvscsi"]
    public static let displays: [(id: String, title: String)] = [
        ("", "Default"), ("std", "Standard VGA"), ("virtio", "VirtIO-GPU"), ("virtio-gl", "VirGL GPU"),
        ("qxl", "SPICE"), ("qxl2", "SPICE Dual Monitor"), ("qxl3", "SPICE Three Monitors"), ("qxl4", "SPICE Four Monitors"),
        ("vmware", "VMware Compatible"), ("cirrus", "Cirrus Logic"), ("serial0", "Serial Terminal 0"),
        ("serial1", "Serial Terminal 1"), ("serial2", "Serial Terminal 2"), ("serial3", "Serial Terminal 3"), ("none", "None"),
    ]

    public init(_ config: GuestConfig) {
        bios = config["bios"] ?? "seabios"
        let machine = PropertyString(parsing: config["machine"] ?? "")
        let id = machine["type"] ?? machine.defaultValue ?? ""
        switch id {
        case "", "pc": (machineFamily, machineVersion) = ("i440fx", "")
        case "q35": (machineFamily, machineVersion) = ("q35", "")
        case _ where id.hasPrefix("pc-q35-"): (machineFamily, machineVersion) = ("q35", String(id.dropFirst(7)))
        case _ where id.hasPrefix("pc-i440fx-"): (machineFamily, machineVersion) = ("i440fx", String(id.dropFirst(10)))
        default: (machineFamily, machineVersion) = (id, "")
        }
        viommu = machine["viommu"] ?? ""
        otherMachineOptions = PropertyString(items: machine.items.filter { $0.key != nil && $0.key != "type" && $0.key != "viommu" })
        scsiController = config["scsihw"] ?? "lsi"
        let vga = PropertyString(parsing: config["vga"] ?? "")
        display = vga["type"] ?? vga.defaultValue ?? ""
        displayMemory = vga["memory"].flatMap { Int($0) } ?? 0
        clipboard = vga["clipboard"] ?? ""
        otherDisplayOptions = PropertyString(items: vga.items.filter { $0.key != nil && !["type", "memory", "clipboard"].contains($0.key!) })
    }

    public func serialized() -> [String: String?] {
        [
            "bios": bios == "seabios" ? nil : bios,
            "machine": machineValue,
            "scsihw": scsiController == "lsi" ? nil : scsiController,
            "vga": displayValue,
        ]
    }

    private var machineValue: String? {
        let id: String? = switch machineFamily {
        case "q35": machineVersion.isEmpty ? "q35" : "pc-q35-\(machineVersion)"
        case "i440fx": machineVersion.isEmpty ? nil : "pc-i440fx-\(machineVersion)"
        default: machineFamily
        }
        var property = PropertyString(items: [])
        if !viommu.isEmpty { property["viommu"] = viommu }
        property.items += otherMachineOptions.items
        guard id != nil || !property.items.isEmpty else { return nil }
        property.items.insert((key: nil, value: id ?? "pc"), at: 0)
        return property.stringValue
    }

    private var displayValue: String? {
        var property = PropertyString(items: [])
        if displayMemory > 0 { property["memory"] = String(displayMemory) }
        if !clipboard.isEmpty { property["clipboard"] = clipboard }
        property.items += otherDisplayOptions.items
        guard !display.isEmpty || !property.items.isEmpty else { return nil }
        property.items.insert((key: nil, value: display.isEmpty ? "std" : display), at: 0)
        return property.stringValue
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
