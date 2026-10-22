import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

/// Guest imports, pruning, OCI images and downloads, with responses recorded from Proxmox VE 9.2.
struct StorageImportTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func ovaImportAsRecorded() throws {
        let metadata = try decode(ImportMetadata.self, #"""
        {"warnings": [{"type": "ova-needs-extracting"}], "source": "import/proxfleet-cirros.ova",
         "disks": {"scsi0": {"volid": "local:import/proxfleet-cirros.ova/cirros-disk1.qcow2"}},
         "create-args": {"boot": "order=scsi0", "name": "proxfleet-cirros", "ostype": "l26", "memory": "256", "cores": "1"},
         "type": "vm", "net": {"net0": {"model": "vmxnet3"}}}
        """#)
        #expect(metadata.disks == [ImportMetadata.Disk(id: "scsi0", volume: "local:import/proxfleet-cirros.ova/cirros-disk1.qcow2", size: nil)])
        var draft = GuestImportDraft(metadata: metadata, node: "pve", volume: "local:import/proxfleet-cirros.ova")
        #expect(draft.name == "proxfleet-cirros" && draft.memoryMiB == 256 && draft.cores == 1 && draft.needsExtracting)
        // Linux gets no driver drive.
        #expect(draft.visibleCDROMs.isEmpty)
        #expect(draft.problems.keys.sorted() == ["bridge", "storage", "vmid"])
        draft.vmid = 130
        draft.defaultStorage = "local-lvm"
        draft.defaultBridge = "vmbr0"
        draft.workingStorage = "scratch"
        draft.liveImport = true
        #expect(draft.problems.isEmpty)
        #expect(PVE.importGuest(draft).parameters.formEncoded == [
            "vmid=130", "boot=order%3Dscsi0", "cores=1", "cpu=x86-64-v2-AES", "import-working-storage=scratch", "live-restore=1", "memory=256",
            "name=proxfleet-cirros", "net0=model%3Dvmxnet3%2Cbridge%3Dvmbr0", "ostype=l26",
            "scsi0=local-lvm%3A0%2Cimport-from%3Dlocal%3Aimport%2Fproxfleet-cirros.ova%2Fcirros-disk1.qcow2", "sockets=1",
        ].joined(separator: "&"))
        #expect(PVE.importMetadata(node: "pve", volume: "local:import/proxfleet-cirros.ova").parameters["volume"] == "import/proxfleet-cirros.ova")
    }

    @Test func windowsESXiImportPreparesVirtIOSCSI() throws {
        let metadata = try decode(ImportMetadata.self, #"""
        {"type": "vm", "source": "esxi",
         "create-args": {"name": "win", "ostype": "win11", "bios": "ovmf", "machine": "q35", "boot": "order=scsi0;ide0;net0", "ide0": "none,media=cdrom", "scsihw": "pvscsi"},
         "disks": {"scsi0": {"volid": "esx:ha-datacenter/ds/win/win.vmdk", "size": 64424509440}, "scsi1": "esx:ha-datacenter/ds/win/win_1.vmdk", "efidisk0": "esx:ha-datacenter/ds/win/win.nvram"},
         "net": {"net0": {"model": "e1000e", "macaddr": "00:50:56:9A:1B:2C"}},
         "warnings": [{"type": "cdrom-image-ignored", "key": "ide0", "value": "[ds] iso/x.iso"}, {"type": "mystery", "message": "Something odd"}]}
        """#)
        #expect(metadata.warnings.map(\.text).last == "Something odd")
        var draft = GuestImportDraft(metadata: metadata, node: "pve", volume: "esx:ha-datacenter/ds/win/win.vmx")
        #expect(draft.isWindows && draft.prepareForVirtIOSCSI && draft.scsiController == "virtio-scsi-single")
        #expect(draft.cdroms.map(\.id) == ["ide0"])
        // SCSI disks move behind the SATA slots in use, which are none here.
        #expect(draft.diskSlots == ["scsi0": "sata0", "scsi1": "sata1"])
        draft.vmid = 131
        draft.defaultStorage = "local-lvm"
        draft.defaultFormat = nil
        draft.defaultBridge = "vmbr0"
        draft.disks[2].isEnabled = false
        draft.uniqueMACAddresses = true
        let parameters = draft.parameters
        #expect(parameters["efidisk0"] == "local-lvm:0,efitype=4m")
        #expect(parameters["sata0"] == "local-lvm:0,import-from=esx:ha-datacenter/ds/win/win.vmdk")
        #expect(parameters["sata1"] == nil && parameters["scsi1"] == nil)
        #expect(parameters["scsi0"] == nil)
        #expect(parameters["boot"] == "order=sata0;ide0;net0")
        #expect(parameters["net0"] == "model=e1000e,bridge=vmbr0")
        #expect(parameters["ide0"] == "none,media=cdrom")
        #expect(parameters["machine"] == "q35" && parameters["bios"] == "ovmf")

        draft.prepareForVirtIOSCSI = false
        draft.uniqueMACAddresses = false
        #expect(draft.parameters["scsi0"] == "local-lvm:0,import-from=esx:ha-datacenter/ds/win/win.vmdk")
        #expect(draft.parameters["net0"] == "e1000e=00:50:56:9A:1B:2C,bridge=vmbr0")
    }

    @Test func linuxWithoutCDDrivesGetsADriverSlotOnlyForWindows() throws {
        let metadata = ImportMetadata(createArguments: ["ostype": "l26"], disks: [.init(id: "sata0", volume: "x", size: nil)], networks: [], warnings: [])
        var draft = GuestImportDraft(metadata: metadata, node: "pve", volume: "local:import/a.ova")
        #expect(draft.cdroms.map(\.id) == ["ide0"] && draft.visibleCDROMs.isEmpty)
        draft.osType = "win10"
        #expect(draft.visibleCDROMs.map(\.id) == ["ide0"])
    }

    @Test func pruneKeepReasons() throws {
        let candidates = try decode([PruneCandidate].self, #"""
        [{"volid": "a", "ctime": 400, "mark": "keep"}, {"volid": "b", "ctime": 300, "mark": "keep"},
         {"volid": "c", "ctime": 200, "mark": "protected"}, {"volid": "d", "ctime": 100, "mark": "keep"}, {"volid": "e", "ctime": 50, "mark": "remove"}]
        """#)
        var options = PruneOptions()
        options.counts = ["keep-last": "2", "keep-daily": "3"]
        let explained = PruneCandidate.withKeepReasons(candidates, options: options)
        #expect(explained.map(\.keepReason) == ["keep-last: 1", "keep-last: 2", "protected", "keep-daily: 1", nil])
        #expect(explained.filter { !$0.isKept }.map(\.id) == ["e"])
        #expect(PruneCandidate.withKeepReasons(candidates, options: PruneOptions()).first?.keepReason == "keep-all")
        let request = PVE.pruneBackups(node: "pve", storage: "local", kind: .virtualMachine, vmid: 100, options: options)
        #expect(request.method == .delete && request.parameters.formEncoded == "type=qemu&vmid=100&prune-backups=keep-last%3D2%2Ckeep-daily%3D3")
        #expect(PVE.prunePreview(node: "pve", storage: "local", kind: .container, vmid: 200, options: nil).parameters.formEncoded == "type=lxc&vmid=200")
    }

    @Test func ociPullAndDownloadNames() {
        var oci = OCIPullDraft()
        oci.reference = "docker.io/library/alpine:3.22"
        oci.takeTagFromReference()
        #expect(oci.reference == "docker.io/library/alpine" && oci.tag == "3.22")
        oci.fileName = "alpine"
        #expect(oci.problems.isEmpty)
        #expect(PVE.pullOCIImage(node: "pve", storage: "local", oci).parameters.formEncoded == "reference=docker.io%2Flibrary%2Falpine%3A3.22&filename=alpine")
        var port = OCIPullDraft()
        port.reference = "registry:5000/team/app"
        port.takeTagFromReference()
        #expect(port.reference == "registry:5000/team/app" && port.tag == "latest")
        port.reference = "Team/App"
        #expect(port.problems.keys.sorted() == ["reference"])

        var iso = StorageFileDraft(content: .iso)
        iso.url = "https://example.com/os.iso.zst"
        iso.applyQueriedName("os.iso.zst")
        #expect(iso.fileName == "os.iso" && iso.decompression == "zst")
        #expect(PVE.downloadURL(node: "pve", storage: "local", iso).parameters["compression"] == "zst")
        var image = StorageFileDraft(content: .import)
        image.applyQueriedName("cloud.img")
        #expect(image.fileName == "cloud.img.raw" && image.decompression.isEmpty)
    }

    @Test func storageHistory() throws {
        let points = try decode([RRDPoint].self, #"[{"total": 43888205824, "time": 1792654620, "used": 6353760256}, {"time": 1792654680}]"#)
        #expect(points[0].storageUsed == 6_353_760_256 && points[0].storageTotal == 43_888_205_824 && points[1].storageUsed == nil)
        #expect(PVE.storageRRD(node: "pve", storage: "local", timeframe: .day).path == "/nodes/pve/storage/local/rrddata")
    }
}
