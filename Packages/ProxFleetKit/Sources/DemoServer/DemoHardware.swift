import Foundation
import ProxmoxCore

/// A PCI, USB or directory mapping in demo mode.
struct DemoMapping: Sendable {
    var id: String
    var values: [String: String]
    var map: [String]
}

/// Consoles, host devices, resource mappings and disk handling in demo mode.
extension DemoState {
    // MARK: - Consoles

    /// Answers `termproxy` or `vncproxy` like Proxmox does and remembers the console for its WebSocket.
    func startConsole(_ console: DemoConsoleRequest, user: String) -> HTTPResponse {
        let ticket = "PVEVNC:DEMO\(UUID().uuidString.prefix(8))::demo-signature"
        consoles[ticket] = console
        return success([
            "port": .int(5900 + consoles.count), "ticket": .string(ticket), "user": .string(user),
            "upid": .string("UPID:demo:00000000:00000000:00000000:vncproxy::\(user):"), "password": "demo1234",
        ])
    }

    func osName(for guest: DemoCluster.Guest) -> String {
        if guest.name.contains("ubuntu") { return "Ubuntu 24.04.3 LTS" }
        return "Debian GNU/Linux 13 (trixie)"
    }

    // MARK: - Host devices

    static let pciDevices: JSONValue = [
        ["id": "0000:00:02.0", "vendor_name": "Intel Corporation", "device_name": "Alder Lake-N [UHD Graphics]", "iommugroup": 0, "mdev": 1,
         "vendor": "0x8086", "device": "0x46d1", "subsystem_vendor": "0x8086", "subsystem_device": "0x7270"],
        ["id": "0000:01:00.0", "vendor_name": "NVIDIA Corporation", "device_name": "GA106 [RTX A2000 12GB]", "iommugroup": 14,
         "vendor": "0x10de", "device": "0x2571", "subsystem_vendor": "0x10de", "subsystem_device": "0x1611"],
        ["id": "0000:01:00.1", "vendor_name": "NVIDIA Corporation", "device_name": "GA106 High Definition Audio Controller", "iommugroup": 14,
         "vendor": "0x10de", "device": "0x228e", "subsystem_vendor": "0x10de", "subsystem_device": "0x1611"],
        ["id": "0000:04:00.0", "vendor_name": "Intel Corporation", "device_name": "Ethernet Controller I226-V", "iommugroup": 17,
         "vendor": "0x8086", "device": "0x125c", "subsystem_vendor": "0x8086", "subsystem_device": "0x0000"],
        ["id": "0000:05:00.0", "vendor_name": "ASMedia Technology Inc.", "device_name": "ASM1166 Serial ATA Controller", "iommugroup": 18,
         "vendor": "0x1b21", "device": "0x1166", "subsystem_vendor": "0x2116", "subsystem_device": "0x2116"],
    ]

    /// The integrated GPU, directly or by its mapping, offers GVT-g vGPUs; other devices have no mediated devices.
    static func mediatedDeviceTypes(of device: String) -> JSONValue {
        guard device == "0000:00:02.0" || device == "igpu" else { return [] }
        return [
            ["type": "i915-GVTg_V5_4", "available": 2, "description": "low_gm_size: 128MB\nhigh_gm_size: 512MB\nfence: 4\nresolution: 1920x1200"],
            ["type": "i915-GVTg_V5_8", "available": 4, "description": "low_gm_size: 64MB\nhigh_gm_size: 384MB\nfence: 4\nresolution: 1024x768"],
        ]
    }

    static let usbDevices: JSONValue = [
        ["busnum": 1, "devnum": 1, "port": 0, "level": 0, "class": 9, "vendid": "1d6b", "prodid": "0002", "product": "xHCI Host Controller", "manufacturer": "Linux xhci-hcd"],
        ["busnum": 1, "devnum": 3, "port": 3, "level": 1, "usbpath": "3", "class": 0, "vendid": "10c4", "prodid": "ea60", "product": "Sonoff Zigbee 3.0 USB Dongle Plus", "manufacturer": "ITead"],
        ["busnum": 1, "devnum": 4, "port": 4, "level": 1, "usbpath": "4", "class": 0, "vendid": "0463", "prodid": "ffff", "product": "5E", "manufacturer": "Eaton"],
        ["busnum": 2, "devnum": 2, "port": 1, "level": 1, "usbpath": "1", "class": 0, "vendid": "046d", "prodid": "c52b", "product": "USB Receiver", "manufacturer": "Logitech"],
    ]

