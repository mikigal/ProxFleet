import Foundation
import ProxmoxCore

/// Disks of a node in demo mode and what is built on them.
struct DemoDiskLayout: Sendable {
    struct Disk: Sendable {
        var path: String
        var model: String
        var serial: String
        var sizeGiB: Int
        var type: String
        var usage: String?
        var hasGPT: Bool
        var wearout: Int?
        var partitions: [(name: String, sizeGiB: Int, usage: String)] = []
    }

    struct Pool: Sendable {
        var name: String
        var raidLevel: String
        var devices: [String]
        var sizeGiB: Int
        var usedGiB: Double
    }

    struct VolumeGroup: Sendable {
        var name: String
        var device: String
        var sizeGiB: Int
        var freeGiB: Int
        var volumes: Int
    }

    struct ThinPool: Sendable {
        var name: String
        var volumeGroup: String
        var sizeGiB: Int
        var usedGiB: Double
    }

    struct Directory: Sendable {
        var name: String
        var device: String
        var fileSystem: String
    }

    var disks: [Disk]
    var pools: [Pool] = []
    var volumeGroups: [VolumeGroup] = []
    var thinPools: [ThinPool] = []
    var directories: [Directory] = []

    /// An NVMe system disk with the installer's LVM layout, plus spare disks; the first node also has a ZFS mirror.
    static func standard(first: Bool) -> DemoDiskLayout {
        var layout = DemoDiskLayout(disks: [
            Disk(path: "/dev/nvme0n1", model: "Samsung SSD 980 PRO 1TB", serial: "S69ENF0R812345", sizeGiB: 931, type: "nvme", usage: "partitions", hasGPT: true, wearout: 97,
                 partitions: [("nvme0n1p1", 0, "BIOS boot"), ("nvme0n1p2", 1, "EFI"), ("nvme0n1p3", 930, "LVM")]),
            Disk(path: "/dev/sdc", model: "Samsung SSD 870 EVO 500GB", serial: "S6PWNX0T401928", sizeGiB: 466, type: "ssd", usage: nil, hasGPT: false, wearout: 100),
            Disk(path: "/dev/sdd", model: "WDC WD40EFZX-68AWUN0", serial: "WD-WX12D80KL4A2", sizeGiB: 3726, type: "hdd", usage: nil, hasGPT: true, wearout: nil),
        ], volumeGroups: [VolumeGroup(name: "pve", device: "/dev/nvme0n1p3", sizeGiB: 930, freeGiB: 16, volumes: 14)],
           thinPools: [ThinPool(name: "data", volumeGroup: "pve", sizeGiB: 800, usedGiB: 310)])
        if first {
            layout.disks += [
                Disk(path: "/dev/sda", model: "WDC WD80EFAX-68KNBN0", serial: "VAG8K2LL", sizeGiB: 7452, type: "hdd", usage: "partitions", hasGPT: true, wearout: nil,
                     partitions: [("sda1", 7452, "ZFS"), ("sda9", 0, "ZFS reserved")]),
                Disk(path: "/dev/sdb", model: "WDC WD80EFAX-68KNBN0", serial: "VAG8M1TQ", sizeGiB: 7452, type: "hdd", usage: "partitions", hasGPT: true, wearout: nil,
                     partitions: [("sdb1", 7452, "ZFS"), ("sdb9", 0, "ZFS reserved")]),
            ]
            layout.pools = [Pool(name: "tank", raidLevel: "mirror", devices: ["/dev/sda", "/dev/sdb"], sizeGiB: 7440, usedGiB: 2210)]
        }
        return layout
    }
}

extension DemoState {
    private static let gib = 1_073_741_824.0

    func diskLayout(_ node: String) -> DemoDiskLayout {
        diskLayouts[node] ?? .standard(first: node == cluster.nodes.first?.name)
    }

