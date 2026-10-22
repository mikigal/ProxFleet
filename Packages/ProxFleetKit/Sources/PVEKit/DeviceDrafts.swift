import Foundation
import ProxmoxCore

/// Kinds of VM devices besides disks and network cards, with their configuration keys.
public enum VMDeviceKind: String, Sendable, CaseIterable, Identifiable {
    case efiDisk, tpmState, usb, pci, serial, parallel, audio, rng, virtioFS, ivshmem

    public var id: String { rawValue }

    /// Key prefix and number of slots; single devices have one slot and a fixed key.
    public var keyPrefix: String {
        switch self {
        case .efiDisk: "efidisk"
        case .tpmState: "tpmstate"
        case .usb: "usb"
        case .pci: "hostpci"
        case .serial: "serial"
        case .parallel: "parallel"
        case .audio: "audio"
        case .rng: "rng"
        case .virtioFS: "virtiofs"
        case .ivshmem: "ivshmem"
        }
    }

    public var slots: Int {
        switch self {
        case .efiDisk, .tpmState, .audio, .rng: 1
        case .ivshmem: 1
        case .usb: 14
        case .pci: 16
        case .serial: 4
        case .parallel: 3
        case .virtioFS: 10
        }
    }

    /// The key a new device of this kind gets, or nil when all slots are used.
    public func nextKey(in config: GuestConfig) -> String? {
        if self == .ivshmem { return config["ivshmem"] == nil ? "ivshmem" : nil }
        return config.nextFreeKey(prefix: keyPrefix, slots: slots)
    }

    /// The kind of a configuration key, e.g. `usb2` → `.usb`.
    public init?(key: String) {
        if key == "ivshmem" { self = .ivshmem; return }
        // `hostpci` before `parallel`/`pci`-like prefixes; the number must follow the prefix directly.
        for kind in Self.allCases where kind != .ivshmem {
            if key.hasPrefix(kind.keyPrefix), Int(key.dropFirst(kind.keyPrefix.count)) != nil {
                self = kind
                return
            }
        }
        return nil
    }

    /// Privilege needed to add, change or remove a device of this kind.
    public var privilege: String {
        switch self {
        case .efiDisk, .tpmState: "VM.Config.Disk"
        default: "VM.Config.HWType"
        }
    }
}

extension GuestConfig {
    /// Devices other than disks and network cards, in key order. EFI and TPM state disks are listed with the disks.
    public var otherDevices: [(key: String, kind: VMDeviceKind, value: String)] {
        values.compactMap { key, value in
            guard let kind = VMDeviceKind(key: key), kind != .efiDisk, kind != .tpmState else { return nil }
            return (key, kind, value)
        }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
}

/// A USB device passed to a VM: a host device, a cluster mapping, or a SPICE redirection port.
public struct USBDeviceDraft: Sendable, Equatable {
    public enum Source: String, Sendable, CaseIterable { case spice, host, mapping }
    public var source: Source = .host
    /// `vendor:product` (e.g. `0627:0001`) or `bus-port` (e.g. `2-1`).
    public var host = ""
    public var mapping = ""
    public var usb3 = false
    private var others = PropertyString(items: [])

    public init() {}

    public init(_ value: String) {
        let property = PropertyString(parsing: value)
        let host = property["host"] ?? property.defaultValue ?? ""
        if let mapping = property["mapping"] {
            source = .mapping
            self.mapping = mapping
        } else if host == "spice" {
            source = .spice
        } else {
            source = .host
            self.host = host
        }
        usb3 = property["usb3"] == "1"
        others.items = property.items.filter { $0.key != nil && !["host", "mapping", "usb3"].contains($0.key!) }
    }

    public var stringValue: String {
        var property = PropertyString(items: [])
        switch source {
        case .spice: property["host"] = "spice"
        case .host: property["host"] = host
        case .mapping: property["mapping"] = mapping
        }
        if usb3 { property["usb3"] = "1" }
        property.items += others.items
        return property.stringValue
    }