    static func sampleMappings(for cluster: DemoCluster) -> [String: [DemoMapping]] {
        let node = cluster.nodes.first?.name ?? "pve"
        return [
            "pci": [
                DemoMapping(id: "gpu-a2000", values: ["description": "NVIDIA RTX A2000 on \(node)"],
                            map: ["node=\(node),path=0000:01:00,id=10de:2571,subsystem-id=10de:1611,iommugroup=14"]),
                DemoMapping(id: "igpu", values: ["description": "Intel UHD Graphics (GVT-g)", "mdev": "1"],
                            map: ["node=\(node),path=0000:00:02.0,id=8086:46d1,subsystem-id=8086:7270,iommugroup=0"]),
            ],
            "usb": [DemoMapping(id: "zigbee-dongle", values: ["description": "Sonoff Zigbee coordinator"], map: ["node=\(node),id=10c4:ea60"])],
            "dir": [DemoMapping(id: "media", values: ["description": "/tank/media on every node"], map: cluster.nodes.map { "node=\($0.name),path=/tank/media" })],
        ]
    }

    /// `/cluster/mapping/{pci,usb,dir}`. nil for other paths.
    func handleMappings(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard parts.count >= 3, parts[0] == "cluster", parts[1] == "mapping", ["pci", "usb", "dir"].contains(parts[2]) else { return nil }
        let type = parts[2]
        if method != .get, !privileges(for: user).contains("Mapping.Modify") { return failure(403, "Permission check failed (/mapping/\(type), Mapping.Modify)") }
        let entries = (parameters["map"] ?? "").split(separator: Character(Self.listSeparator)).map(String.init).filter { !$0.isEmpty }
        let keys: Set<String> = ["description", "mdev", "live-migration-capable"]
        switch (method, parts.count) {
        case (.get, 3):
            return success(.array((mappings[type] ?? []).map { mappingJSON($0, type: type, checks: parameters["check-node"] != nil) }))
        case (.post, 3):
            let id = parameters["id"] ?? ""
            guard !id.isEmpty else { return fieldFailure(["id": "property is missing and it is not optional"]) }
            guard !(mappings[type] ?? []).contains(where: { $0.id == id }) else { return failure(500, "\(type) mapping '\(id)' already defined") }
            guard !entries.isEmpty else { return fieldFailure(["map": "property is missing and it is not optional"]) }
            mappings[type, default: []].append(DemoMapping(id: id, values: parameters.filter { keys.contains($0.key) }, map: entries))
            return success(nil)
        case (.put, 4):
            guard let index = mappings[type]?.firstIndex(where: { $0.id == parts[3] }) else { return failure(500, "\(type) mapping '\(parts[3])' does not exist") }
            if let digest = parameters["digest"], digest != mappingDigest(mappings[type]![index]) {
                return failure(500, "detected modified configuration - file changed by other user? Try again.")
            }
            for key in (parameters["delete"] ?? "").split(separator: ",") { mappings[type]![index].values[String(key)] = nil }
            for (key, value) in parameters where keys.contains(key) { mappings[type]![index].values[key] = value }
            if !entries.isEmpty { mappings[type]![index].map = entries }
            return success(nil)
        case (.delete, 4):
            guard let index = mappings[type]?.firstIndex(where: { $0.id == parts[3] }) else { return failure(500, "\(type) mapping '\(parts[3])' does not exist") }
            mappings[type]!.remove(at: index)
            return success(nil)
        default:
            return nil
        }
    }

    private func mappingDigest(_ mapping: DemoMapping) -> String {
        String(format: "%08x", (mapping.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + mapping.map).joined().hashValue & 0xffff_ffff)
    }

