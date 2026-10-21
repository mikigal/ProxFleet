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
         {"storage": "ceph", "type": "rbd", "pool": "vms", "content": "images"}]
        """#)
        #expect(configs[0].location == "pve/data" && configs[0].content == ["rootdir", "images"] && configs[0].digest == "e262bd0e")
        #expect(configs[1].location == "/var/lib/vz" && !configs[1].isShared)
        #expect(configs[2].isDisabled && configs[2].nodes == ["pve1", "pve2"])
        #expect(configs[3].isShared && configs[3].location == "10.0.10.5:/mnt/tank")
        #expect(StorageConfigDraft(configs[4]) == nil)

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
        draft.mountOptions = ""
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
}