    public var isComplete: Bool {
        switch source {
        case .spice: true
        case .host: !host.isEmpty
        case .mapping: !mapping.isEmpty
        }
    }
}

/// A PCI(e) device passed through to a VM, from the host or a cluster mapping.
public struct PCIDeviceDraft: Sendable, Equatable {
    public var usesMapping = false
    /// `0000:01:00.0`; with all functions the function is left out (`0000:01:00`).
    public var host = ""
    public var mapping = ""
    public var allFunctions = false
    public var pcie = false
    public var romBar = true
    public var primaryGPU = false
    /// Mediated device type, e.g. a vGPU profile.
    public var mdev = ""
    /// IDs the guest sees instead of the device's own, e.g. `0x8086`; empty to pass them unchanged.
    public var vendorID = ""
    public var deviceID = ""
    public var subVendorID = ""
    public var subDeviceID = ""
    private var others = PropertyString(items: [])

    /// Keys of the ID overrides, in the order of the web interface.
    static let idKeys = ["vendor-id", "device-id", "sub-vendor-id", "sub-device-id"]

    public init() {}

    public init(_ value: String) {
        let property = PropertyString(parsing: value)
        if let mapping = property["mapping"] {
            usesMapping = true
            self.mapping = mapping
        }
        let host = property["host"] ?? property.defaultValue ?? ""
        // Without a function number (`.0`) the device is passed with all its functions.
        allFunctions = !host.isEmpty && !host.contains(".")
        self.host = host
        pcie = property["pcie"] == "1"
        romBar = property["rombar"] != "0"
        primaryGPU = property["x-vga"] == "1"
        mdev = property["mdev"] ?? ""
        vendorID = property["vendor-id"] ?? ""
        deviceID = property["device-id"] ?? ""
        subVendorID = property["sub-vendor-id"] ?? ""
        subDeviceID = property["sub-device-id"] ?? ""
        others.items = property.items.filter { $0.key != nil && !(["host", "mapping", "pcie", "rombar", "x-vga", "mdev"] + Self.idKeys).contains($0.key!) }
    }

    public var stringValue: String {
        var property = PropertyString(items: [])
        if usesMapping {
            property["mapping"] = mapping
        } else {
            property["host"] = allFunctions ? Self.withoutFunction(host) : host
        }
        if pcie { property["pcie"] = "1" }
        if !romBar { property["rombar"] = "0" }
        if primaryGPU { property["x-vga"] = "1" }
        if !mdev.isEmpty { property["mdev"] = mdev }
        for (key, value) in zip(Self.idKeys, [vendorID, deviceID, subVendorID, subDeviceID]) where !value.trimmed.isEmpty {
            property[key] = value.trimmed.lowercased()
        }
        property.items += others.items
        return property.stringValue
    }

    public var isComplete: Bool { (usesMapping ? !mapping.isEmpty : !host.isEmpty) && idProblem == nil }

    /// Proxmox takes the ID overrides as four hexadecimal digits with `0x`, e.g. `0x8086`.
    public var idProblem: String? {
        let valid = [vendorID, deviceID, subVendorID, subDeviceID].allSatisfy { value in
            let value = value.trimmed
            return value.isEmpty || (value.count == 6 && value.lowercased().hasPrefix("0x") && value.dropFirst(2).allSatisfy(\.isHexDigit))
        }
        return valid ? nil : String(localized: "Enter IDs as 0x and four hexadecimal digits, e.g. 0x8086.")
    }

    /// `0000:01:00.1` → `0000:01:00`.
    public static func withoutFunction(_ address: String) -> String {
        guard let dot = address.lastIndex(of: "."), address[address.index(after: dot)...].allSatisfy(\.isNumber) else { return address }
        return String(address[..<dot])
    }
}

/// Audio device and its backend.
public struct AudioDeviceDraft: Sendable, Equatable {
    public var device = "ich9-intel-hda"
    public var driver = "spice"

    public static let devices = ["ich9-intel-hda", "intel-hda", "AC97"]

    public init() {}

    public init(_ value: String) {
        let property = PropertyString(parsing: value)
        device = property["device"] ?? property.defaultValue ?? "ich9-intel-hda"
        driver = property["driver"] ?? "spice"
    }