    /// Routes below `/nodes/{node}/disks`. nil for other paths.
    func handleDisks(_ method: HTTPMethod, node: String, rest: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard rest.first == "disks", let info = cluster.nodes.first(where: { $0.name == node }) else { return nil }
        guard info.isOnline else { return failure(595, "Connection refused: node '\(node)' seems to be offline") }
        if method != .get, !privileges(for: user).contains("Sys.Modify") {
            return failure(403, "Permission check failed (/, Sys.Modify)")
        }
        var layout = diskLayout(node)
        defer { diskLayouts[node] = layout }

        switch (method, Array(rest.dropFirst())) {
        case (.get, ["list"]):
            return success(.array(layout.disks.flatMap { disk in
                diskJSON(disk) + (parameters["include-partitions"] == "1" ? disk.partitions.map { partitionJSON($0, of: disk) } : [])
            }))
        case (.get, ["smart"]):
            guard let disk = layout.disks.first(where: { $0.path == parameters["disk"] }) else { return failure(500, "no such disk") }
            return success(smartJSON(disk))
        case (.post, ["initgpt"]):
            guard let index = layout.disks.firstIndex(where: { $0.path == parameters["disk"] }) else { return failure(500, "no such disk") }
            guard layout.disks[index].usage == nil else { return failure(500, "disk \(layout.disks[index].path) already in use") }
            layout.disks[index].hasGPT = true
            return startTask(node: node, type: "diskinit", objectID: layout.disks[index].path.replacingOccurrences(of: "/dev/", with: ""), user: user, duration: 1.5)
        case (.put, ["wipedisk"]):
            guard let index = layout.disks.firstIndex(where: { $0.path == parameters["disk"] }) else { return failure(500, "no such disk") }
            let disk = layout.disks[index]
            let directory = layout.directories.contains { $0.device == disk.path }
            let pool = layout.pools.contains { $0.devices.contains(disk.path) }
            guard disk.path != "/dev/nvme0n1", disk.usage != "LVM", !pool, !directory else {
                return failure(500, "disk '\(disk.path)' is in use")
            }
            layout.disks[index].usage = nil
            layout.disks[index].hasGPT = false
            layout.disks[index].partitions = []
            layout.pools.removeAll { $0.devices.contains(layout.disks[index].path) }
            return startTask(node: node, type: "wipedisk", objectID: layout.disks[index].path.replacingOccurrences(of: "/dev/", with: ""), user: user, duration: 1.5)
        case (.get, ["lvm"]):
            return success(["leaf": 0, "children": .array(layout.volumeGroups.map { group in
                [
                    "name": .string(group.name), "size": .int(Int(Double(group.sizeGiB) * Self.gib)), "free": .int(Int(Double(group.freeGiB) * Self.gib)),
                    "lvcount": .int(group.volumes), "leaf": 0,
                    "children": [["name": .string(group.device), "size": .int(Int(Double(group.sizeGiB) * Self.gib)), "free": .int(Int(Double(group.freeGiB) * Self.gib)), "leaf": 1]],
                ]
            })])
        case (.get, ["lvmthin"]):
            return success(.array(layout.thinPools.map { pool in
                [
                    "lv": .string(pool.name), "vg": .string(pool.volumeGroup), "lv_size": .int(Int(Double(pool.sizeGiB) * Self.gib)),
                    "used": .int(Int(pool.usedGiB * Self.gib)), "metadata_size": .int(Int(Self.gib)), "metadata_used": .int(Int(Self.gib * 0.12)),
                    "lv_type": "t", "lv_state": "a",
                ]
            }))
        case (.get, ["zfs"]):
            return success(.array(layout.pools.map { pool in
                [
                    "name": .string(pool.name), "size": .int(Int(Double(pool.sizeGiB) * Self.gib)), "alloc": .int(Int(pool.usedGiB * Self.gib)),
                    "free": .int(Int((Double(pool.sizeGiB) - pool.usedGiB) * Self.gib)), "frag": 3, "dedup": 1.0, "health": "ONLINE",
                ]
            }))
        case (.get, let path) where path.count == 2 && path[0] == "zfs":
            guard let pool = layout.pools.first(where: { $0.name == path[1] }) else { return failure(500, "zpool '\(path[1])' does not exist") }
            return success(zfsStatusJSON(pool))
        case (.get, ["directory"]):
            return success(.array(layout.directories.map { directory in
                [
                    "path": .string("/mnt/pve/\(directory.name)"), "device": .string("/dev/disk/by-uuid/\(abs(directory.name.hashValue) % 100_000_000)-demo"), "type": .string(directory.fileSystem),
                    "options": "defaults", "unitfile": .string("/etc/systemd/system/mnt-pve-\(directory.name).mount"),
                ]
            }))
        case (.post, let path) where path.count == 1 && ["lvm", "lvmthin", "zfs", "directory"].contains(path[0]):
            return createStorage(kind: path[0], node: node, layout: &layout, parameters: parameters, user: user)
        case (.delete, let path) where path.count == 2 && ["lvm", "lvmthin", "zfs", "directory"].contains(path[0]):
            return deleteStorage(kind: path[0], name: path[1], node: node, layout: &layout, parameters: parameters, user: user)
        default:
            return nil
        }
    }

