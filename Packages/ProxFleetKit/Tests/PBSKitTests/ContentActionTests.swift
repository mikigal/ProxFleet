import Foundation
@testable import PBSKit
import ProxmoxCore
import PVEKit
import Testing

struct ContentActionTests {
    private let group = BackupGroupReference(namespace: BackupNamespace("pve"), type: .vm, backupID: "102")

    @Test func moves() {
        let move = PBS.moveGroup("store1", group, to: BackupNamespace("archive"), merge: true)
        #expect(move.method == .post)
        #expect(move.path == "/admin/datastore/store1/move-group")
        #expect(move.parameters == ["backup-type": "vm", "backup-id": "102", "ns": "pve", "target-ns": "archive", "merge-group": true])
        // The root namespace is named with an empty path when it is the target.
        #expect(PBS.moveGroup("store1", group, to: .root, merge: false).parameters["target-ns"] == "")
        let namespace = PBS.moveNamespace("store1", BackupNamespace("pve"), to: BackupNamespace("old/pve"), mergeGroups: true)
        #expect(namespace.parameters == ["ns": "pve", "target-ns": "old/pve", "merge-groups": true])
    }

    @Test func pruneOfANamespace() {
        let request = PBS.pruneNamespace("store1", BackupNamespace("pve"), keep: RetentionPolicy(last: 2, weekly: 4), dryRun: true)
        #expect(request.path == "/admin/datastore/store1/prune-datastore")
        #expect(request.parameters == ["keep-last": 2, "keep-weekly": 4, "ns": "pve", "dry-run": true])
        #expect(PBS.pruneNamespace("store1", .root, keep: RetentionPolicy(last: 1)).parameters == ["keep-last": 1])
    }

    @Test func deletionsKeepProtectedSnapshotsWithoutAnError() {
        // The server deletes the unprotected snapshots either way; without this it reports that as an error.
        #expect(PBS.deleteGroup("store1", group).parameters["error-on-protected"] == .bool(false))
        #expect(PBS.deleteNamespace("store1", BackupNamespace("pve"), deleteGroups: true).parameters == ["ns": "pve", "delete-groups": true, "error-on-protected": false])
    }

    @Test func deletionResults() throws {
        // Recorded on 4.2.
        let result = try JSONDecoder().decode(DeletionResult.self, from: Data(#"{"protected-snapshots":1,"removed-groups":0,"removed-snapshots":2}"#.utf8))
        #expect(result.protectedSnapshots == 1)
        #expect(result.removedGroups == 0)
        #expect(result.removedSnapshots == 2)
    }

    @Test func pruneDecisions() throws {
        let decisions = try JSONDecoder().decode([SnapshotPruneDecision].self, from: Data(#"""
        [{"backup-id":"200","backup-time":1792850989,"backup-type":"ct","keep":true,"protected":true},
         {"backup-id":"200","backup-time":1792850991,"backup-type":"ct","keep":false,"protected":false}]
        """#.utf8))
        #expect(decisions.map(\.keep) == [true, false])
        #expect(decisions[0].isProtected)
        #expect(decisions[1].reference.group.path == "ct/200")
    }

    /// Task IDs recorded on 4.2 while moving and pruning.
    @Test func taskTitlesForContentTasks() throws {
        let prune = try #require(UPID(#"UPID:pbs-claude:000002CB:00000218:00000020:6ADCD152:prune:pflive\x2dcontent\x3a\x3act-200:root@pam:"#))
        #expect(TaskDescription.title(type: prune.type, objectID: prune.objectID) == "pflive-content ct/200 – Prune")
        let pruneAll = try #require(UPID(#"UPID:pbs-claude:000002CB:00000218:00000021:6ADCD152:prune:pflive\x2dcontent\x3a:root@pam:"#))
        #expect(TaskDescription.title(type: pruneAll.type, objectID: pruneAll.objectID) == "pflive-content – Prune")
        let move = try #require(UPID(#"UPID:pbs-claude:000002CB:00000218:0000001E:6ADCD152:move-group:pflive\x2dcontent\x3a-vm-102\x3amoved:root@pam:"#))
        #expect(TaskDescription.title(type: move.type, objectID: move.objectID) == "pflive-content vm/102 → moved – Move Group")
        let moveNamespace = try #require(UPID(#"UPID:pbs-claude:000002CB:00000218:0000001F:6ADCD152:move-namespace:pflive\x2dcontent\x3amoved\x3atarget-moved:root@pam:"#))
        #expect(TaskDescription.title(type: moveNamespace.type, objectID: moveNamespace.objectID) == "pflive-content moved → target/moved – Move Namespace")
    }
}
