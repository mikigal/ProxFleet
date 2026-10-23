import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct CephTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func setupStateFromErrors() {
        #expect(CephSetupState.from(errorMessage: "binary not installed: /usr/bin/ceph-mon") == .notInstalled)
        #expect(CephSetupState.from(errorMessage: "pveceph configuration not initialized - missing '/etc/pve/ceph.conf', missing '/etc/pve/ceph'") == .notInitialized)
        #expect(CephSetupState.from(errorMessage: "rados_connect failed - No such file or directory") == .noMonitor)
        #expect(CephSetupState.from(errorMessage: "Permission check failed") == nil)
    }

    /// `GET /nodes/{node}/ceph/releases` on PVE 9.2.
    @Test func releasesAndInstallOptions() throws {
        let json = #"[{"available": 0, "is-default": 0, "release": "reef", "unsupported": 0, "version": "18.2"}, {"available": 1, "is-default": 0, "version": "19.2", "unsupported": 0, "release": "squid"}, {"available": 1, "is-default": 1, "unsupported": 0, "release": "tentacle", "version": "20.2"}]"#
        let releases = try decode([CephRelease].self, json)
        #expect(releases.filter(\.isAvailable).map(\.name) == ["squid", "tentacle"])
        #expect(releases.first(where: \.isDefault)?.version == "20.2")
        #expect(CephRelease.installOptions(release: "tentacle", repository: "no-subscription") == ["--version", "tentacle", "--repository", "no-subscription"])
    }

    /// The parts of `ceph status` of the test cluster on PVE 9.2 with Ceph 20.2, two OSDs and a degraded pool.
    @Test func decodesStatusAsRecorded() throws {
        let json = #"""
        {"health": {"checks": {"PG_DEGRADED": {"muted": false, "detail": [{"message": "pg 3.0 is active+undersized+degraded, acting [0,1]"}], "summary": {"count": 6, "message": "Degraded data redundancy: 22/66 objects degraded (33.333%), 6 pgs degraded"}, "severity": "HEALTH_WARN"}, "TOO_FEW_OSDS": {"summary": {"message": "OSD count 2 < osd_pool_default_size 3", "count": 1}, "severity": "HEALTH_WARN", "muted": false, "detail": []}}, "status": "HEALTH_WARN", "mutes": []},
         "quorum_names": ["pve-claude", "test3"], "fsid": "8793c51f-bcbf-40be-84ce-0498f3be7784",
         "monmap": {"epoch": 2, "mons": [{"name": "pve-claude", "rank": 0}, {"name": "test3", "rank": 1}]},
         "osdmap": {"osd_in_since": 1792760422, "epoch": 10, "num_up_osds": 2, "num_osds": 2, "num_in_osds": 2},
         "pgmap": {"bytes_avail": 68655693824, "num_pgs": 144, "degraded_total": 66, "bytes_used": 55394304, "bytes_total": 68711088128, "num_pools": 3, "pgs_by_state": [{"state_name": "active+clean", "count": 128}, {"state_name": "active+undersized", "count": 10}, {"count": 6, "state_name": "active+undersized+degraded"}], "num_objects": 22, "degraded_ratio": 0.333333333333333},
         "mgrmap": {"active_name": "pve-claude", "standbys": [{"name": "test3", "gid": 4123}], "available_modules": [{"name": "dashboard", "module_options": {}}]},
         "fsmap": {"up": 1, "up:standby": 0, "by_rank": [{"status": "up:active", "name": "pve-claude"}]}}
        """#
        let status = try decode(CephStatus.self, json)
        #expect(status.health == "HEALTH_WARN" && status.checks.map(\.code) == ["PG_DEGRADED", "TOO_FEW_OSDS"])
        #expect(status.checks[0].details == ["pg 3.0 is active+undersized+degraded, acting [0,1]"] && status.checks[1].summary == "OSD count 2 < osd_pool_default_size 3")
        #expect(status.monitors == ["pve-claude", "test3"] && status.quorum == ["pve-claude", "test3"])
        #expect(status.osdCount == 2 && status.osdsUp == 2 && status.osdsIn == 2)
        #expect(status.placementGroups == 144 && status.placementGroupStates.first?.state == "active+clean" && status.placementGroupStates.map(\.count) == [128, 10, 6])
        #expect(status.bytesUsed == 55_394_304 && status.bytesTotal == 68_711_088_128 && status.degradedRatio > 0.33)
        #expect(status.activeManager == "pve-claude" && status.standbyManagers == ["test3"] && status.metadataServersUp == 1)
    }

    @Test func decodesServicesAndOSDTree() throws {
        let monitors = try decode([CephService].self, #"[{"service": true, "addr": "10.10.100.150:6789/0", "host": "pve-claude", "quorum": 1, "state": "running", "rank": 0, "name": "pve-claude", "ceph_version_short": "20.2.4"}]"#)
        #expect(monitors[0].isRunning && monitors[0].inQuorum == true && monitors[0].version == "20.2.4")
        let mds = try decode([CephService].self, #"[{"name": "pve-claude", "host": "pve-claude", "state": "up:active", "fs_name": "pfprobefs"}, {"name": "b", "host": "b", "state": "stopped"}]"#)
        #expect(mds[0].fileSystem == "pfprobefs" && mds[0].isRunning && !mds[1].isRunning)

        let tree = #"""
        {"root": {"leaf": 0, "children": [{"pgs": 0, "id": "-1", "name": "default", "leaf": 0, "type": "root", "children": [{"name": "test3", "id": "-5", "type": "host", "children": [{"bytes_used": 447016960, "host": "test3", "status": "up", "leaf": 1, "in": 1, "device_class": "hdd", "name": "osd.1", "pgs": 7, "id": "1", "dbdev": null, "percent_used": 1.30114941322793, "type": "osd", "total_space": 34355544064, "ceph_version_short": "20.2.4"}]}, {"name": "pve-claude", "id": "-3", "type": "host", "children": [{"total_space": 34355544064, "percent_used": 0.08, "type": "osd", "name": "osd.0", "device_class": "hdd", "id": "0", "bytes_used": 27598848, "host": "pve-claude", "status": "down", "in": 0, "leaf": 1}]}]}]}, "flags": "sortbitwise,recovery_deletes,noout"}
        """#
        let decoded = try decode(CephOSDTree.self, tree)
        #expect(decoded.hosts == ["pve-claude", "test3"] && decoded.osds.map(\.id) == [0, 1])
        #expect(!decoded.osds[0].isUp && !decoded.osds[0].isIn && decoded.osds[1].isUp && decoded.osds[1].placementGroups == 7)
        #expect(decoded.osds[1].totalSpace == 34_355_544_064 && decoded.osds[1].host == "test3" && decoded.osds[1].name == "osd.1")
        #expect(decoded.flags.contains("noout"))
    }

    @Test func decodesPoolsFileSystemsAndFlags() throws {
        let pools = try decode([CephPool].self, #"""
        [{"min_size": 1, "target_size_ratio": null, "pg_num": 128, "pool_name": "pfprobe", "bytes_used": 0, "pool": 1, "size": 2, "target_size": null, "pg_num_final": 32, "crush_rule": 0, "percent_used": 0, "application_metadata": {"rbd": {}}, "type": "replicated", "crush_rule_name": "replicated_rule", "pg_num_min": null, "pg_autoscale_mode": "on"},
         {"pool": 3, "size": 3, "pool_name": "pfprobefs_metadata", "bytes_used": 97580, "pg_num": 8, "min_size": 2, "percent_used": 1.49616141698061e-06, "pg_num_min": 16, "pg_autoscale_mode": "on", "crush_rule_name": "replicated_rule", "application_metadata": {"cephfs": {"metadata": "pfprobefs"}}, "pg_num_final": 16, "target_size_ratio": 0.2}]
        """#)
        #expect(pools[0].name == "pfprobe" && pools[0].size == 2 && pools[0].minSize == 1 && pools[0].placementGroups == 128 && pools[0].placementGroupsTarget == 32)
        #expect(pools[0].applications == ["rbd"] && pools[0].targetSizeRatio == nil && pools[1].placementGroupsMinimum == 16)
        // Ceph's percent_used is a fraction.
        #expect(pools[1].percentUsed < 0.001 && pools[1].targetSizeRatio == 0.2)

        let fileSystems = try decode([CephFileSystem].self, #"[{"data_pool_ids": [2], "metadata_pool": "fs_metadata", "data_pools": ["fs_data"], "name": "fs", "metadata_pool_id": 3}]"#)
        #expect(fileSystems == [CephFileSystem(name: "fs", metadataPool: "fs_metadata", dataPools: ["fs_data"])])
        let flags = try decode([CephFlag].self, #"[{"description": "Scrubbing is disabled.", "name": "noscrub", "value": 1}, {"name": "noout", "value": 0, "description": "x"}]"#)
        #expect(flags.map(\.isSet) == [true, false])
        let safety = try decode(CephSafetyCheck.self, #"{"status": "unsafe to stop osd(s) at this time (7 PGs are or would become offline)", "safe": false}"#)
        #expect(!safety.isSafe && safety.status?.hasPrefix("unsafe") == true)
    }

    @Test func poolDrafts() throws {
        var draft = CephPoolDraft()
        draft.name = "vm-pool"
        #expect(draft.problems.isEmpty)
        #expect(PVE.createCephPool(node: "pve", draft).parameters.formEncoded
            == "name=vm-pool&crush_rule=replicated_rule&min_size=2&pg_autoscale_mode=on&pg_num=128&size=3&application=rbd&add_storages=1")
        draft.minSize = 1
        #expect(draft.warnsAboutMinSize)
        draft.size = 8
        draft.name = "a b"
        draft.targetSizeRatio = "-1"
        #expect(Set(draft.problems.keys) == ["name", "size", "target_size_ratio"])

        let pool = CephPool(name: "vm-pool", size: 3, minSize: 2, placementGroups: 128)
        let original = CephPoolDraft(pool)
        #expect(original.changes(from: original).items.isEmpty && !original.addStorage)
        var edited = original
        edited.size = 2
        edited.targetSizeGiB = "100"
        edited.autoscaleMode = "warn"
        #expect(edited.changes(from: original).formEncoded == "pg_autoscale_mode=warn&size=2&target_size=100G")
        #expect(PVE.updateCephPool(node: "pve", name: "vm-pool", edited.changes(from: original)).method == .put)
        #expect(PVE.destroyCephPool(node: "pve", name: "vm-pool", removeStorages: true).parameters.formEncoded == "remove_storages=1")
    }

    @Test func osdDrafts() {
        var draft = CephOSDDraft()
        #expect(draft.problems["dev"] != nil)
        draft.device = "/dev/sdb"
        #expect(PVE.createCephOSD(node: "pve", draft).parameters.formEncoded == "dev=%2Fdev%2Fsdb")
        draft.databaseDevice = "/dev/nvme0n1"
        draft.databaseSize = "30"
        draft.walDevice = "/dev/sdb"
        draft.walSize = "0.2"
        draft.encrypted = true
        draft.deviceClass = "hdd"
        #expect(Set(draft.problems.keys) == ["wal_dev", "wal_dev_size"])
        draft.walDevice = ""
        #expect(draft.problems.isEmpty)
        #expect(PVE.createCephOSD(node: "pve", draft).parameters.formEncoded == "dev=%2Fdev%2Fsdb&db_dev=%2Fdev%2Fnvme0n1&db_dev_size=30&encrypted=1&crush-device-class=hdd")
    }

    @Test func requests() {
        #expect(PVE.initializeCeph(node: "pve", network: "10.0.0.0/24", clusterNetwork: "", size: 3, minSize: 2).parameters.formEncoded == "network=10.0.0.0%2F24&size=3&min_size=2")
        #expect(PVE.createCephService(.monitor, node: "pve2").path == "/nodes/pve2/ceph/mon/pve2")
        #expect(PVE.createCephService(.metadataServer, node: "pve2", id: "fs-b", hotStandby: true).parameters.formEncoded == "hotstandby=1")
        #expect(PVE.cephServiceAction("restart", node: "pve2", service: "osd.3").parameters.formEncoded == "service=osd.3")
        #expect(PVE.setCephOSD(node: "pve", id: 3, in: false).path == "/nodes/pve/ceph/osd/3/out")
        #expect(PVE.scrubCephOSD(node: "pve", id: 3, deep: true).parameters.formEncoded == "deep=1")
        #expect(PVE.destroyCephOSD(node: "pve", id: 3, cleanup: true).parameters.formEncoded == "cleanup=1")
        #expect(PVE.setCephFlags(["noout": true, "noscrub": false]).parameters.formEncoded == "noout=1&noscrub=0")
        #expect(PVE.createCephFileSystem(node: "pve", name: "cephfs", placementGroups: 64, addStorage: true).parameters.formEncoded == "pg_num=64&add-storage=1")
    }
}
