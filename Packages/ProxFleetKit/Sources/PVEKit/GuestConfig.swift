import Foundation
import ProxmoxCore

/// `GET .../config`: the flat key-value configuration of a VM or container.
public struct GuestConfig: Decodable, Sendable, Equatable {
    public var values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: String] = [:]
        for key in container.allKeys {
            if let value = container.lossyString(key) { values[key.stringValue] = value }
        }
        self.values = values
    }

    public subscript(key: String) -> String? { values[key] }

    /// Changes whenever the configuration changes; sent back when editing to detect conflicts.
    public var digest: String? { values["digest"] }
    /// VM name or container host name.
    public var name: String? { values["name"] ?? values["hostname"] }
    public var description: String? { values["description"] }
    public var cores: Int? { values["cores"].flatMap { Int($0) } }
    public var sockets: Int { values["sockets"].flatMap { Int($0) } ?? 1 }
    public var memoryMiB: Int? { values["memory"].flatMap { Int($0) } }
    public var balloonMiB: Int? { values["balloon"].flatMap { Int($0) } }
    public var swapMiB: Int? { values["swap"].flatMap { Int($0) } }
    public var osType: String? { values["ostype"] }
    public var bios: String? { values["bios"] }
    public var machine: String? { values["machine"] }
    public var cpuType: String? { values["cpu"].map { PropertyString(parsing: $0).defaultValue ?? $0 } }
    public var startsOnBoot: Bool { values["onboot"] == "1" }
    public var isUnprivileged: Bool { values["unprivileged"] == "1" }

    /// The QEMU guest agent option, e.g. `1` or `enabled=1,fstrim_cloned_disks=1`.
    public var agentEnabled: Bool {
        guard let text = values["agent"] else { return false }
        let property = PropertyString(parsing: text)
        return (property["enabled"] ?? property.defaultValue) == "1"
    }

    /// Devices in boot order, from `order=scsi0;ide2;net0`.
    public var bootOrder: [String] {
        guard let text = values["boot"], let order = PropertyString(parsing: text)["order"] else { return [] }
        return order.split(separator: ";").map(String.init)
    }

    public var disks: [GuestDisk] {
        values.keys
            .filter(GuestDisk.isDiskKey)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { key in values[key].map { GuestDisk(key: key, value: $0) } }
    }

    public var networks: [GuestNIC] {
        values.keys
            .filter { $0.hasPrefix("net") && Int($0.dropFirst(3)) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { key in values[key].map { GuestNIC(key: key, value: $0) } }
    }

    /// Human-readable operating system type, as shown in the web interface.
    public var osTypeDescription: String? {
        guard let osType else { return nil }
        return Self.osTypeNames[osType] ?? osType
    }

    static let osTypeNames: [String: String] = [
        "l26": "Linux 6.x – 2.6 Kernel",
        "l24": "Linux 2.4 Kernel",
        "win11": "Windows 11/2022/2025",
        "win10": "Windows 10/2016/2019",
        "win8": "Windows 8.x/2012/2012r2",
        "win7": "Windows 7/2008r2",
        "w2k8": "Windows Vista/2008",
        "wxp": "Windows XP/2003",
        "w2k": "Windows 2000",
        "solaris": "Solaris Kernel",
        "other": "Other",
        "alpine": "Alpine",
        "archlinux": "Arch Linux",
        "centos": "CentOS",
        "debian": "Debian",
        "devuan": "Devuan",
        "fedora": "Fedora",
        "gentoo": "Gentoo",
        "nixos": "NixOS",
        "opensuse": "openSUSE",
        "ubuntu": "Ubuntu",
        "unmanaged": "Unmanaged",
    ]
}

/// A disk, CD drive or container volume from the configuration.
public struct GuestDisk: Sendable, Equatable, Identifiable {
    public var key: String
    public var volume: String
    public var size: String?
    public var isCDROM: Bool
    public var options: PropertyString

    public var id: String { key }

    init(key: String, value: String) {
        let property = PropertyString(parsing: value)
        self.key = key
        volume = property.defaultValue ?? property["file"] ?? property["volume"] ?? value
        size = property["size"]
        isCDROM = property["media"] == "cdrom"
        options = property
    }

    /// For container mount points, the path inside the container.
    public var mountPoint: String? { options["mp"] }

    public var isUnused: Bool { key.hasPrefix("unused") }

    static func isDiskKey(_ key: String) -> Bool {
        if ["efidisk0", "tpmstate0", "rootfs"].contains(key) { return true }
        for prefix in ["scsi", "virtio", "sata", "ide", "mp", "unused"] where key.hasPrefix(prefix) {
            return Int(key.dropFirst(prefix.count)) != nil
        }
        return false
    }
}

/// A network device from the configuration.
public struct GuestNIC: Sendable, Equatable, Identifiable {
    public var key: String
    /// VM device model (`virtio`, `e1000`…) or container interface name (`eth0`).
    public var model: String?
    public var macAddress: String?
    public var bridge: String?
    public var vlanTag: String?
    public var firewall: Bool
    public var isLinkDown: Bool
    /// Containers only: `dhcp`, `manual` or an address in CIDR notation.
    public var ipv4: String?

    public var id: String { key }

    private static let optionKeys: Set<String> = [
        "bridge", "firewall", "tag", "rate", "link_down", "mtu", "queues", "macaddr", "model", "trunks",
        "name", "hwaddr", "ip", "gw", "ip6", "gw6", "type",
    ]

    init(key: String, value: String) {
        let property = PropertyString(parsing: value)
        self.key = key
        if let first = property.items.first, let firstKey = first.key, !Self.optionKeys.contains(firstKey) {
            // VM format: `virtio=BC:24:11:..`, the model is the key and the MAC the value.
            model = firstKey
            macAddress = first.value
        } else {
            model = property["model"] ?? property["name"]
            macAddress = property["macaddr"] ?? property["hwaddr"]
        }
        bridge = property["bridge"]
        vlanTag = property["tag"]
        firewall = property["firewall"] == "1"
        isLinkDown = property["link_down"] == "1"
        ipv4 = property["ip"]
    }
}
