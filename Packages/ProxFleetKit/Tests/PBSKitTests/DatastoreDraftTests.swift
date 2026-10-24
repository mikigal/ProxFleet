import Foundation
@testable import PBSKit
import ProxmoxCore
import Testing

struct DatastoreDraftTests {
    private func config(_ json: String) throws -> DatastoreConfig {
        try JSONDecoder().decode(DatastoreConfig.self, from: Data(json.utf8))
    }

    @Test func newDatastoresStartWithTheWebInterfacesSchedules() {
        let draft = DatastoreDraft()
        #expect(draft.gcSchedule == "daily")
        #expect(draft.pruneSchedule == "daily")
        #expect(draft.kind == .local)
    }

    @Test func localCreation() {
        var draft = DatastoreDraft()
        draft.name = " store3 "
        draft.path = "/mnt/datastore/store3"
        draft.comment = "Third"
        draft.retention = RetentionPolicy(last: 3, daily: 7)
        let parameters = draft.creationParameters(usesNotificationSystem: true)
        #expect(parameters["name"] == "store3")
        #expect(parameters["path"] == "/mnt/datastore/store3")
        #expect(parameters["gc-schedule"] == "daily")
        #expect(parameters["prune-schedule"] == "daily")
        #expect(parameters["keep-last"] == "3")
        #expect(parameters["keep-daily"] == "7")
        #expect(parameters["keep-weekly"] == nil)
        #expect(parameters["comment"] == "Third")
        #expect(parameters["notification-mode"] == "notification-system")
        #expect(parameters["backing-device"] == nil)
        #expect(parameters["reuse-datastore"] == nil)
        // Releases before the notification system know no notification mode.
        #expect(draft.creationParameters(usesNotificationSystem: false)["notification-mode"] == nil)
    }

    @Test func removableAndS3Creation() {
        var removable = DatastoreDraft()
        removable.name = "usb"
        removable.kind = .removable
        removable.path = "backups"
        removable.backingDevice = "c3d7e1f0-5a2b-4c9e-8f61-2b7d40a9e113"
        removable.reuseExisting = true
        let parameters = removable.creationParameters(usesNotificationSystem: true)
        #expect(parameters["backing-device"] == "c3d7e1f0-5a2b-4c9e-8f61-2b7d40a9e113")
        #expect(parameters["reuse-datastore"] == .bool(true))

        var s3 = DatastoreDraft()
        s3.name = "cloud"
        s3.kind = .s3
        s3.path = "/mnt/cache"
        s3.s3Endpoint = "minio"
        s3.bucket = "pbs"
        s3.overwriteInUse = true
        let s3Parameters = s3.creationParameters(usesNotificationSystem: true)
        #expect(s3Parameters["backend"] == "type=s3,client=minio,bucket=pbs")
        #expect(s3Parameters["overwrite-in-use"] == .bool(true))
    }

    @Test func problemsByParameter() {
        var draft = DatastoreDraft()
        draft.name = "-x"
        draft.path = "relative"
        #expect(Set(draft.problems(isNew: true).keys) == ["name", "path"])
        draft.name = "store1"
        draft.path = "/mnt/store1"
        #expect(draft.problems(isNew: true).isEmpty)
        draft.kind = .removable
        #expect(Set(draft.problems(isNew: true).keys) == ["path", "backing-device"])
        draft.kind = .s3
        #expect(Set(draft.problems(isNew: true).keys) == ["backend", "bucket"])
        // Existing datastores keep their location.
        draft.kind = .local
        draft.name = ""
        #expect(draft.problems(isNew: false).isEmpty)
        draft.maintenance = DatastoreMaintenance(kind: .offline, message: String(repeating: "x", count: 65))
        #expect(draft.problems(isNew: false).keys.contains("maintenance-mode"))
    }

