import Foundation
import ProxmoxCore

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
        ["id": "0000:00:02.0", "vendor_name": "Intel Corporation", "device_name": "Alder Lake-N [UHD Graphics]", "iommugroup": 0, "mdev": 1],
        ["id": "0000:01:00.0", "vendor_name": "NVIDIA Corporation", "device_name": "GA106 [RTX A2000 12GB]", "iommugroup": 14],
        ["id": "0000:01:00.1", "vendor_name": "NVIDIA Corporation", "device_name": "GA106 High Definition Audio Controller", "iommugroup": 14],
        ["id": "0000:04:00.0", "vendor_name": "Intel Corporation", "device_name": "Ethernet Controller I226-V", "iommugroup": 17],
        ["id": "0000:05:00.0", "vendor_name": "ASMedia Technology Inc.", "device_name": "ASM1166 Serial ATA Controller", "iommugroup": 18],
    ]

    static let usbDevices: JSONValue = [
        ["busnum": 1, "devnum": 1, "port": 0, "level": 0, "class": 9, "vendid": "1d6b", "prodid": "0002", "product": "xHCI Host Controller", "manufacturer": "Linux xhci-hcd"],
        ["busnum": 1, "devnum": 3, "port": 3, "level": 1, "usbpath": "3", "class": 0, "vendid": "10c4", "prodid": "ea60", "product": "Sonoff Zigbee 3.0 USB Dongle Plus", "manufacturer": "ITead"],
        ["busnum": 1, "devnum": 4, "port": 4, "level": 1, "usbpath": "4", "class": 0, "vendid": "0463", "prodid": "ffff", "product": "5E", "manufacturer": "Eaton"],
        ["busnum": 2, "devnum": 2, "port": 1, "level": 1, "usbpath": "1", "class": 0, "vendid": "046d", "prodid": "c52b", "product": "USB Receiver", "manufacturer": "Logitech"],
    ]

    func resourceMappings(_ type: String) -> JSONValue {
        switch type {
        case "pci": [["id": "gpu-a2000", "description": "NVIDIA RTX A2000 on pve1"]]
        case "usb": [["id": "zigbee-dongle", "description": "Sonoff Zigbee coordinator"]]
        case "dir": [["id": "media", "description": "/tank/media on every node"]]
        default: []
        }
    }

    // MARK: - Disks

    /// Turns a new disk such as `local-lvm:32` or `local-lvm:cloudinit` into an allocated volume, like Proxmox does.
    func allocateVolume(_ value: String, key: String, guest: DemoCluster.Guest) -> String {
        guard Self.isDiskKey(key) else { return value }
        var property = PropertyString(parsing: value)
        guard let source = property.defaultValue ?? property["file"] ?? property["volume"],
              let colon = source.firstIndex(of: ":") else { return value }
        let storage = source[..<colon]
        let size = source[source.index(after: colon)...]
        let allocated: String
        if size == "cloudinit" {
            allocated = "\(storage):vm-\(guest.vmid)-cloudinit"
            property["media"] = "cdrom"
        } else if let gib = Double(size) {
            allocated = "\(storage):vm-\(guest.vmid)-disk-\(nextDiskNumber(for: guest.vmid))"
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
