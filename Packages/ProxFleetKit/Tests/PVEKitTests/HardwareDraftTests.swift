import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct HardwareDraftTests {
    @Test func cpuKeepsUnknownOptionsAndOrdersFlags() {
        let config = GuestConfig(values: ["cores": "4", "cpu": "host,flags=-pcid;+aes,hidden=1", "cpuunits": "200"])
        let original = CPUDraft(config, isVM: true)
        #expect(original.model == "host")
        #expect(original.flags == ["pcid": false, "aes": true])
        #expect(original.changes(from: original).isEmpty)
        var draft = original
        draft.flags["md-clear"] = true
        draft.limit = 1.5
        draft.vcpus = 2
        let update = draft.changes(from: original)
        #expect(update.values == ["cpu": "host,flags=+md-clear;-pcid;+aes,hidden=1", "cpulimit": "1.5", "vcpus": "2"])
    }

    @Test func cpuDefaultsAreDeleted() {
        let original = CPUDraft(GuestConfig(values: ["sockets": "2", "cpu": "x86-64-v2-AES", "cpulimit": "2"]), isVM: true)
        var draft = original
        draft.sockets = 1
        draft.model = ""
        draft.limit = 0
        #expect(Set(draft.changes(from: original).deletions) == ["sockets", "cpu", "cpulimit"])
    }

    @Test func containerCoresAreOptional() {
        let original = CPUDraft(GuestConfig(values: [:]), isVM: false)
        #expect(original.cores == 0)
        var draft = original
        draft.cores = 2
        #expect(draft.changes(from: original).values == ["cores": "2"])
    }

    @Test func machineVersionAndIOMMU() {
        let original = VMSystemDraft(GuestConfig(values: ["machine": "pc-q35-9.2+pve1", "vga": "virtio,memory=64"]))
        #expect(original.machineFamily == "q35")
        #expect(original.machineVersion == "9.2+pve1")
        #expect(original.display == "virtio")
        #expect(original.displayMemory == 64)
        var draft = original
        draft.viommu = "intel"
        draft.machineVersion = ""
        draft.clipboard = "vnc"
        let update = draft.changes(from: original)
        #expect(update.values == ["machine": "q35,viommu=intel", "vga": "virtio,memory=64,clipboard=vnc"])
    }

    @Test func defaultMachineAndDisplay() {
        let original = VMSystemDraft(GuestConfig(values: [:]))
        var draft = original
        draft.viommu = "virtio"
        draft.clipboard = "vnc"
        #expect(draft.changes(from: original).values == ["machine": "pc,viommu=virtio", "vga": "std,clipboard=vnc"])
        draft.viommu = ""
        draft.clipboard = ""
        #expect(draft.changes(from: original).isEmpty)
    }

    @Test func diskLimitsAndSerial() {
        let disk = GuestDisk(key: "scsi0", value: "local-lvm:vm-100-disk-0,iothread=1,size=32G")
        var draft = DiskOptionsDraft(disk)
        draft.limits["mbps_rd"] = "100,5"
        draft.serial = "DATA01"
        draft.asyncIO = "native"
        #expect(draft.stringValue == "local-lvm:vm-100-disk-0,iothread=1,size=32G,aio=native,serial=DATA01,mbps_rd=100.5")
    }

    @Test func networkQueuesAndTrunks() {
        var draft = NetworkDeviceDraft(GuestNIC(key: "net0", value: "virtio=BC:24:11:00:00:01,bridge=vmbr0,firewall=1"))
        draft.queues = 4
        draft.trunks = "10;20-30"
        #expect(draft.stringValue == "virtio=BC:24:11:00:00:01,bridge=vmbr0,firewall=1,queues=4,trunks=10;20-30")
    }
}
