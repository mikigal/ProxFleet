import Foundation
@testable import PBSKit
import ProxmoxCore
import PVEKit
import Testing

struct RequestTests {
    private let group = BackupGroupReference(namespace: BackupNamespace("pve/nested"), type: .ct, backupID: "200")

    @Test func contentCallsNameTheGroupAndItsNamespace() {
        let snapshot = group.snapshot(at: 1_792_850_989)
        let request = PBS.snapshotFiles("store1", snapshot)
        #expect(request.path == "/admin/datastore/store1/files")
        #expect(request.parameters == ["backup-type": "ct", "backup-id": "200", "ns": "pve/nested", "backup-time": 1_792_850_989])
        // The root namespace is left out.
        let root = BackupGroupReference(type: .host, backupID: "pbs-claude")
        #expect(PBS.groups("store1").parameters.isEmpty)
        #expect(root.parameters == ["backup-type": "host", "backup-id": "pbs-claude"])
    }

    @Test func verificationAlwaysSaysWhetherToSkipVerified() {
        let all = PBS.verify("store1", skipVerified: false)
        #expect(all.method == .post)
        #expect(all.parameters == ["ignore-verified": false])
        let outdated = PBS.verify("store1", group: group, skipVerified: true, reverifyAfterDays: 30)
        #expect(outdated.parameters["ignore-verified"] == .bool(true))
        #expect(outdated.parameters["outdated-after"] == .int(30))
        #expect(outdated.parameters["backup-id"] == "200")
    }

    @Test func pruneSendsOnlySetRules() {
        let retention = RetentionPolicy(last: 3, hourly: 0, daily: 7)
        let preview = PBS.previewPrune("store1", group, keep: retention)
        #expect(preview.parameters["keep-last"] == .int(3))
        #expect(preview.parameters["keep-daily"] == .int(7))
        #expect(preview.parameters["keep-hourly"] == nil)
        #expect(preview.parameters["dry-run"] == .bool(true))
        #expect(PBS.prune("store1", group, keep: retention).parameters["use-task"] == .bool(true))
        #expect(RetentionPolicy().keepsEverything)
        #expect(RetentionPolicy().parameters.isEmpty)
    }

    @Test func catalogAndDownloads() {
        let snapshot = group.snapshot(at: 10)
        let catalog = PBS.catalog("store1", snapshot, filePath: "/")
        #expect(catalog.parameters["filepath"] == "/")
        #expect(catalog.parameters["archive-name"] == nil)
        let split = PBS.catalog("store1", snapshot, filePath: "cm9vdA==", archive: "root.mpxar.didx")
        #expect(split.parameters["archive-name"] == "root.mpxar.didx")
        let directory = PBS.downloadArchiveEntry("store1", snapshot, filePath: "cm9vdA==", tar: true)
        #expect(directory.path == "/admin/datastore/store1/pxar-file-download")
        #expect(directory.parameters["tar"] == .bool(true))
        #expect(PBS.downloadSnapshotFile("store1", snapshot, fileName: "pct.conf.blob").parameters["file-name"] == "pct.conf.blob")
    }

    @Test func namespaceCalls() {
        #expect(PBS.namespaces("store1").parameters.isEmpty)
        #expect(PBS.namespaces("store1", parent: BackupNamespace("pve"), maxDepth: 1).parameters == ["parent": "pve", "max-depth": 1])
        #expect(PBS.createNamespace("store1", name: "nested", parent: .root).parameters == ["name": "nested"])
        let delete = PBS.deleteNamespace("store1", BackupNamespace("pve/nested"), deleteGroups: true)
        #expect(delete.method == .delete)
        #expect(delete.parameters == ["ns": "pve/nested", "delete-groups": true])
    }

    @Test func datastoreCalls() {
        #expect(PBS.datastoreStatus("store 1").path == "/admin/datastore/store%201/status")
        #expect(PBS.datastoreStatus("store1").parameters == ["verbose": true])
        #expect(PBS.datastoreRRD("store1", timeframe: .day).parameters == ["timeframe": "day", "cf": "AVERAGE"])
        let delete = PBS.deleteDatastore("store1", destroyData: true, keepJobs: false, digest: "abc")
        #expect(delete.method == .delete)
        #expect(delete.parameters == ["destroy-data": true, "keep-job-configs": false, "digest": "abc"])
    }