    private func createStorage(kind: String, node: String, layout: inout DemoDiskLayout, parameters: [String: String], user: String) -> HTTPResponse {
        guard let name = parameters["name"], !name.isEmpty else { return fieldFailure(["name": "property is missing and it is not optional"]) }
        let devices = (kind == "zfs" ? parameters["devices"] : parameters["device"])?.split(separator: ",").map(String.init) ?? []
        let key = kind == "zfs" ? "devices" : "device"
        guard !devices.isEmpty else { return fieldFailure([key: "property is missing and it is not optional"]) }
        var indices: [Int] = []
        for device in devices {
            guard let index = layout.disks.firstIndex(where: { $0.path == device }) else { return failure(500, "unable to find device '\(device)'") }
            guard layout.disks[index].usage == nil else { return failure(500, "device '\(device)' is already in use") }
            indices.append(index)
        }
        let taken = layout.pools.map(\.name) + layout.volumeGroups.map(\.name) + layout.thinPools.map(\.name) + layout.directories.map(\.name)
        guard !taken.contains(name) else { return failure(500, "storage ID '\(name)' already defined") }
        let size = indices.map { layout.disks[$0].sizeGiB }.min() ?? 0
        switch kind {
        case "zfs":
            let level = parameters["raidlevel"] ?? "single"
            let minimum = ["mirror": 2, "raid10": 4, "raidz": 3, "raidz2": 4, "raidz3": 5][level] ?? 1
            guard devices.count >= minimum else { return failure(500, "\(level) needs at least \(minimum) disks") }
            if level != "single", Set(indices.map { layout.disks[$0].sizeGiB }).count > 1 {
                let paths = devices.map { "/dev/disk/by-id/ata-\($0.replacingOccurrences(of: "/dev/", with: ""))" }.joined(separator: " ")
                return startTask(node: node, type: "zfscreate", objectID: name, user: user, duration: 1,
                                 error: "command '/sbin/zpool create -o 'ashift=12' \(name) \(level) \(paths)' failed: exit code 1")
            }
            let usable = ["mirror": 1, "raid10": devices.count / 2, "raidz": devices.count - 1, "raidz2": devices.count - 2, "raidz3": devices.count - 3][level] ?? devices.count
            layout.pools.append(.init(name: name, raidLevel: level, devices: devices, sizeGiB: size * usable, usedGiB: 0.01))
            for index in indices {
                // Proxmox reports the disk as partitioned; its partitions are ZFS and ZFS reserved.
                layout.disks[index].usage = "partitions"
                layout.disks[index].hasGPT = true
                let base = layout.disks[index].path.replacingOccurrences(of: "/dev/", with: "")
                layout.disks[index].partitions = [("\(base)1", size, "ZFS"), ("\(base)9", 0, "ZFS reserved")]
            }
        case "lvm":
            layout.volumeGroups.append(.init(name: name, device: devices[0], sizeGiB: size, freeGiB: size, volumes: 0))
            layout.disks[indices[0]].usage = "LVM"
        case "lvmthin":
            layout.volumeGroups.append(.init(name: name, device: devices[0], sizeGiB: size, freeGiB: 0, volumes: 1))
            layout.thinPools.append(.init(name: name, volumeGroup: name, sizeGiB: size - 1, usedGiB: 0))
            layout.disks[indices[0]].usage = "LVM"
        default:
            let fileSystem = parameters["filesystem"] ?? "ext4"
            layout.directories.append(.init(name: name, device: devices[0], fileSystem: fileSystem))
            let base = devices[0].replacingOccurrences(of: "/dev/", with: "")
            layout.disks[indices[0]].usage = "partitions"
            layout.disks[indices[0]].hasGPT = true
            layout.disks[indices[0]].partitions = [("\(base)1", size, fileSystem)]
        }
        let type = ["zfs": "zfscreate", "lvm": "lvmcreate", "lvmthin": "lvmthincreate", "directory": "dircreate"][kind] ?? kind
        return startTask(node: node, type: type, objectID: name, user: user, duration: 2.5)
    }