    private func mappingJSON(_ mapping: DemoMapping, type: String, checks: Bool) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(mapping.id), "type": .string(type), "map": .array(mapping.map.map { .string($0) }),
                                           "digest": .string(mappingDigest(mapping))]
        for (key, value) in mapping.values { object[key] = key == "description" ? .string(value) : .int(Int(value) ?? 0) }
        if checks { object[type == "usb" ? "errors" : "checks"] = [] }
        return .object(object)
    }

    // MARK: - Disks

    /// Turns a new disk such as `local-lvm:32` or `local-lvm:cloudinit` into an allocated volume, like Proxmox does.
    func allocateVolume(_ value: String, key: String, guest: DemoCluster.Guest) -> String {
        guard Self.isDiskKey(key) else { return value }
        var property = PropertyString(parsing: value)
        guard let source = property.defaultValue ?? property["file"] ?? property["volume"],
              let colon = source.firstIndex(of: ":") else { return value }
        let storage = source[..<colon]
        var size = source[source.index(after: colon)...]
        // An import takes the size of its image.
        if let image = property["import-from"] {
            property["import-from"] = nil
            let bytes = files.first { $0.volume == image }?.size ?? 2_147_483_648
            size = Substring(String(max(1, Int((Double(bytes) / 1_073_741_824).rounded(.up)))))
        }
        let allocated: String
        if size == "cloudinit" {
            allocated = "\(storage):vm-\(guest.vmid)-cloudinit"
            property["media"] = "cdrom"
        } else if let gib = Double(size) {
            // The format only picks the image type; directory storages show it as the file extension.
            let format = property["format"]
            property["format"] = nil
            let suffix = format.map { $0 == "raw" ? "" : ".\($0)" } ?? ""
            allocated = "\(storage):vm-\(guest.vmid)-disk-\(nextDiskNumber(for: guest.vmid))\(suffix)"
            let isSmallStateDisk = key.hasPrefix("efidisk") || key.hasPrefix("tpmstate")
            property["size"] = isSmallStateDisk ? "4M" : "\(Int(gib))G"
        } else {
            return value
        }
        if property.items.first?.key == nil, !property.items.isEmpty {
            property.items[0].value = allocated
        } else {
            property.items.insert((key: nil, value: allocated), at: 0)
        }
        return property.stringValue
    }

    /// The volume a removed disk leaves behind as `unusedN`, or nil for drives without one.
    static func detachableVolume(key: String, value: String?) -> String? {
        guard let value, isDiskKey(key), !key.hasPrefix("unused") else { return nil }
        let property = PropertyString(parsing: value)
        guard property["media"] != "cdrom", let volume = property.defaultValue ?? property["file"], volume.contains(":vm-") else { return nil }
        return volume
    }

    static func isDiskKey(_ key: String) -> Bool {
        if ["rootfs", "efidisk0", "tpmstate0"].contains(key) { return true }
        return ["scsi", "sata", "ide", "virtio", "mp", "unused"].contains { prefix in
            key.hasPrefix(prefix) && Int(key.dropFirst(prefix.count)) != nil
        }
    }

    private func nextDiskNumber(for vmid: Int) -> Int {
        var used: Set<Int> = []
        for guest in cluster.guests {
            for value in currentConfig(guest).values {
                guard let range = value.range(of: "vm-\(vmid)-disk-") else { continue }
                if let number = Int(value[range.upperBound...].prefix { $0.isNumber }) { used.insert(number) }
            }
        }
        return (0...).first { !used.contains($0) } ?? 0
    }

    /// `move_disk` and `move_volume`: to another storage, or with `target-vmid` to another guest.
    func moveDisk(_ guest: DemoCluster.Guest, parameters: [String: String], user: String) -> HTTPResponse {
        let isVM = guest.kind == .qemu
        guard let key = parameters[isVM ? "disk" : "volume"], let value = currentConfig(guest)[key] else {
            return failure(500, "disk does not exist")
        }
        var property = PropertyString(parsing: value)
        guard let volume = property.defaultValue, let colon = volume.firstIndex(of: ":") else {
            return failure(500, "cannot move this disk")
        }

        if let targetText = parameters["target-vmid"], let targetVMID = Int(targetText),
           let targetKey = parameters[isVM ? "target-disk" : "target-volume"],
           let target = cluster.guests.first(where: { $0.vmid == targetVMID && $0.kind == guest.kind }) {
            guard target.node == guest.node else { return failure(500, "target guest is on another node") }
            guard currentConfig(target)[targetKey] == nil else { return failure(500, "target disk \(targetKey) already exists") }
            property.items[0].value = "\(volume[..<colon]):vm-\(targetVMID)-disk-\(nextDiskNumber(for: targetVMID))"
            configEdits[targetVMID, default: [:]][targetKey] = .some(key.hasPrefix("unused") ? property.items[0].value : property.stringValue)
            configEdits[guest.vmid, default: [:]][key] = .some(nil)
            configRevisions[targetVMID, default: 0] += 1
        } else if let storage = parameters["storage"] {
            property.items[0].value = "\(storage):vm-\(guest.vmid)-disk-\(nextDiskNumber(for: guest.vmid))"
            configEdits[guest.vmid, default: [:]][key] = .some(property.stringValue)
            if parameters["delete"] != "1" {
                let config = currentConfig(guest)
                if let unused = (0..<256).map({ "unused\($0)" }).first(where: { config[$0] == nil }) {
                    configEdits[guest.vmid, default: [:]][unused] = .some(volume)
                }
            }
        } else {
            return failure(400, "Parameter verification failed.")
        }
        configRevisions[guest.vmid, default: 0] += 1
        return startConfigTask(guest, user: user, type: isVM ? "qmmove" : "move_volume")
    }
}