    @Test func onlyChangesAreSentAndClearedSettingsAreDeleted() throws {
        let stored = try config(#"{"name":"store1","path":"/datastore/store1","comment":"Main","gc-schedule":"daily","verify-new":true,"notification-mode":"notification-system","tuning":"chunk-order=none,future-option=7"}"#)
        let original = DatastoreDraft(stored)
        var draft = original
        #expect(draft.changes(from: original).isEmpty)

        draft.comment = ""
        draft.gcSchedule = "sat 03:00"
        draft.verifyNew = false
        draft.tuning["sync-level"] = "file"
        let update = draft.changes(from: original, digest: "abc")
        #expect(update.values == ["gc-schedule": "sat 03:00", "tuning": "chunk-order=none,future-option=7,sync-level=file"])
        #expect(update.deletions == ["comment", "verify-new"])
        // `delete` is a list: one parameter per setting.
        #expect(update.parameters.values("delete") == ["comment", "verify-new"])
        #expect(update.parameters["digest"] == "abc")
    }

    @Test func tuningKeepsUnknownOptionsAndClearsWhenEmpty() {
        var tuning = PropertyMap(parsing: "chunk-order=none,future-option=7")
        tuning["chunk-order"] = nil
        #expect(tuning.stringValue == "future-option=7")
        tuning["future-option"] = " "
        #expect(tuning.stringValue == nil)
    }

    @Test func notificationsAsTheServerWritesThem() throws {
        let stored = try config(#"{"name":"store1","path":"/x","notification-mode":"legacy-sendmail","notify-user":"admin@pbs","notify":"gc=error,prune=never"}"#)
        var draft = DatastoreDraft(stored)
        #expect(draft.usesSendmail)
        #expect(draft.notify == ["gc": .error, "prune": .never])
        draft.notify["verify"] = .always
        draft.notify["gc"] = nil
        #expect(draft.changes(from: DatastoreDraft(stored)).values["notify"] == "verify=always,prune=never")
    }

    @Test func maintenanceAsStoredByTheServer() throws {
        // Recorded on 4.2 after setting it with the web interface's format: the type unnamed, quotes escaped.
        let stored = try config(#"{"name":"pflive","path":"/x","maintenance-mode":"read-only,message=\"Moving, \\\"soon\\\"\""}"#)
        let maintenance = try #require(stored.maintenance)
        #expect(maintenance.kind == .readOnly)
        #expect(maintenance.message == #"Moving, "soon""#)
        var draft = DatastoreDraft(stored)
        draft.maintenance = nil
        #expect(draft.changes(from: DatastoreDraft(stored)).deletions == ["maintenance-mode"])
    }

    @Test func legacyPruneSettingsRoundTrip() throws {
        let stored = try config(#"{"name":"old","path":"/x","prune-schedule":"daily","keep-last":3,"keep-daily":7}"#)
        var draft = DatastoreDraft(stored)
        #expect(draft.retention == RetentionPolicy(last: 3, daily: 7))
        draft.retention.daily = nil
        draft.retention.weekly = 4
        let update = draft.changes(from: DatastoreDraft(stored))
        #expect(update.values == ["keep-weekly": "4"])
        #expect(update.deletions == ["keep-daily"])
    }
}

struct AccessAndDiskFixtureTests {
    @Test func aclEntries() throws {
        let acl = try envelopeFixture("access-acl", as: Digested<[BackupServerACLEntry]>.self)
        #expect(acl.digest != nil)
        let limited = try #require(acl.value.first { $0.authID == "limited@pbs" })
        #expect(limited.path == "/datastore/store1")
        #expect(limited.role == "DatastoreAudit")
        #expect(limited.propagates)
        #expect(acl.value.first { $0.authID == "root@pam!seed" }?.isToken == true)
    }

    @Test func aclChanges() {
        let entry = BackupServerACLEntry(path: "/datastore/store1/pve", authID: "anna@pbs", role: "DatastoreBackup", propagates: false)
        #expect(PBS.setACL(entry).parameters == ["path": "/datastore/store1/pve", "role": "DatastoreBackup", "auth-id": "anna@pbs", "propagate": false])
        let removal = PBS.setACL(entry, remove: true, digest: "d")
        #expect(removal.method == .put)
        #expect(removal.parameters["delete"] == .bool(true))
        #expect(removal.parameters["propagate"] == nil)
        #expect(removal.parameters["digest"] == "d")
    }

    @Test func rolesAndUsers() throws {
        let roles = try fixture("access-roles", as: [BackupServerRole].self)
        let reader = try #require(roles.first { $0.id == "DatastoreReader" })
        #expect(reader.privileges.contains("Datastore.Read"))
        #expect(reader.comment?.contains("restores") == true)
        let users = try envelopeFixture("access-users", as: Digested<[BackupServerUser]>.self).value
        let root = try #require(users.first { $0.id == "root@pam" })
        #expect(root.tokens.map(\.id) == ["root@pam!seed"])
        #expect(root.authIDs == ["root@pam", "root@pam!seed"])
        #expect(root.isEnabled)
    }

    @Test func privilegesAreBooleans() throws {
        let permissions = try fixture("access-permissions", as: [String: [String: Bool]].self)
        #expect(permissions["/"]?["Datastore.Allocate"] == true)
    }

    @Test func disksWithNestedPartitions() throws {
        let disks = try fixture("node-disks-list", as: [BackupServerDisk].self)
        let system = try #require(disks.first { $0.name == "sda" })
        #expect(!system.partitions.isEmpty)
        #expect(system.datastorePartitions.isEmpty)
        let spare = try #require(disks.first { $0.name == "sdb" })
        #expect(spare.isUnused)
        #expect(spare.size == 34_359_738_368)
        #expect(PBS.disks().parameters == ["include-partitions": true, "skipsmart": true])
    }

    @Test func bucketListsInEitherShape() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(S3BucketList.self, from: Data(#"["b","a"]"#.utf8)).names == ["a", "b"])
        #expect(try decoder.decode(S3BucketList.self, from: Data(#"[{"name":"pbs"},{"other":1}]"#.utf8)).names == ["pbs"])
    }
}