    private func deleteStorage(kind: String, name: String, node: String, layout: inout DemoDiskLayout, parameters: [String: String], user: String) -> HTTPResponse {
        if name == "pve" || name == "data" { return failure(500, "volume group '\(name)' holds the root file system") }
        var devices: [String] = []
        switch kind {
        case "zfs":
            guard let index = layout.pools.firstIndex(where: { $0.name == name }) else { return failure(500, "zpool '\(name)' does not exist") }
            devices = layout.pools.remove(at: index).devices
        case "lvm":
            guard let index = layout.volumeGroups.firstIndex(where: { $0.name == name }) else { return failure(500, "volume group '\(name)' does not exist") }
            guard !layout.thinPools.contains(where: { $0.volumeGroup == name }) else { return failure(500, "volume group '\(name)' still has logical volumes") }
            devices = [layout.volumeGroups.remove(at: index).device]
        case "lvmthin":
            guard let index = layout.thinPools.firstIndex(where: { $0.name == name && $0.volumeGroup == parameters["volume-group"] }) else {
                return failure(500, "thin pool '\(name)' does not exist")
            }
            let pool = layout.thinPools.remove(at: index)
            if let group = layout.volumeGroups.firstIndex(where: { $0.name == pool.volumeGroup }) {
                // Wiping the disks also removes the volume group, as Proxmox does.
                if parameters["cleanup-disks"] == "1" {
                    devices = [layout.volumeGroups.remove(at: group).device]
                } else {
                    layout.volumeGroups[group].volumes = 0
                    layout.volumeGroups[group].freeGiB = layout.volumeGroups[group].sizeGiB
                }
            }
        default:
            guard let index = layout.directories.firstIndex(where: { $0.name == name }) else { return failure(500, "mount point '/mnt/pve/\(name)' does not exist") }
            devices = [layout.directories.remove(at: index).device]
        }
        if parameters["cleanup-disks"] == "1" {
            for device in devices {
                guard let index = layout.disks.firstIndex(where: { $0.path == device }) else { continue }
                layout.disks[index].usage = nil
                layout.disks[index].hasGPT = false
                layout.disks[index].partitions = []
            }
        }
        let type = ["zfs": "zfsremove", "lvm": "lvmremove", "lvmthin": "lvmthinremove", "directory": "dirremove"][kind] ?? kind
        let objectID = kind == "lvmthin" ? "\(parameters["volume-group"] ?? name)-\(name)" : name
        return startTask(node: node, type: type, objectID: objectID, user: user, duration: 1.5)
    }

    private func diskJSON(_ disk: DemoDiskLayout.Disk) -> [JSONValue] {
        var object: [String: JSONValue] = [
            "devpath": .string(disk.path), "model": .string(disk.model), "serial": .string(disk.serial), "vendor": "ATA     ",
            "size": .int(Int(Double(disk.sizeGiB) * Self.gib)), "type": .string(disk.type), "health": disk.type == "nvme" ? "PASSED" : "OK",
            "wearout": disk.wearout.map { .int($0) } ?? "N/A", "gpt": .int(disk.hasGPT ? 1 : 0), "rpm": .int(disk.type == "hdd" ? 5400 : 0),
            "wwn": "unknown", "osdid": -1, "osdid-list": nil, "mounted": 0,
            "by_id_link": .string("/dev/disk/by-id/ata-\(disk.model.replacingOccurrences(of: " ", with: "_"))_\(disk.serial)"),
        ]
        if let usage = disk.usage { object["used"] = .string(usage) }
        return [.object(object)]
    }

