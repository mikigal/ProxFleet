import Foundation
import ProxmoxCore

/// Options of a guest as editable values. Both the draft and the original serialize the same way, so only
/// options the user actually changed end up in the update, even when the server stored them differently.
public protocol OptionsDraft: Equatable {
    /// Configuration values this draft manages; nil means "not set", which is the Proxmox default.
    func serialized() -> [String: String?]
}

extension OptionsDraft {
    public func changes(from original: Self) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let new = serialized()
        let old = original.serialized()
        for (key, value) in new where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        return update
    }
}

/// Start/shutdown order and delays, shared by VMs and containers.
public struct StartupOptions: Equatable, Sendable {
    public var order = ""
    public var startDelay = ""
    public var shutdownTimeout = ""

    init(_ text: String?) {
        let property = PropertyString(parsing: text ?? "")
        order = property["order"] ?? ""
        startDelay = property["up"] ?? ""
        shutdownTimeout = property["down"] ?? ""
    }

    var serialized: String? {
        var property = PropertyString(items: [])
        if !order.isEmpty { property["order"] = order }
        if !startDelay.isEmpty { property["up"] = startDelay }
        if !shutdownTimeout.isEmpty { property["down"] = shutdownTimeout }
        return property.items.isEmpty ? nil : property.stringValue
    }
}

/// SMBIOS type 1 fields. Text fields are sent base64-encoded so they may contain any character.
public struct SMBIOSOptions: Equatable, Sendable {
    public var uuid = ""
    public var manufacturer = ""
    public var product = ""
    public var version = ""
    public var serial = ""
    public var sku = ""
    public var family = ""

    static let textKeys = ["manufacturer", "product", "version", "serial", "sku", "family"]

    init(_ text: String?) {
        let property = PropertyString(parsing: text ?? "")
        let encoded = property["base64"] == "1"
        func value(_ key: String) -> String {
            guard let raw = property[key] else { return "" }
            guard encoded, let data = Data(base64Encoded: raw) else { return raw }
            return String(decoding: data, as: UTF8.self)
        }
        uuid = property["uuid"] ?? ""
        manufacturer = value("manufacturer")
        product = value("product")
        version = value("version")
        serial = value("serial")
        sku = value("sku")
        family = value("family")
    }

    var serialized: String? {
        var property = PropertyString(items: [])
        let texts = [("family", family), ("manufacturer", manufacturer), ("product", product), ("serial", serial), ("sku", sku), ("version", version)]
            .filter { !$0.1.isEmpty }
        if !texts.isEmpty { property["base64"] = "1" }
        for (key, value) in texts { property[key] = Data(value.utf8).base64EncodedString() }
        if !uuid.isEmpty { property["uuid"] = uuid }
        return property.items.isEmpty ? nil : property.stringValue
    }
}

private func flag(_ value: Bool, default defaultValue: Bool) -> String? {
    value == defaultValue ? nil : (value ? "1" : "0")
}

private func boolValue(_ text: String?, default defaultValue: Bool) -> Bool {
    text.map { $0 == "1" } ?? defaultValue
}