    public var stringValue: String { "device=\(device),driver=\(driver)" }
}

/// VirtIO random number generator fed from a host entropy source.
public struct RNGDeviceDraft: Sendable, Equatable {
    public var source = "/dev/urandom"
    /// Bytes allowed per period, 0 for no limit.
    public var maxBytes = 1024
    /// Period in milliseconds.
    public var period = 1000

    public static let sources = ["/dev/urandom", "/dev/random", "/dev/hwrng"]

    public init() {}

    public init(_ value: String) {
        let property = PropertyString(parsing: value)
        source = property["source"] ?? property.defaultValue ?? "/dev/urandom"
        maxBytes = property["max_bytes"].flatMap { Int($0) } ?? 1024
        period = property["period"].flatMap { Int($0) } ?? 1000
    }

    public var stringValue: String {
        var property = PropertyString(items: [])
        property["source"] = source
        if maxBytes != 1024 { property["max_bytes"] = String(maxBytes) }
        if period != 1000 { property["period"] = String(period) }
        return property.stringValue
    }
}

/// A host directory shared with the VM through virtiofsd, by its directory mapping.
public struct VirtioFSDraft: Sendable, Equatable {
    public var directory = ""
    public var cache = ""
    public var directIO = false
    public var exposeACL = false
    public var exposeXattr = false

    public static let cacheModes = ["auto", "always", "metadata", "never"]

    public init() {}

    public init(_ value: String) {
        let property = PropertyString(parsing: value)
        directory = property["dirid"] ?? property.defaultValue ?? ""
        cache = property["cache"] ?? ""
        directIO = property["direct-io"] == "1"
        exposeACL = property["expose-acl"] == "1"
        exposeXattr = property["expose-xattr"] == "1"
    }

    public var stringValue: String {
        var property = PropertyString(items: [])
        property["dirid"] = directory
        if !cache.isEmpty { property["cache"] = cache }
        if directIO { property["direct-io"] = "1" }
        // ACL support implies extended attributes.
        if exposeACL { property["expose-acl"] = "1" } else if exposeXattr { property["expose-xattr"] = "1" }
        return property.stringValue
    }
}

/// Inter-VM shared memory.
public struct IVSHMEMDraft: Sendable, Equatable {
    public var sizeMiB = 32
    public var name = ""

    public init() {}

    public init(_ value: String) {
        let property = PropertyString(parsing: value)
        sizeMiB = property["size"].flatMap { Int($0) } ?? 32
        name = property["name"] ?? ""
    }

    public var stringValue: String {
        var property = PropertyString(items: [])
        property["size"] = String(sizeMiB)
        if !name.trimmed.isEmpty { property["name"] = name.trimmed }
        return property.stringValue
    }
}

extension GuestConfig {
    /// Value for a new EFI vars disk; Proxmox allocates the right size. `format` is for storages with several image formats.
    public static func efiDiskValue(storage: String, preEnrolledKeys: Bool, format: String? = nil) -> String {
        var property = PropertyString(items: [(key: nil, value: "\(storage):1")])
        if let format { property["format"] = format }
        property["efitype"] = "4m"
        if preEnrolledKeys {
            property["pre-enrolled-keys"] = "1"
            property["ms-cert"] = "2023k"
        }
        return property.stringValue
    }

    /// Value for a new TPM state disk.
    public static func tpmStateValue(storage: String, version: String) -> String {
        "\(storage):1,version=\(version)"
    }
}

/// A PCI device of a node.
public struct NodePCIDevice: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let vendorName: String?
    public let deviceName: String?
    public let iommuGroup: Int?
    /// Whether the device offers mediated devices (vGPU).
    public let mdev: Bool?
    /// `0x8086`-style IDs, for resource mappings.
    public let vendor: String?
    public let device: String?
    public let subsystemVendor: String?
    public let subsystemDevice: String?

    enum CodingKeys: String, CodingKey {
        case id, mdev, vendor, device
        case vendorName = "vendor_name"
        case deviceName = "device_name"
        case iommuGroup = "iommugroup"
        case subsystemVendor = "subsystem_vendor"
        case subsystemDevice = "subsystem_device"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        vendorName = try? container.decode(String.self, forKey: .vendorName)
        deviceName = try? container.decode(String.self, forKey: .deviceName)
        iommuGroup = try? container.decode(Int.self, forKey: .iommuGroup)
        mdev = (try? container.decode(Bool.self, forKey: .mdev)) ?? (try? container.decode(Int.self, forKey: .mdev)).map { $0 != 0 }
        vendor = try? container.decode(String.self, forKey: .vendor)
        device = try? container.decode(String.self, forKey: .device)
        subsystemVendor = try? container.decode(String.self, forKey: .subsystemVendor)
        subsystemDevice = try? container.decode(String.self, forKey: .subsystemDevice)
    }

