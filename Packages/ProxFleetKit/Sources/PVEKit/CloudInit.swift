import Foundation
import ProxmoxCore

/// Address settings of one network device for cloud-init, `ipconfigN`.
public struct CloudInitIPConfig: Sendable, Equatable {
    public var ipv4Mode: AddressMode = .none
    public var ipv4Address = ""
    public var ipv4Gateway = ""
    public var ipv6Mode: AddressMode = .none
    public var ipv6Address = ""
    public var ipv6Gateway = ""

    public init() {}

    public init(_ value: String?) {
        let property = PropertyString(parsing: value ?? "")
        ipv4Mode = AddressMode(property["ip"])
        if ipv4Mode == .static { ipv4Address = property["ip"] ?? "" }
        ipv4Gateway = property["gw"] ?? ""
        ipv6Mode = AddressMode(property["ip6"])
        if ipv6Mode == .static { ipv6Address = property["ip6"] ?? "" }
        ipv6Gateway = property["gw6"] ?? ""
    }

    public var stringValue: String? {
        var property = PropertyString(items: [])
        switch ipv4Mode {
        case .dhcp: property["ip"] = "dhcp"
        case .static:
            property["ip"] = ipv4Address.trimmed
            if !ipv4Gateway.trimmed.isEmpty { property["gw"] = ipv4Gateway.trimmed }
        default: break
        }
        switch ipv6Mode {
        case .dhcp: property["ip6"] = "dhcp"
        case .slaac: property["ip6"] = "auto"
        case .static:
            property["ip6"] = ipv6Address.trimmed
            if !ipv6Gateway.trimmed.isEmpty { property["gw6"] = ipv6Gateway.trimmed }
        default: break
        }
        return property.items.isEmpty ? nil : property.stringValue
    }
}

/// Cloud-init settings of a VM.
public struct CloudInitDraft: OptionsDraft, Sendable {
    public var user: String
    /// Whether a password is set; the server never returns it.
    public let hasPassword: Bool
    /// A new password, empty to keep the current one.
    public var newPassword = ""
    public var removesPassword = false
    public var sshKeys: [String]
    public var upgradePackages: Bool
    /// `nocloud`, `configdrive2`, `opennebula`, or empty for the default.
    public var type: String
    public var searchDomain: String
    public var nameservers: [String]
    /// `ipconfigN` by network device key (`net0`).
    public var ipConfigs: [String: CloudInitIPConfig]
    /// Custom snippet files, `user=local:snippets/user.yaml,...`.
    public var custom: [String: String]

    public static let customKinds = ["user", "network", "meta", "vendor"]

    public init(_ config: GuestConfig) {
        user = config["ciuser"] ?? ""
        hasPassword = config["cipassword"] != nil
        sshKeys = (config["sshkeys"]?.removingPercentEncoding ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        upgradePackages = config["ciupgrade"] != "0"
        type = config["citype"] ?? ""
        searchDomain = config["searchdomain"] ?? ""
        nameservers = (config["nameserver"] ?? "").split(separator: " ").map(String.init)
        ipConfigs = [:]
        for nic in config.networks {
            let index = nic.key.dropFirst(3)
            ipConfigs[nic.key] = CloudInitIPConfig(config["ipconfig\(index)"])
        }
        custom = [:]
        let customProperty = PropertyString(parsing: config["cicustom"] ?? "")
        for kind in Self.customKinds {
            if let value = customProperty[kind] { custom[kind] = value }
        }
    }

    public func serialized() -> [String: String?] {
        let keys = sshKeys.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let servers = nameservers.map(\.trimmed).filter { !$0.isEmpty }
        var values: [String: String?] = [
            "ciuser": user.trimmed.isEmpty ? nil : user.trimmed,
            "sshkeys": keys.isEmpty ? nil : Self.encodeKeys(keys),
            "ciupgrade": upgradePackages ? nil : "0",
            "citype": type.isEmpty ? nil : type,
            "searchdomain": searchDomain.trimmed.isEmpty ? nil : searchDomain.trimmed,
            "nameserver": servers.isEmpty ? nil : servers.joined(separator: " "),
        ]
        for (nic, ipConfig) in ipConfigs {
            values["ipconfig\(nic.dropFirst(3))"] = ipConfig.stringValue
        }
        var customProperty = PropertyString(items: [])
        for kind in Self.customKinds {
            if let value = custom[kind]?.trimmed, !value.isEmpty { customProperty[kind] = value }
        }
        values["cicustom"] = customProperty.items.isEmpty ? nil : customProperty.stringValue
        return values
    }

    /// Changed settings, including a new or removed password.
    public func update(from original: CloudInitDraft) -> GuestConfigUpdate {
        var update = changes(from: original)
        if !newPassword.isEmpty {
            update.set("cipassword", newPassword)
        } else if removesPassword, hasPassword {
            update.set("cipassword", nil)
        }
        return update
    }

    /// Proxmox expects the keys URL-encoded like JavaScript's `encodeURIComponent`.
    static func encodeKeys(_ keys: [String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return keys.joined(separator: "\n").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

extension GuestConfig {
    /// The drive holding the generated cloud-init image, e.g. `ide2`.
    public var cloudInitDrive: GuestDisk? {
        disks.first { $0.volume.contains("cloudinit") }
    }

    /// Value for a new cloud-init drive on a storage.
    public static func cloudInitDriveValue(storage: String) -> String {
        "\(storage):cloudinit"
    }
}

extension PVE {
    /// Rebuilds the cloud-init image from the current settings.
    public static func regenerateCloudInit(_ guest: GuestReference) -> APIRequest<Nothing> {
        APIRequest(.put, guest.path + "/cloudinit")
    }
}
