import ProxmoxCore
@testable import PVEKit
import Testing

struct ConfigEditingTests {
    @Test func propertyStringRoundTripAndEdit() {
        var property = PropertyString(parsing: #"local-lvm:vm-100-disk-0,size=4G,ip="a,b""#)
        #expect(property.stringValue == #"local-lvm:vm-100-disk-0,size=4G,ip="a,b""#)
        property["size"] = "8G"
        property["discard"] = "on"
        property["ip"] = nil
        #expect(property.stringValue == "local-lvm:vm-100-disk-0,size=8G,discard=on")
    }

    @Test func updateParameters() {
        var update = GuestConfigUpdate(digest: "abc")
        update.set("memory", "2048")
        update.set("onboot", true)
        update.set("description", nil)
        update.reverts = ["cores"]
        #expect(update.parameters.formEncoded == "memory=2048&onboot=1&delete=description&revert=cores&digest=abc")
        update.set("description", "back")
        #expect(!update.deletions.contains("description"))
    }

    @Test func networkDraftKeepsUnknownOptions() {
        let nic = GuestNIC(key: "net0", value: "virtio=BC:24:11:B1:83:AD,bridge=vmbr0,firewall=1,queues=4")
        var draft = NetworkDeviceDraft(nic)
        #expect(draft.model == "virtio")
        #expect(draft.macAddress == "BC:24:11:B1:83:AD")
        #expect(draft.stringValue == "virtio=BC:24:11:B1:83:AD,bridge=vmbr0,firewall=1,queues=4")
        draft.vlanTag = 20
        draft.firewall = false
        draft.model = "e1000"
        #expect(draft.stringValue == "e1000=BC:24:11:B1:83:AD,bridge=vmbr0,tag=20,firewall=0,queues=4")

        var fresh = NetworkDeviceDraft()
        fresh.bridge = "vmbr1"
        #expect(fresh.stringValue == "model=virtio,bridge=vmbr1,firewall=1")
    }

    @Test func diskDraftKeepsVolumeAndSize() {
        let disk = GuestDisk(key: "scsi0", value: "local-lvm:vm-100-disk-0,iothread=1,size=32G")
        var draft = DiskOptionsDraft(disk)
        #expect(draft.ioThread)
        draft.discard = true
        draft.cache = "writeback"
        draft.includeInBackup = false
        #expect(draft.stringValue == "local-lvm:vm-100-disk-0,iothread=1,size=32G,cache=writeback,discard=on,backup=0")
    }

    @Test func freeKeysAndNewValues() {
        let config = GuestConfig(values: ["scsi0": "x", "scsi1": "y", "net0": "z"])
        #expect(config.nextFreeKey(prefix: "scsi", slots: 31) == "scsi2")
        #expect(config.nextFreeKey(prefix: "net", slots: 32) == "net1")
        #expect(GuestConfig.newDiskValue(storage: "local-lvm", sizeGiB: 32, discard: true, ioThread: true, ssdEmulation: false) == "local-lvm:32,discard=on,iothread=1")
        #expect(GuestConfig.cdromValue(isoVolume: nil) == "none,media=cdrom")
    }
}