    /// `8086:293e`, as resource mappings expect.
    public var vendorDeviceID: String? {
        guard let vendor, let device else { return nil }
        return "\(vendor):\(device)".replacingOccurrences(of: "0x", with: "")
    }

    public var subsystemID: String? {
        guard let subsystemVendor, let subsystemDevice else { return nil }
        return "\(subsystemVendor):\(subsystemDevice)".replacingOccurrences(of: "0x", with: "")
    }
}

/// A mediated device type a PCI device offers, e.g. a vGPU profile, from `GET .../hardware/pci/{id}/mdev`.
public struct MediatedDeviceType: Decodable, Sendable, Hashable, Identifiable {
    public let type: String
    public let name: String?
    /// Instances of this type that can still be created.
    public let available: Int?
    public let description: String?

    public var id: String { type }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        type = container.lossyString(AnyCodingKey("type")) ?? ""
        name = container.lossyString(AnyCodingKey("name"))
        available = container.lossyInt(AnyCodingKey("available"))
        description = container.lossyString(AnyCodingKey("description")).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A USB device of a node.
public struct NodeUSBDevice: Decodable, Sendable, Hashable, Identifiable {
    public let busNumber: Int
    public let usbPath: String?
    public let vendorID: String
    public let productID: String
    public let product: String?
    public let manufacturer: String?
    public let deviceClass: Int?

    public var id: String { "\(busNumber)-\(usbPath ?? "")-\(vendorID):\(productID)" }
    /// `vendor:product`, stable when the device moves to another port.
    public var deviceID: String { "\(vendorID):\(productID)" }
    /// `bus-port`, for passing whatever is plugged into that port.
    public var portID: String? { usbPath.map { "\(busNumber)-\($0)" } }
    /// Hubs and root hubs cannot be passed through.
    public var isHub: Bool { deviceClass == 9 }

    enum CodingKeys: String, CodingKey {
        case product, manufacturer
        case busNumber = "busnum"
        case usbPath = "usbpath"
        case vendorID = "vendid"
        case productID = "prodid"
        case deviceClass = "class"
    }
}

/// A cluster-wide resource mapping (PCI, USB or directory).
public struct ResourceMapping: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let description: String?
    /// PCI mappings: whether the mapped devices offer mediated devices.
    public let mdev: Bool?

    enum CodingKeys: String, CodingKey { case id, description, mdev }

    public init(id: String, description: String? = nil, mdev: Bool? = nil) {
        self.id = id
        self.description = description
        self.mdev = mdev
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        description = try? container.decode(String.self, forKey: .description)
        mdev = (try? container.decode(Bool.self, forKey: .mdev)) ?? (try? container.decode(Int.self, forKey: .mdev)).map { $0 != 0 }
    }
}

extension PVE {
    public static func pciDevices(node: String) -> APIRequest<[NodePCIDevice]> {
        APIRequest(.get, "/nodes/\(node)/hardware/pci", parameters: ["pci-class-blacklist": ""])
    }

    /// Mediated device types of a host PCI device (`0000:01:00.0`) or of a PCI mapping's device on the node.
    public static func mediatedDeviceTypes(node: String, device: String) -> APIRequest<[MediatedDeviceType]> {
        APIRequest(.get, "/nodes/\(node)/hardware/pci/\(escapePath(device))/mdev")
    }

    public static func usbDevices(node: String) -> APIRequest<[NodeUSBDevice]> {
        APIRequest(.get, "/nodes/\(node)/hardware/usb")
    }

    /// `pci`, `usb` or `dir`.
    public static func resourceMappings(_ type: String) -> APIRequest<[ResourceMapping]> {
        APIRequest(.get, "/cluster/mapping/\(type)")
    }
}