private func optional(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

/// All options of a VM's Options panel in the web interface.
public struct VMOptionsDraft: OptionsDraft, Sendable {
    public var name: String
    public var startAtBoot: Bool
    public var startup: StartupOptions
    public var osType: String
    public var protection: Bool
    public var tags: [String]
    public var hotplug: Set<String>
    public var agentEnabled: Bool
    public var agentFreezeFS: Bool
    public var agentTrimClonedDisks: Bool
    public var agentType: String
    public var tablet: Bool
    public var acpi: Bool
    public var kvm: Bool
    public var freezeCPU: Bool
    public var localTime: Bool
    /// nil starts the clock at the current time.
    public var rtcStartDate: String?
    public var smbios: SMBIOSOptions
    public var spiceFolderSharing: Bool
    public var spiceVideoStreaming: String
    public var vmStateStorage: String
    public var keyboard: String
    public var allowReboot: Bool
    public var allowKSM: Bool
    public var hugepages: String
    public var keepHugepages: Bool
    public var watchdogModel: String
    public var watchdogAction: String
    public var sevType: String
    public var sevNoDebug: Bool
    public var sevNoKeySharing: Bool
    public var sevKernelHashes: Bool
    public var sevAllowSMT: Bool
    public var tdxEnabled: Bool
    public var tdxAttestation: Bool
    public var migrateDowntime: String
    public var migrateSpeed: String
    public var hookscript: String

    public static let hotplugFeatures = ["network", "disk", "usb", "memory", "cpu", "cloudinit"]
    static let defaultHotplug: Set<String> = ["network", "disk", "usb"]
    public static let keyboardLayouts = ["da", "de", "de-ch", "en-gb", "en-us", "es", "fi", "fr", "fr-be", "fr-ca", "fr-ch", "hu", "is", "it", "ja", "lt", "mk", "nl", "no", "pl", "pt", "pt-br", "sl", "sv", "tr"]
    public static let watchdogActions = ["reset", "shutdown", "poweroff", "pause", "debug", "none"]

    public init(_ config: GuestConfig) {
        name = config.name ?? ""
        startAtBoot = config.startsOnBoot
        startup = StartupOptions(config["startup"])
        osType = config.osType ?? "other"
        protection = config["protection"] == "1"
        tags = GuestSummary.parseTags(config["tags"])

        switch config["hotplug"] {
        case nil, "1": hotplug = Self.defaultHotplug
        case "0": hotplug = []
        case let value?: hotplug = Set(value.split(separator: ",").map(String.init))
        }

        let agent = PropertyString(parsing: config["agent"] ?? "")
        agentEnabled = (agent["enabled"] ?? agent.defaultValue) == "1"
        agentFreezeFS = (agent["freeze-fs"] ?? agent["freeze-fs-on-backup"] ?? agent["guest-fsfreeze"]) != "0"
        agentTrimClonedDisks = agent["fstrim_cloned_disks"] == "1"
        agentType = agent["type"] ?? "virtio"

        tablet = boolValue(config["tablet"], default: true)
        acpi = boolValue(config["acpi"], default: true)
        kvm = boolValue(config["kvm"], default: true)
        freezeCPU = boolValue(config["freeze"], default: false)
        localTime = boolValue(config["localtime"], default: false)
        rtcStartDate = config["startdate"].flatMap { $0 == "now" ? nil : $0 }
        smbios = SMBIOSOptions(config["smbios1"])

        let spice = PropertyString(parsing: config["spice_enhancements"] ?? "")
        spiceFolderSharing = spice["foldersharing"] == "1"
        spiceVideoStreaming = spice["videostreaming"] ?? "off"

        vmStateStorage = config["vmstatestorage"] ?? ""
        keyboard = config["keyboard"] ?? ""
        allowReboot = boolValue(config["reboot"], default: true)
        allowKSM = boolValue(config["allow-ksm"], default: true)
        hugepages = config["hugepages"] ?? ""
        keepHugepages = boolValue(config["keephugepages"], default: false)

        let watchdog = PropertyString(parsing: config["watchdog"] ?? "")
        watchdogModel = watchdog["model"] ?? watchdog.defaultValue ?? ""
        watchdogAction = watchdog["action"] ?? ""

        let sev = PropertyString(parsing: config["amd-sev"] ?? "")
        sevType = sev["type"] ?? sev.defaultValue ?? ""
        sevNoDebug = sev["no-debug"] == "1"
        sevNoKeySharing = sev["no-key-sharing"] == "1"
        sevKernelHashes = sev["kernel-hashes"] == "1"
        sevAllowSMT = sev["allow-smt"] == "1"

        let tdx = PropertyString(parsing: config["intel-tdx"] ?? "")
        tdxEnabled = config["intel-tdx"] != nil
        tdxAttestation = tdx["attestation"] == "1"

        migrateDowntime = config["migrate_downtime"] ?? ""
        migrateSpeed = config["migrate_speed"] ?? ""
        hookscript = config["hookscript"] ?? ""
    }

    public func serialized() -> [String: String?] {
        var agent = PropertyString(items: [])
        if agentEnabled || !agentFreezeFS || agentTrimClonedDisks || agentType != "virtio" {
            agent["enabled"] = agentEnabled ? "1" : "0"
            if !agentFreezeFS { agent["freeze-fs"] = "0" }
            if agentTrimClonedDisks { agent["fstrim_cloned_disks"] = "1" }
            if agentType != "virtio" { agent["type"] = agentType }
        }

        var spice = PropertyString(items: [])
        if spiceFolderSharing { spice["foldersharing"] = "1" }
        if spiceVideoStreaming != "off" { spice["videostreaming"] = spiceVideoStreaming }

        var watchdog = PropertyString(items: [])
        if !watchdogModel.isEmpty {
            watchdog["model"] = watchdogModel
            if !watchdogAction.isEmpty { watchdog["action"] = watchdogAction }
        }

        var sev = PropertyString(items: [])
        if !sevType.isEmpty {
            sev["type"] = sevType
            if sevNoDebug { sev["no-debug"] = "1" }
            if sevNoKeySharing { sev["no-key-sharing"] = "1" }
            if sevKernelHashes { sev["kernel-hashes"] = "1" }
            if sevAllowSMT { sev["allow-smt"] = "1" }
        }

        let hotplugValue: String?
        if hotplug == Self.defaultHotplug {
            hotplugValue = nil
        } else if hotplug.isEmpty {
            hotplugValue = "0"
        } else {
            hotplugValue = Self.hotplugFeatures.filter(hotplug.contains).joined(separator: ",")
        }

        return [
            "name": optional(name),
            "onboot": startAtBoot ? "1" : nil,
            "startup": startup.serialized,
            "ostype": osType,
            "protection": protection ? "1" : nil,
            "tags": tags.isEmpty ? nil : tags.joined(separator: ";"),
            "hotplug": hotplugValue,
            "agent": agent.items.isEmpty ? nil : agent.stringValue,
            "tablet": flag(tablet, default: true),
            "acpi": flag(acpi, default: true),
            "kvm": flag(kvm, default: true),
            "freeze": flag(freezeCPU, default: false),
            "localtime": flag(localTime, default: false),
            "startdate": rtcStartDate,
            "smbios1": smbios.serialized,
            "spice_enhancements": spice.items.isEmpty ? nil : spice.stringValue,
            "vmstatestorage": optional(vmStateStorage),
            "keyboard": optional(keyboard),
            "reboot": flag(allowReboot, default: true),
            "allow-ksm": flag(allowKSM, default: true),
            "hugepages": optional(hugepages),
            "keephugepages": flag(keepHugepages, default: false),
            "watchdog": watchdog.items.isEmpty ? nil : watchdog.stringValue,
            "amd-sev": sev.items.isEmpty ? nil : sev.stringValue,
            "intel-tdx": tdxEnabled ? "type=tdx,attestation=\(tdxAttestation ? 1 : 0)" : nil,
            "migrate_downtime": optional(migrateDowntime),
            "migrate_speed": optional(migrateSpeed),
            "hookscript": optional(hookscript),
        ]
    }
}

/// All options of a container's Options panel in the web interface.
public struct ContainerOptionsDraft: OptionsDraft, Sendable {
    public var hostname: String
    public var startAtBoot: Bool
    public var startup: StartupOptions
    public var osType: String
    public var architecture: String
    public var protection: Bool
    public var tags: [String]
    public var consoleMode: String
    public var ttyCount: Int
    public var consoleDevice: Bool
    public var timezone: String
    public var nesting: Bool
    public var keyctl: Bool
    public var fuse: Bool
    public var mknod: Bool
    public var forceWritableSys: Bool
    public var mountTypes: Set<String>
    public var debug: Bool
    public var entrypoint: String
    public var environment: [EnvironmentVariable]
    public var hookscript: String
    /// Fixed at creation; shown, not edited.
    public let isUnprivileged: Bool

    public struct EnvironmentVariable: Equatable, Sendable, Identifiable {
        public var id = UUID()
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && lhs.value == rhs.value
        }
    }

    public static let osTypes = ["alpine", "archlinux", "centos", "debian", "devuan", "fedora", "gentoo", "nixos", "opensuse", "ubuntu", "unmanaged"]
    public static let architectures = ["amd64", "i386", "arm64", "armhf", "riscv32", "riscv64"]
    public static let consoleModes = ["tty", "console", "shell"]
    public static let mountableTypes = ["nfs", "cifs"]

    public init(_ config: GuestConfig) {
        hostname = config.name ?? ""
        startAtBoot = config.startsOnBoot
        startup = StartupOptions(config["startup"])
        osType = config.osType ?? "unmanaged"
        architecture = config["arch"] ?? "amd64"
        protection = config["protection"] == "1"
        tags = GuestSummary.parseTags(config["tags"])
        consoleMode = config["cmode"] ?? "tty"
        ttyCount = config["tty"].flatMap { Int($0) } ?? 2
        consoleDevice = boolValue(config["console"], default: true)
        timezone = config["timezone"] ?? ""

        let features = PropertyString(parsing: config["features"] ?? "")
        nesting = features["nesting"] == "1"
        keyctl = features["keyctl"] == "1"
        fuse = features["fuse"] == "1"
        mknod = features["mknod"] == "1"
        forceWritableSys = features["force_rw_sys"] == "1"
        mountTypes = Set((features["mount"] ?? "").split(separator: ";").map(String.init))

        debug = boolValue(config["debug"], default: false)
        entrypoint = config["entrypoint"] ?? ""
        environment = (config["env"] ?? "").split(separator: "\0").compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? EnvironmentVariable(name: parts[0], value: parts[1]) : nil
        }
        hookscript = config["hookscript"] ?? ""
        isUnprivileged = config.isUnprivileged
    }

    public func serialized() -> [String: String?] {
        var features = PropertyString(items: [])
        if nesting { features["nesting"] = "1" }
        if keyctl { features["keyctl"] = "1" }
        if fuse { features["fuse"] = "1" }
        if mknod { features["mknod"] = "1" }
        if forceWritableSys { features["force_rw_sys"] = "1" }
        if !mountTypes.isEmpty { features["mount"] = mountTypes.sorted().joined(separator: ";") }

        let variables = environment.filter { !$0.name.isEmpty }.map { "\($0.name)=\($0.value)" }
        return [
            "hostname": optional(hostname),
            "onboot": startAtBoot ? "1" : nil,
            "startup": startup.serialized,
            "ostype": osType,
            "arch": architecture == "amd64" ? nil : architecture,
            "protection": protection ? "1" : nil,
            "tags": tags.isEmpty ? nil : tags.joined(separator: ";"),
            "cmode": consoleMode == "tty" ? nil : consoleMode,
            "tty": ttyCount == 2 ? nil : String(ttyCount),
            "console": flag(consoleDevice, default: true),
            "timezone": optional(timezone),
            "features": features.items.isEmpty ? nil : features.stringValue,
            "debug": flag(debug, default: false),
            "entrypoint": optional(entrypoint),
            "env": variables.isEmpty ? nil : variables.joined(separator: "\0"),
            "hookscript": optional(hookscript),
        ]
    }
}

/// Tags must be lowercase letters, digits and `_ - + .`, starting with a letter, digit or underscore.
public enum TagRules {
    public static func normalize(_ text: String) -> String? {
        let tag = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = tag.unicodeScalars.first,
              CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "_")).contains(first),
              tag.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-+.").contains($0) })
        else { return nil }
        return tag
    }
}