    @Test func jobLists() {
        #expect(PBS.syncJobs().parameters == ["sync-direction": "all"])
        // Servers before 3.3 refuse the parameter.
        #expect(PBS.syncJobs(direction: nil).parameters.isEmpty)
        #expect(PBS.verifyJobs(store: "store1").parameters == ["store": "store1"])
        #expect(PBS.runSyncJob("pf-sync").path == "/admin/sync/pf-sync/run")
    }

    @Test func taskFilters() {
        var filter = BackupServerTaskFilter(limit: 20)
        filter.since = Date(timeIntervalSince1970: 1_792_800_000)
        filter.statuses = [.error, .warning]
        filter.store = "store1"
        let request = PBS.tasks(filter)
        #expect(request.path == "/nodes/localhost/tasks")
        #expect(request.parameters.values("statusfilter") == ["error", "warning"])
        #expect(request.parameters["since"] == .int(1_792_800_000))
        #expect(request.parameters["store"] == "store1")
        #expect(request.parameters["limit"] == .int(20))
        // Colons may stay in a path; the backslashes of escaped task IDs may not.
        #expect(PBS.taskStatus(upid: #"UPID:pbs:1:2:3:4:verify:store1\x3apf:root@pam:"#).path == "/nodes/localhost/tasks/UPID:pbs:1:2:3:4:verify:store1%5Cx3apf:root@pam:/status")
    }
}

struct ModelTests {
    @Test(arguments: [
        ("type=read-only", DatastoreMaintenance.Kind.readOnly, nil as String?),
        (#"type=offline,message="Disk swap""#, .offline, "Disk swap"),
        (#"message="Moving, back soon",type=offline"#, .offline, "Moving, back soon"),
        (#"offline,message="Say \"hi\"""#, .offline, #"Say "hi""#),
    ])
    func readsMaintenanceModes(text: String, kind: DatastoreMaintenance.Kind, message: String?) throws {
        let maintenance = try #require(DatastoreMaintenance(parsing: text))
        #expect(maintenance.kind == kind)
        #expect(maintenance.message == message)
    }

    @Test func writesMaintenanceModesLikeTheWebInterface() {
        #expect(DatastoreMaintenance(kind: .readOnly).stringValue == "type=read-only")
        #expect(DatastoreMaintenance(kind: .offline, message: #"Say "hi" \o/"#).stringValue == #"type=offline,message="Say \"hi\" o/""#)
        #expect(DatastoreMaintenance(parsing: "") == nil)
        let unknown = DatastoreMaintenance(parsing: "type=future-mode")
        #expect(unknown?.kind == nil)
        #expect(unknown?.stringValue == "type=future-mode")
    }

    @Test func snapshotFileKinds() {
        #expect(SnapshotFile(name: "root.mpxar.didx").kind == .fileArchive)
        #expect(SnapshotFile(name: "root.ppxar.didx").kind == .filePayload)
        #expect(SnapshotFile(name: "catalog.pcat1.didx").kind == .catalog)
        #expect(SnapshotFile(name: "index.json.blob").kind == .blob)
        #expect(SnapshotFile(name: "drive-efidisk0.img.fidx").displayName == "drive-efidisk0.img")
    }

    @Test func featureTable() throws {
        let version32 = PBSVersion(version: "3.2", release: "7")
        #expect(version32.number == PVEVersionNumber(3, 2, 7))
        #expect(version32.supports(.notifications))
        #expect(!version32.supports(.pushSync))
        #expect(!PBSVersion(version: "3.4", release: "1").supports(.s3Datastores))
        #expect(PBSVersion(version: "4.0", release: "14").supports(.s3Datastores))
        #expect(!PBSVersion(version: "4.1", release: "0").supports(.moveGroupsAndNamespaces))
        #expect(!PBSVersion(version: "2.4", release: "7").isSupported)
        #expect(PBSVersion(version: "3.0", release: "1").isSupported)
        // A version the app cannot read offers everything.
        #expect(PBSVersion(version: "unknown").supports(.syncEncryption))
    }

    @Test func remoteAddresses() throws {
        let decoder = JSONDecoder()
        let plain = try decoder.decode(BackupRemote.self, from: Data(#"{"name":"a","host":"pbs.lan","auth-id":"sync@pbs"}"#.utf8))
        #expect(plain.address == "pbs.lan")
        let port = try decoder.decode(BackupRemote.self, from: Data(#"{"name":"a","host":"fd00::1","port":8008,"auth-id":"sync@pbs"}"#.utf8))
        #expect(port.address == "[fd00::1]:8008")
    }
}
