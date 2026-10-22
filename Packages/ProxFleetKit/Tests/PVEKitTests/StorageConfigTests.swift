import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

/// Storage definitions, with responses recorded from Proxmox VE 9.2.
struct StorageConfigTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func configs() throws {
        let configs = try decode([StorageConfig].self, #"""
        [{"thinpool": "data", "storage": "local-lvm", "vgname": "pve", "content": "rootdir,images", "type": "lvmthin", "digest": "e262bd0e"},
         {"type": "dir", "digest": "e262bd0e", "storage": "local", "content": "vztmpl,iso,backup,import", "path": "/var/lib/vz"},
         {"storage": "pfprobe", "type": "dir", "disable": 1, "content": "vztmpl,iso", "path": "/var/lib/pfprobe", "nodes": "pve1,pve2",
          "prune-backups": "keep-last=3,keep-daily=7"},
         {"storage": "nas", "type": "nfs", "server": "10.0.10.5", "export": "/mnt/tank", "content": "backup"},
         {"storage": "san", "type": "iscsidirect", "portal": "10.0.0.9", "target": "iqn.x", "content": "images"}]
        """#)
        #expect(configs[0].location == "pve/data" && configs[0].content == ["rootdir", "images"] && configs[0].digest == "e262bd0e")
        #expect(configs[1].location == "/var/lib/vz" && !configs[1].isShared)
        #expect(configs[2].isDisabled && configs[2].nodes == ["pve1", "pve2"])
        #expect(configs[3].isShared && configs[3].location == "10.0.10.5:/mnt/tank")
        #expect(StorageConfigDraft(configs[4]) == nil && configs[4].location == "10.0.0.9 · iqn.x")

        let draft = try #require(StorageConfigDraft(configs[2]))
        #expect(!draft.isEnabled && draft.nodes == ["pve1", "pve2"] && draft.path == "/var/lib/pfprobe")
        #expect(draft.prune.counts == ["keep-last": "3", "keep-daily": "7"] && draft.prune.serialized == "keep-last=3,keep-daily=7")
    }

    @Test func pruneOptions() {
        var prune = PruneOptions()
        #expect(prune.serialized == nil)
        prune.counts = ["keep-weekly": "4", "keep-last": " 2 ", "keep-daily": ""]
        #expect(prune.serialized == "keep-last=2,keep-weekly=4")
        prune.counts["keep-yearly"] = "0"
        #expect(prune.problems.keys.sorted() == ["prune-backups"])
        prune.keepAll = true
        #expect(prune.serialized == "keep-all=1")
        #expect(PruneOptions("keep-all=1").keepAll)
    }

    @Test func creation() {
        var nfs = StorageConfigDraft(type: .nfs)
        #expect(nfs.problems(isNew: true).keys.sorted() == ["export", "server", "storage"])
        nfs.storage = "nas"
        nfs.server = "10.0.10.5"
        nfs.export = "/mnt/tank"
        nfs.content = ["iso", "backup"]
        nfs.mountOptions = "vers=4.2"
        nfs.prune.counts = ["keep-daily": "7"]
        #expect(nfs.problems(isNew: true).isEmpty)
        #expect(PVE.createStorage(nfs).parameters.formEncoded
            == "storage=nas&type=nfs&content=iso%2Cbackup&export=%2Fmnt%2Ftank&options=vers%3D4.2&prune-backups=keep-daily%3D7&server=10.0.10.5")

        var pbs = StorageConfigDraft(type: .pbs)
        pbs.storage = "pbs"
        pbs.server = "pbs.lan"
        pbs.datastore = "main"
        pbs.username = "backup@pbs"
        pbs.fingerprint = "AB:CD"
        #expect(pbs.problems(isNew: true).keys.sorted() == ["fingerprint", "password"])
        pbs.password = "secret"
        pbs.fingerprint = ""
        #expect(pbs.problems(isNew: true).isEmpty)
        #expect(PVE.createStorage(pbs).parameters.formEncoded
            == "storage=pbs&type=pbs&content=backup&datastore=main&server=pbs.lan&username=backup%40pbs&password=secret")

        var dir = StorageConfigDraft(type: .dir)
        dir.storage = "9bad"
        dir.path = "relative"
        dir.content = []
        #expect(dir.problems(isNew: true).keys.sorted() == ["content", "path", "storage"])
    }

    @Test func updatesSkipFixedSettingsAndDeleteClearedOnes() throws {
        let config = try decode(StorageConfig.self, #"{"storage": "nas", "type": "nfs", "server": "10.0.10.5", "export": "/mnt/tank", "content": "iso,backup", "prune-backups": "keep-daily=7", "options": "vers=4.2", "nodes": "pve1"}"#)
        let original = try #require(StorageConfigDraft(config))
        #expect(original.changes(from: original).isEmpty)

        var draft = original
        draft.server = "10.0.10.99"
        draft.content = ["iso"]
        draft.nodes = []
        draft.isEnabled = false
        #expect(original.nfsVersion == "4.2" && original.mountOptions.isEmpty)
        draft.nfsVersion = ""
        let update = draft.changes(from: original)
        // Without backups, retention is cleared too; the server address cannot change after creation.
        #expect(update.values == ["content": "iso", "disable": "1"])
        #expect(update.deletions == ["nodes", "options", "prune-backups"])

        draft = original
        draft.password = "new"
        #expect(draft.changes(from: original).values == ["password": "new"])
    }

    @Test func scanResults() throws {
        let results = try decode([StorageScanResult].self, #"""
        [{"path": "/mnt/tank/proxmox", "options": "10.0.10.0/24"}, {"share": "backups", "description": "Backup share"},
         {"store": "main", "comment": ""}, {"size": 136361017344, "lvcount": 11, "vg": "pve", "free": 16915628032},
         {"lv": "data", "vg": "pve", "lv_size": 64135102464}]
        """#)
        #expect(results.map(\.name) == ["/mnt/tank/proxmox", "backups", "main", "pve", "data"])
        #expect(results[0].detail == "10.0.10.0/24" && results[1].detail == "Backup share" && results[2].detail == nil)
        #expect(results[3].detail != nil)
    }

    @Test func iscsiLVMAndFileOptions() {
        var iscsi = StorageConfigDraft(type: .iscsi)
        iscsi.storage = "san"
        #expect(iscsi.problems(isNew: true).keys.sorted() == ["portal", "target"])
        iscsi.portal = "10.0.0.9"
        iscsi.target = "iqn.2003-01.org.linux-iscsi.san:sn.1"
        iscsi.usesLUNsDirectly = false
        #expect(iscsi.problems(isNew: true).isEmpty)
        #expect(PVE.createStorage(iscsi).parameters.formEncoded == "storage=san&type=iscsi&content=none&portal=10.0.0.9&target=iqn.2003-01.org.linux-iscsi.san%3Asn.1")

        var lvm = StorageConfigDraft(type: .lvm)
        lvm.storage = "san-lvm"
        lvm.baseVolume = "san:0.0.1.scsi-36001405"
        lvm.volumeGroup = "vg-san"
        lvm.isShared = true
        lvm.wipesRemovedVolumes = true
        lvm.volumeChainSnapshots = true
        #expect(PVE.createStorage(lvm).parameters.formEncoded
            == "storage=san-lvm&type=lvm&base=san%3A0.0.1.scsi-36001405&content=images%2Crootdir&saferemove=1&shared=1&snapshot-as-volume-chain=1&vgname=vg-san")

        var dir = StorageConfigDraft(type: .dir)
        dir.storage = "files"
        dir.path = "/mnt/files"
        dir.preallocation = "full"
        dir.volumeChainSnapshots = true
        #expect(PVE.createStorage(dir).parameters["preallocation"] == "full")
        #expect(PVE.createStorage(dir).parameters["snapshot-as-volume-chain"] == "1")
        // Volume chains can only be turned on when adding, except on LVM.
        var editedDir = dir
        editedDir.volumeChainSnapshots = false
        editedDir.preallocation = ""
        #expect(editedDir.changes(from: dir).deletions == ["preallocation"])
        var editedLVM = lvm
        editedLVM.volumeChainSnapshots = false
        editedLVM.wipesRemovedVolumes = false
        #expect(editedLVM.changes(from: lvm).deletions.sorted() == ["saferemove", "snapshot-as-volume-chain"])

        var nfs = StorageConfigDraft(type: .nfs)
        nfs.mountOptions = "soft, vers=3"
        #expect(nfs.serialized()["options"] == "soft,vers=3")
        nfs.nfsVersion = "4.2"
        #expect(nfs.serialized()["options"] == "soft,vers=4.2")
    }

    @Test func cephZFSOverISCSIAndESXi() throws {
        var rbd = StorageConfigDraft(type: .rbd)
        rbd.storage = "ceph-vms"
        rbd.pool = "vms"
        #expect(rbd.username == "admin" && rbd.content == ["images"])
        #expect(PVE.createStorage(rbd).parameters.formEncoded == "storage=ceph-vms&type=rbd&content=images&pool=vms")
        rbd.usesClusterCeph = false
        #expect(rbd.problems(isNew: true).keys.sorted() == ["keyring", "monhost"])
        rbd.monitors = "10.0.0.1 10.0.0.2"
        rbd.keyring = "[client.admin]\n\tkey = AQB=="
        rbd.usesKRBD = true
        #expect(rbd.problems(isNew: true).isEmpty)
        #expect(PVE.createStorage(rbd).parameters.formEncoded
            == "storage=ceph-vms&type=rbd&content=images&krbd=1&monhost=10.0.0.1%2010.0.0.2&pool=vms&username=admin&keyring=%5Bclient.admin%5D%0A%09key%20%3D%20AQB%3D%3D")

        let config = try JSONDecoder().decode(StorageConfig.self, from: Data(#"{"storage": "ext", "type": "cephfs", "monhost": "10.0.0.1", "username": "admin", "content": "backup,iso", "fs-name": "cephfs"}"#.utf8))
        let cephfs = try #require(StorageConfigDraft(config))
        #expect(!cephfs.usesClusterCeph && cephfs.fsName == "cephfs")
        var edited = cephfs
        edited.monitors = "10.0.0.5"
        edited.keyring = "AQB=="
        edited.username = "other"
        // The user and the file system are fixed; a new secret is sent.
        #expect(edited.changes(from: cephfs).values == ["monhost": "10.0.0.5", "keyring": "AQB=="])

        var zfs = StorageConfigDraft(type: .zfs)
        zfs.storage = "zfs-san"
        zfs.portal = "10.0.0.9"
        zfs.pool = "tank/pve"
        zfs.target = "iqn.2003-01.org.linux-iscsi.san:pve"
        zfs.iscsiProvider = .lio
        zfs.lioTargetPortalGroup = "tpg1"
        zfs.writeCache = false
        zfs.comstarHostGroup = "ignored"
        #expect(zfs.problems(isNew: true).isEmpty)
        #expect(PVE.createStorage(zfs).parameters.formEncoded
            == "storage=zfs-san&type=zfs&blocksize=4k&content=images&iscsiprovider=LIO&lio_tpg=tpg1&pool=tank%2Fpve&portal=10.0.0.9&target=iqn.2003-01.org.linux-iscsi.san%3Apve")
        zfs.iscsiProvider = .comstar
        #expect(zfs.serialized()["nowritecache"] == "1" && zfs.serialized()["comstar_hg"] == "ignored")

        var esxi = StorageConfigDraft(type: .esxi)
        esxi.storage = "esx"
        esxi.server = "esxi.lan"
        #expect(esxi.problems(isNew: true).keys.sorted() == ["password", "username"])
        esxi.username = "root"
        esxi.password = "secret"
        esxi.skipsCertificateVerification = true
        #expect(PVE.createStorage(esxi).parameters.formEncoded
            == "storage=esx&type=esxi&content=import&server=esxi.lan&skip-cert-verification=1&username=root&password=secret")
    }

    @Test func pbsEncryption() throws {
        var pbs = StorageConfigDraft(type: .pbs)
        pbs.storage = "pbs"
        pbs.server = "pbs.lan"
        pbs.datastore = "main"
        pbs.username = "backup@pbs"
        pbs.password = "secret"
        #expect(pbs.encryptionMode == .none && PVE.createStorage(pbs).parameters["encryption-key"] == nil)
        pbs.encryptionMode = .autogenerate
        #expect(PVE.createStorage(pbs).parameters["encryption-key"] == "autogen")
        pbs.encryptionMode = .upload
        pbs.encryptionKey = "not json"
        #expect(pbs.problems(isNew: true).keys.sorted() == ["encryption-key"])
        pbs.encryptionKey = #"{"kdf": null, "data": "abc"}"#
        #expect(pbs.problems(isNew: true).isEmpty)

        let config = try JSONDecoder().decode(StorageConfig.self, from: Data(#"{"storage": "pbs", "type": "pbs", "server": "pbs.lan", "datastore": "main", "username": "backup@pbs", "content": "backup", "encryption-key": "4f:2a:11"}"#.utf8))
        let existing = try #require(StorageConfigDraft(config))
        #expect(existing.hasEncryptionKey && existing.encryptionMode == .keep)
        #expect(existing.changes(from: existing).isEmpty)
        var removal = existing
        removal.encryptionMode = .none
        #expect(removal.changes(from: existing).deletions == ["encryption-key"])

        let result = try JSONDecoder().decode(StorageChangeResult.self, from: Data(#"{"storage": "pbs", "type": "pbs", "config": {"encryption-key": "{\"kdf\":null}"}}"#.utf8))
        #expect(result.encryptionKey == #"{"kdf":null}"#)
    }
}
