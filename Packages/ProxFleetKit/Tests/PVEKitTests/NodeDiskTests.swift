import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

/// Disks and the storage built on them. Disk, LVM and thin pool responses are recorded from Proxmox VE 9.2.
struct NodeDiskTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func disksAndPartitions() throws {
        let disks = try decode([NodeDisk].self, #"""
        [{"used": "BIOS boot", "health": "OK", "by_id_link": "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0", "osdid-list": null,
          "vendor": "QEMU    ", "devpath": "/dev/sda", "serial": "drive-scsi0", "gpt": 1, "type": "ssd", "model": "QEMU_HARDDISK",
          "rpm": 0, "osdid": -1, "wwn": "unknown", "wearout": "N/A", "size": 137438953472},
         {"devpath": "/dev/sda3", "parent": "/dev/sda", "used": "LVM", "size": 136362065408, "type": "partition", "gpt": 1, "mounted": 0},
         {"devpath": "/dev/sda1", "parent": "/dev/sda", "used": "BIOS boot", "size": 1031168, "type": "partition", "gpt": 1},
         {"devpath": "/dev/sdb", "size": 4000787030016, "type": "hdd", "rpm": 5400, "wearout": 97, "health": "FAILED", "gpt": 0}]
        """#)
        let sda = disks[0]
        #expect(sda.vendor == "QEMU" && sda.wwn == nil && sda.wearout == nil && sda.rpm == nil)
        #expect(sda.usage == "BIOS boot" && sda.hasGPT && !sda.isPartition && !sda.isFailing)
        let sdb = disks[3]
        #expect(sdb.isUnused && sdb.wearout == 97 && sdb.rpm == 5400 && sdb.isFailing)

        let grouped = NodeDisk.grouped(disks)
        #expect(grouped.map(\.disk.name) == ["sda", "sdb"])
        #expect(grouped[0].partitions.map(\.name) == ["sda1", "sda3"])
        #expect(grouped[0].partitions[1].type == "partition")
    }

    @Test func smartReports() throws {
        let text = try decode(SMARTReport.self, #"{"type": "text", "health": "OK", "text": "Current Drive Temperature:     0 C\n\n"}"#)
        #expect(text.health == "OK" && text.attributes.isEmpty && text.text == "Current Drive Temperature:     0 C")

        let ata = try decode(SMARTReport.self, #"""
        {"health": "PASSED", "type": "ata", "attributes": [
          {"id": "  5", "name": "Reallocated_Sector_Ct", "value": "100", "worst": "100", "threshold": "005", "raw": "0", "fail": "-", "flags": "PO--CK", "normalized": 100},
          {"id": "197", "name": "Current_Pending_Sector", "value": 1, "worst": 1, "threshold": 0, "raw": "8", "fail": "FAILING_NOW"}]}
        """#)
        #expect(ata.text == nil)
        #expect(ata.attributes.map(\.id) == [5, 197])
        #expect(ata.attributes[0].name == "Reallocated Sector Ct" && !ata.attributes[0].isFailing)
        #expect(ata.attributes[1].value == "1" && ata.attributes[1].isFailing)
    }

    @Test func lvmAndThinPools() throws {
        let groups = try decode(LVMVolumeGroups.self, #"""
        {"children": [{"leaf": 0, "lvcount": 11, "size": 136361017344, "name": "pve",
          "children": [{"name": "/dev/sda3", "free": 16915628032, "size": 136361017344, "leaf": 1}], "free": 16915628032}], "leaf": 0}
        """#).groups
        #expect(groups.count == 1)
        #expect(groups[0].name == "pve" && groups[0].volumeCount == 11 && groups[0].free == 16_915_628_032)
        #expect(groups[0].physicalVolumes.map(\.name) == ["/dev/sda3"])

        let pools = try decode([LVMThinPool].self, #"""
        [{"metadata_used": 17179869, "lv_size": 64135102464, "metadata_size": 1073741824, "vg": "pve", "lv_type": "t", "lv_state": "a",
          "ctime": "1792535161", "lv": "data", "used": 173164776}]
        """#)
        #expect(pools[0].id == "pve/data" && pools[0].used == 173_164_776 && pools[0].metadataSize == 1_073_741_824)
    }

    @Test func zfsPoolAndStatusTree() throws {
        let pool = try decode(ZFSPool.self, #"{"name": "tank", "size": 7988639170560, "alloc": 2372938792960, "free": 5615700377600, "frag": 3, "dedup": 1, "health": "ONLINE"}"#)
        #expect(pool.isHealthy && pool.fragmentation == 3 && pool.dedupRatio == 1)

        let status = try decode(ZFSPoolStatus.self, #"""
        {"name": "tank", "state": "DEGRADED", "status": "One or more devices could not be used.", "action": "Attach the missing device.",
         "scan": "scrub repaired 0B", "errors": "No known data errors\n",
         "children": [{"name": "tank", "state": "DEGRADED", "read": 0, "write": 0, "cksum": 0, "msg": "",
           "children": [{"name": "mirror-0", "state": "DEGRADED", "read": 0, "write": 0, "cksum": 0, "msg": "",
             "children": [{"name": "sda1", "state": "ONLINE", "read": 0, "write": 0, "cksum": 0, "msg": "", "leaf": 1},
                          {"name": "sdb1", "state": "UNAVAIL", "read": 3, "write": 0, "cksum": 0, "msg": "cannot open", "leaf": 1}]}]},
           {"name": "logs", "msg": ""}]}
        """#)
        #expect(status.state == "DEGRADED" && status.errors == "No known data errors")
        let rows = status.devices.flatMap { $0.flattened() }
        #expect(rows.map(\.device.name) == ["tank", "mirror-0", "sda1", "sdb1", "logs"])
        #expect(rows.map(\.depth) == [0, 1, 2, 2, 0])
        #expect(rows[3].device.hasErrors && rows[3].device.message == "cannot open")
        #expect(rows[4].device.state == nil)
    }

    @Test func directoryMounts() throws {
        let mounts = try decode([DirectoryMount].self, #"[{"path": "/mnt/pve/backup", "device": "/dev/sdc1", "type": "ext4", "options": "defaults", "unitfile": "/etc/systemd/system/mnt-pve-backup.mount"}]"#)
        #expect(mounts[0].name == "backup" && mounts[0].fileSystem == "ext4")
    }

    @Test func creatingStorage() {
        var zfs = DiskStorageDraft(kind: .zfs)
        #expect(zfs.problems.keys.sorted() == ["devices", "name"])
        zfs.name = "tank"
        zfs.raidLevel = "raidz"
        zfs.devices = ["/dev/sdb", "/dev/sdc"]
        #expect(zfs.problems["devices"] == "raidz needs at least 3 disks.")
        zfs.devices.append("/dev/sdd")
        #expect(zfs.problems.isEmpty)
        #expect(PVE.createDiskStorage(node: "pve", zfs).path == "/nodes/pve/disks/zfs")
        #expect(PVE.createDiskStorage(node: "pve", zfs).parameters.formEncoded
            == "name=tank&devices=%2Fdev%2Fsdb%2C%2Fdev%2Fsdc%2C%2Fdev%2Fsdd&raidlevel=raidz&compression=on&ashift=12&add_storage=1")
        zfs.raidLevel = "raid10"
        zfs.devices.append("/dev/sde")
        zfs.devices.append("/dev/sdf")
        #expect(zfs.problems["devices"] == "raid10 needs an even number of disks.")

        var directory = DiskStorageDraft(kind: .directory)
        directory.name = "9backup"
        directory.devices = ["/dev/sdc"]
        #expect(directory.problems.keys.sorted() == ["name"])
        directory.name = "backup"
        directory.fileSystem = "xfs"
        directory.addStorage = false
        #expect(PVE.createDiskStorage(node: "pve", directory).parameters.formEncoded == "name=backup&device=%2Fdev%2Fsdc&filesystem=xfs&add_storage=0")

        let thin = PVE.deleteDiskStorage(node: "pve", kind: .lvmThin, name: "fast", volumeGroup: "fast", cleanupConfig: true, wipeDisks: false)
        #expect(thin.method == .delete && thin.path == "/nodes/pve/disks/lvmthin/fast")
        #expect(thin.parameters.formEncoded == "cleanup-config=1&cleanup-disks=0&volume-group=fast")
    }
}
