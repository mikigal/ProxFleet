import Foundation
import ProxmoxCore

/// Editable form of a VM network device. Options the form does not know are kept as they were.
public struct NetworkDeviceDraft: Sendable, Equatable {
    public var model = "virtio"
    /// nil lets Proxmox generate an address.
    public var macAddress: String?
    public var bridge = "vmbr0"
    public var vlanTag: Int?
    public var firewall = true
    public var isDisconnected = false
    /// MB/s, nil for unlimited.
    public var rateLimit: Double?
    public var mtu: Int?
    /// VirtIO multiqueue, nil for one queue.
    public var queues: Int?
    /// VLAN IDs allowed through, e.g. `10;20-30`; empty for all.
    public var trunks = ""
    private var others = PropertyString(items: [])

    public static let models = ["virtio", "e1000", "e1000e", "rtl8139", "vmxnet3"]

    public init() {}

    public init(_ nic: GuestNIC) {
        model = nic.model ?? "virtio"
        macAddress = nic.macAddress
        bridge = nic.bridge ?? "vmbr0"
        vlanTag = nic.vlanTag.flatMap { Int($0) }
        firewall = nic.firewall
        isDisconnected = nic.isLinkDown
        rateLimit = nic.options["rate"].flatMap { Double($0) }
        mtu = nic.options["mtu"].flatMap { Int($0) }
        queues = nic.options["queues"].flatMap { Int($0) }
        trunks = nic.options["trunks"] ?? ""
        let known: Set<String> = ["model", "macaddr", "bridge", "tag", "firewall", "link_down", "rate", "mtu", "queues", "trunks"]
        others.items = nic.options.items.enumerated().filter { index, item in
            guard let key = item.key else { return false }
            // The first item of `virtio=MAC` is the model, not an option.
            return !(index == 0 && !GuestNIC.optionKeys.contains(key)) && !known.contains(key)
        }.map(\.element)
    }

    public var stringValue: String {
        var property = PropertyString(items: [])
        if let macAddress, !macAddress.isEmpty {
            property.items.append((key: model, value: macAddress))
        } else {
            property.items.append((key: "model", value: model))
        }
        property["bridge"] = bridge
        if let vlanTag { property["tag"] = String(vlanTag) }
        property["firewall"] = firewall ? "1" : "0"
        if isDisconnected { property["link_down"] = "1" }
        if let rateLimit { property["rate"] = String(rateLimit) }
        if let mtu { property["mtu"] = String(mtu) }
        if let queues { property["queues"] = String(queues) }
        if !trunks.trimmed.isEmpty { property["trunks"] = trunks.trimmed }
        property.items += others.items
        return property.stringValue
    }
}

/// Editable options of an existing disk. The volume, size and unknown options are kept.
public struct DiskOptionsDraft: Sendable, Equatable {
    /// nil is the Proxmox default (no cache).
    public var cache: String?
    public var discard = false
    public var ioThread = false
    public var ssdEmulation = false
    public var includeInBackup = true
    /// nil is the Proxmox default (io_uring).
    public var asyncIO: String?
    public var readOnly = false
    public var replicate = true
    public var serial = ""
    /// Bandwidth limits in MB/s and operation limits per second, empty for unlimited.
    public var limits: [String: String] = [:]
    private var property: PropertyString

    public static let cacheModes = ["none", "writethrough", "writeback", "directsync", "unsafe"]
    public static let asyncIOModes = ["io_uring", "native", "threads"]
    public static let limitKeys = ["mbps_rd", "mbps_wr", "iops_rd", "iops_wr", "mbps_rd_max", "mbps_wr_max", "iops_rd_max", "iops_wr_max"]

    /// Options of a new disk, all at the Proxmox defaults.
    public init() {
        self.init(GuestDisk(key: "", value: ""))
    }

    public init(_ disk: GuestDisk) {
        property = disk.options
        cache = property["cache"]
        discard = property["discard"] == "on"
        ioThread = property["iothread"] == "1"
        ssdEmulation = property["ssd"] == "1"
        includeInBackup = property["backup"] != "0"
        asyncIO = property["aio"]
        readOnly = property["ro"] == "1"
        replicate = property["replicate"] != "0"
        serial = property["serial"] ?? ""
        for key in Self.limitKeys {
            if let value = property[key] { limits[key] = value }
        }
    }

    public var stringValue: String {
        var result = property
        result["cache"] = cache
        result["discard"] = discard ? "on" : nil
        result["iothread"] = ioThread ? "1" : nil
        result["ssd"] = ssdEmulation ? "1" : nil
        result["backup"] = includeInBackup ? nil : "0"
        result["aio"] = asyncIO
        result["ro"] = readOnly ? "1" : nil
        result["replicate"] = replicate ? nil : "0"
        result["serial"] = serial.trimmed.isEmpty ? nil : serial.trimmed
        for key in Self.limitKeys {
            let value = limits[key]?.trimmed.replacingOccurrences(of: ",", with: ".") ?? ""
            result[key] = value.isEmpty ? nil : value
        }
        return result.stringValue
    }

    /// Value for a new disk with these options: `local-lvm:32,discard=on,iothread=1`.
    public func newDiskValue(storage: String, sizeGiB: Int) -> String {
        var result = PropertyString(parsing: stringValue)
        result.items.insert((key: nil, value: "\(storage):\(sizeGiB)"), at: 0)
        return result.stringValue
    }
}

/// Buses a VM disk can attach to, with the number of slots each has.
public enum DiskBus: String, Sendable, CaseIterable, Identifiable {
    case scsi, virtio, sata, ide

    public var id: String { rawValue }

    public var slots: Int {
        switch self {
        case .scsi: 31
        case .virtio: 16
        case .sata: 6
        case .ide: 4
        }
    }

    public var title: String {
        switch self {
        case .scsi: "SCSI"
        case .virtio: "VirtIO Block"
        case .sata: "SATA"
        case .ide: "IDE"
        }
    }
}

extension GuestConfig {
    /// First unused key with a prefix, e.g. `scsi1` or `net2`.
    public func nextFreeKey(prefix: String, slots: Int) -> String? {
        (0..<slots).map { "\(prefix)\($0)" }.first { values[$0] == nil }
    }

    /// The volume of a CD/DVD drive that uses the host's physical drive.
    public static let physicalCDROM = "cdrom"

    /// Value for a CD/DVD drive with an ISO image or the host's drive (`physicalCDROM`), or empty when `isoVolume` is nil.
    public static func cdromValue(isoVolume: String?) -> String {
        "\(isoVolume ?? "none"),media=cdrom"
    }
}