    private func partitionJSON(_ partition: (name: String, sizeGiB: Int, usage: String), of disk: DemoDiskLayout.Disk) -> JSONValue {
        [
            "devpath": .string("/dev/\(partition.name)"), "parent": .string(disk.path), "type": "partition",
            "size": .int(partition.sizeGiB == 0 ? 8_388_608 : Int(Double(partition.sizeGiB) * Self.gib)), "used": .string(partition.usage),
            "gpt": .int(disk.hasGPT ? 1 : 0), "mounted": .int(partition.usage == "EFI" || partition.usage == "ext4" || partition.usage == "xfs" ? 1 : 0),
            "health": "UNKNOWN", "wearout": "N/A", "osdid": -1,
        ]
    }

    private func smartJSON(_ disk: DemoDiskLayout.Disk) -> JSONValue {
        guard disk.type != "nvme" else {
            return [
                "health": "PASSED", "type": "text",
                "text": """
                SMART/Health Information (NVMe Log 0x02)
                Critical Warning:                   0x00
                Temperature:                        41 Celsius
                Available Spare:                    100%
                Available Spare Threshold:          10%
                Percentage Used:                    3%
                Data Units Read:                    48,211,923 [24.6 TB]
                Data Units Written:                 39,104,511 [20.0 TB]
                Power Cycles:                       112
                Power On Hours:                     9,874
                Unsafe Shutdowns:                   21
                Media and Data Integrity Errors:    0
                Error Information Log Entries:      0
                """,
            ]
        }
        let hours = disk.type == "hdd" ? "31544" : "9874"
        let attributes: [(Int, String, String, String, String, String)] = [
            (1, "Raw_Read_Error_Rate", "100", "100", "016", "0"),
            (5, "Reallocated_Sector_Ct", "100", "100", "005", "0"),
            (9, "Power_On_Hours", "096", "096", "000", hours),
            (12, "Power_Cycle_Count", "100", "100", "000", "112"),
            (194, "Temperature_Celsius", "171", "153", "000", "35 (Min/Max 18/47)"),
            (197, "Current_Pending_Sector", "100", "100", "000", "0"),
            (199, "UDMA_CRC_Error_Count", "200", "200", "000", "0"),
        ]
        return [
            "health": "PASSED", "type": "ata",
            "attributes": .array(attributes.map { id, name, value, worst, threshold, raw in
                [
                    "id": .string(String(format: "%3d", id)), "name": .string(name), "value": .string(value), "worst": .string(worst),
                    "threshold": .string(threshold), "raw": .string(raw), "fail": "-", "flags": "PO-R--", "normalized": .int(Int(value) ?? 0),
                ]
            }),
        ]
    }

    private func zfsStatusJSON(_ pool: DemoDiskLayout.Pool) -> JSONValue {
        func leaf(_ device: String) -> JSONValue {
            ["name": .string("/dev/disk/by-id/ata-\(device.replacingOccurrences(of: "/dev/", with: ""))-part1"), "state": "ONLINE", "read": 0, "write": 0, "cksum": 0, "msg": "", "leaf": 1]
        }
        let vdevs: [JSONValue]
        switch pool.raidLevel {
        case "single":
            vdevs = pool.devices.map(leaf)
        case "raid10":
            vdevs = stride(from: 0, to: pool.devices.count, by: 2).map { start in
                ["name": .string("mirror-\(start / 2)"), "state": "ONLINE", "read": 0, "write": 0, "cksum": 0, "msg": "",
                 "children": .array(pool.devices[start..<min(start + 2, pool.devices.count)].map(leaf))]
            }
        default:
            let name = pool.raidLevel == "raidz" ? "raidz1" : pool.raidLevel
            vdevs = [["name": .string("\(name)-0"), "state": "ONLINE", "read": 0, "write": 0, "cksum": 0, "msg": "", "children": .array(pool.devices.map(leaf))]]
        }
        return [
            "name": .string(pool.name), "state": "ONLINE", "errors": "No known data errors",
            "scan": "scrub repaired 0B in 05:12:44 with 0 errors on Sun Oct 11 05:36:45 2026",
            "children": [["name": .string(pool.name), "state": "ONLINE", "read": 0, "write": 0, "cksum": 0, "msg": "", "children": .array(vdevs)]],
        ]
    }
}
