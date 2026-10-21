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
        let known: Set<String> = ["model", "macaddr", "bridge", "tag", "firewall", "link_down", "rate", "mtu"]
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
    private var property: PropertyString

    public static let cacheModes = ["none", "writethrough", "writeback", "directsync", "unsafe"]

    public init(_ disk: GuestDisk) {
        property = disk.options
        cache = property["cache"]
        discard = property["discard"] == "on"
        ioThread = property["iothread"] == "1"
        ssdEmulation = property["ssd"] == "1"
        includeInBackup = property["backup"] != "0"
    }

    public var stringValue: String {
        var result = property
        result["cache"] = cache
        result["discard"] = discard ? "on" : nil
        result["iothread"] = ioThread ? "1" : nil
        result["ssd"] = ssdEmulation ? "1" : nil
        result["backup"] = includeInBackup ? nil : "0"
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

    /// Value for a new disk: `local-lvm:32,discard=on,iothread=1`.
    public static func newDiskValue(storage: String, sizeGiB: Int, discard: Bool, ioThread: Bool, ssdEmulation: Bool) -> String {
        var property = PropertyString(items: [(key: nil, value: "\(storage):\(sizeGiB)")])
        if discard { property["discard"] = "on" }
        if ioThread { property["iothread"] = "1" }
        if ssdEmulation { property["ssd"] = "1" }
        return property.stringValue
    }

    /// Value for a CD/DVD drive with an ISO image, or empty when `isoVolume` is nil.
    public static func cdromValue(isoVolume: String?) -> String {
        "\(isoVolume ?? "none"),media=cdrom"
    }
}
