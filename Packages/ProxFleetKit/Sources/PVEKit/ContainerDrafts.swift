import Foundation
import ProxmoxCore

/// How a container interface gets an address for one IP version.
public enum AddressMode: String, Sendable, CaseIterable, Identifiable {
    /// Not configured by Proxmox.
    case none
    case dhcp
    /// IPv6 only: stateless autoconfiguration.
    case slaac
    case `static`
    /// Configured inside the container; Proxmox leaves it alone.
    case manual

    public var id: String { rawValue }

    init(_ value: String?) {
        switch value {
        case nil, "": self = .none
        case "dhcp": self = .dhcp
        case "auto": self = .slaac
        case "manual": self = .manual
        default: self = .static
        }
    }
}

/// Editable form of a container network interface. Options the form does not know are kept as they were.
public struct ContainerNetworkDraft: Sendable, Equatable {
    public var name = "eth0"
    /// nil lets Proxmox generate an address.
    public var macAddress: String?
    public var bridge = "vmbr0"
    public var vlanTag: Int?
    public var firewall = true
    public var isDisconnected = false
    public var ipv4Mode: AddressMode = .dhcp
    /// CIDR, e.g. `192.168.1.10/24`.
    public var ipv4Address = ""
    public var ipv4Gateway = ""
    public var ipv6Mode: AddressMode = .none
    public var ipv6Address = ""
    public var ipv6Gateway = ""
    /// MB/s, nil for unlimited.
    public var rateLimit: Double?
    public var mtu: Int?
    private var others = PropertyString(items: [])

    static let knownKeys: Set<String> = [
        "name", "hwaddr", "bridge", "tag", "firewall", "link_down", "ip", "gw", "ip6", "gw6", "rate", "mtu",
    ]

    public init(name: String = "eth0") {
        self.name = name
        others["type"] = "veth"
    }

    public init(_ nic: GuestNIC) {
        let property = nic.options
        name = property["name"] ?? "eth0"
        macAddress = property["hwaddr"]
        bridge = property["bridge"] ?? "vmbr0"
        vlanTag = property["tag"].flatMap { Int($0) }
        firewall = property["firewall"] == "1"
        isDisconnected = property["link_down"] == "1"
        ipv4Mode = AddressMode(property["ip"])
        if ipv4Mode == .static { ipv4Address = property["ip"] ?? "" }
        ipv4Gateway = property["gw"] ?? ""
        ipv6Mode = AddressMode(property["ip6"])
        if ipv6Mode == .static { ipv6Address = property["ip6"] ?? "" }
        ipv6Gateway = property["gw6"] ?? ""
        rateLimit = property["rate"].flatMap { Double($0) }
        mtu = property["mtu"].flatMap { Int($0) }
        others.items = property.items.filter { item in
            guard let key = item.key else { return false }
            return !Self.knownKeys.contains(key)
        }
    }

    public var stringValue: String {
        var property = PropertyString(items: [])
        property["name"] = name
        if let macAddress, !macAddress.isEmpty { property["hwaddr"] = macAddress }
        property["bridge"] = bridge
        if let vlanTag { property["tag"] = String(vlanTag) }
        if firewall { property["firewall"] = "1" }
        if isDisconnected { property["link_down"] = "1" }
        switch ipv4Mode {
        case .none, .slaac: break
        case .dhcp: property["ip"] = "dhcp"
        case .manual: property["ip"] = "manual"
        case .static:
            property["ip"] = ipv4Address
            if !ipv4Gateway.isEmpty { property["gw"] = ipv4Gateway }
        }
        switch ipv6Mode {
        case .none: break
        case .dhcp: property["ip6"] = "dhcp"
        case .slaac: property["ip6"] = "auto"
        case .manual: property["ip6"] = "manual"
        case .static:
            property["ip6"] = ipv6Address
            if !ipv6Gateway.isEmpty { property["gw6"] = ipv6Gateway }
        }
        if let rateLimit { property["rate"] = String(rateLimit) }
        if let mtu { property["mtu"] = String(mtu) }
        property.items += others.items
        return property.stringValue
    }
}

/// DNS settings of a container. Empty values make the container use the host's settings.
public struct ContainerDNSDraft: OptionsDraft, Sendable {
    public var searchDomain: String
    public var nameservers: [String]

    public init(_ config: GuestConfig) {
        searchDomain = config["searchdomain"] ?? ""
        nameservers = (config["nameserver"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" }).map(String.init)
    }

    public func serialized() -> [String: String?] {
        let servers = nameservers.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let domain = searchDomain.trimmingCharacters(in: .whitespaces)
        return [
            "searchdomain": domain.isEmpty ? nil : domain,
            "nameserver": servers.isEmpty ? nil : servers.joined(separator: " "),
        ]
    }
}

/// Editable options of a container's root file system or a mount point. Volume, size and unknown options are kept.
public struct MountPointDraft: Sendable, Equatable {
    /// Path inside the container; not used for the root file system.
    public var path: String
    /// nil follows the file system default.
    public var acl: Bool?
    public var quota = false
    public var replicate = true
    public var readOnly = false
    /// Mount points are left out of backups unless this is set; the root file system is always included.
    public var includeInBackup = false
    /// For bind mounts and shared storage: the volume is available on all nodes.
    public var shared = false
    public var mountOptions: Set<String> = []
    public let isRootFS: Bool
    private var property: PropertyString

    public static let availableMountOptions = ["discard", "lazytime", "noatime", "nodev", "noexec", "nosuid"]

    public init(_ disk: GuestDisk) {
        property = disk.options
        isRootFS = disk.key == "rootfs"
        path = property["mp"] ?? ""
        acl = property["acl"].map { $0 == "1" }
        quota = property["quota"] == "1"
        replicate = property["replicate"] != "0"
        readOnly = property["ro"] == "1"
        includeInBackup = property["backup"] == "1"
        shared = property["shared"] == "1"
        mountOptions = Set((property["mountoptions"] ?? "").split(separator: ";").map(String.init))
    }

    public var stringValue: String {
        var result = property
        if !isRootFS {
            result["mp"] = path
            result["ro"] = readOnly ? "1" : nil
            result["backup"] = includeInBackup ? "1" : nil
            result["shared"] = shared ? "1" : nil
        }
        result["acl"] = acl.map { $0 ? "1" : "0" }
        result["quota"] = quota ? "1" : nil
        result["replicate"] = replicate ? nil : "0"
        result["mountoptions"] = mountOptions.isEmpty ? nil : Self.availableMountOptions.filter(mountOptions.contains).joined(separator: ";")
        return result.stringValue
    }

    /// Value for a new mount point on a storage, `local-lvm:8,mp=/data,backup=1`, or a bind mount of a host path.
    public static func newValue(source: String, sizeGiB: Int?, path: String, includeInBackup: Bool, readOnly: Bool) -> String {
        var property = PropertyString(items: [(key: nil, value: sizeGiB.map { "\(source):\($0)" } ?? source)])
        property["mp"] = path
        if includeInBackup { property["backup"] = "1" }
        if readOnly { property["ro"] = "1" }
        return property.stringValue
    }
}
