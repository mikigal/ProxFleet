import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct ReplicationTests {
    /// `GET /nodes/pve-claude/replication` of the test cluster on PVE 9.2, before the first run and after one.
    private let beforeFirstRun = #"[{"fail_count": 0, "guest": 230, "target": "test2", "jobnum": 0, "last_try": 0, "source": "pve-claude", "next_sync": 1800, "vmtype": "qemu", "comment": "probe", "schedule": "*/30", "last_sync": 0, "rate": 50, "id": "230-0", "type": "local"}]"#
    private let afterRun = #"{"id": "230-0", "type": "local", "rate": 50, "last_sync": 1792751463, "duration": 2.245835, "schedule": "*/30", "comment": "probe", "last_try": 1792751463, "next_sync": 1792753200, "vmtype": "qemu", "source": "pve-claude", "target": "test2", "fail_count": 0, "guest": 230, "jobnum": 0}"#

    @Test func decodesStateAsRecordedFromPVE92() throws {
        let pending = try #require(try JSONDecoder().decode([ReplicationJob].self, from: Data(beforeFirstRun.utf8)).first)
        #expect(pending.id == "230-0" && pending.guest == 230 && pending.jobNumber == 0 && pending.target == "test2" && pending.source == "pve-claude")
        #expect(pending.rate == 50 && pending.schedule == "*/30" && pending.isEnabled && pending.guestType == "qemu")
        // Never synced: no last sync, and a next sync in 1970, which counts as pending.
        #expect(pending.lastSync == nil && pending.isPending())

        let synced = try JSONDecoder().decode(ReplicationJob.self, from: Data(afterRun.utf8))
        #expect(synced.lastSync == Date(timeIntervalSince1970: 1_792_751_463) && synced.duration == 2.245835)
        #expect(!synced.isPending(at: Date(timeIntervalSince1970: 1_792_751_500)) && !synced.isRunning && synced.error == nil)
    }

    @Test func decodesConfigurationRemovalAndErrors() throws {
        let json = #"[{"source": "pve-claude", "target": "test2", "guest": 230, "type": "local", "jobnum": 0, "schedule": "*/30", "disable": 1, "id": "230-0", "remove_job": "full"}, {"id": "101-2", "target": "test3", "type": "local", "pid": 4711, "error": "missing replicate feature\n", "fail_count": 3}]"#
        let jobs = try JSONDecoder().decode([ReplicationJob].self, from: Data(json.utf8))
        #expect(!jobs[0].isEnabled && jobs[0].removal == "full" && jobs[0].guestType == nil)
        // Without guest and jobnum, the ID tells them.
        #expect(jobs[1].guest == 101 && jobs[1].jobNumber == 2 && jobs[1].schedule == "*/15")
        #expect(jobs[1].isRunning && jobs[1].error == "missing replicate feature" && jobs[1].failCount == 3)
    }

    @Test func newJobsTakeTheGuestsNextNumber() {
        let existing = [ReplicationJob(id: "100-0", guest: 100, target: "b"), ReplicationJob(id: "100-3", guest: 100, jobNumber: 3, target: "c"), ReplicationJob(id: "101-0", guest: 101, target: "b")]
        #expect(ReplicationJobDraft.nextID(for: 100, existing: existing) == "100-4")
        #expect(ReplicationJobDraft.nextID(for: 102, existing: existing) == "102-0")
    }

    @Test func creationLeavesDefaultsOut() {
        var draft = ReplicationJobDraft(guest: 230, target: "test2")
        #expect(draft.problems.isEmpty)
        let request = PVE.createReplicationJob(draft, id: "230-0")
        #expect(request.method == .post && request.path == "/cluster/replication")
        #expect(request.parameters.formEncoded == "id=230-0&type=local&target=test2")
        draft.schedule = "*/30"
        draft.rate = "12,5"
        draft.comment = " nightly "
        draft.isEnabled = false
        #expect(PVE.createReplicationJob(draft, id: "230-1").parameters.formEncoded == "id=230-1&type=local&target=test2&comment=nightly&disable=1&rate=12.5&schedule=%2A%2F30")
    }

    @Test func editsSendChangesAndDeleteClearedValues() {
        let job = ReplicationJob(id: "230-0", guest: 230, target: "test2", schedule: "*/30", rate: 50, comment: "probe")
        let original = ReplicationJobDraft(job)
        #expect(original.rate == "50" && original.changes(from: original).isEmpty)
        var edited = original
        edited.rate = ""
        edited.comment = ""
        edited.schedule = "*/15"
        edited.isEnabled = false
        let update = edited.changes(from: original)
        #expect(update.values == ["disable": "1"] && update.deletions == ["rate", "comment", "schedule"])
        #expect(PVE.updateReplicationJob("230-0", update).path == "/cluster/replication/230-0")
    }

    @Test func problems() {
        var draft = ReplicationJobDraft(guest: 0)
        #expect(Set(draft.problems.keys) == ["guest", "target"])
        draft = ReplicationJobDraft(guest: 100, target: "b")
        draft.rate = "0.5"
        #expect(draft.problems["rate"] != nil)
        draft.rate = "abc"
        #expect(draft.problems["rate"] != nil)
    }

    @Test func requests() {
        #expect(PVE.replicationStatus(node: "pve", guest: 100).path == "/nodes/pve/replication")
        #expect(PVE.replicationStatus(node: "pve", guest: 100).parameters["guest"] == .int(100))
        #expect(PVE.deleteReplicationJob("100-0").parameters.formEncoded == "")
        #expect(PVE.deleteReplicationJob("100-0", keep: true).parameters.formEncoded == "keep=1")
        #expect(PVE.runReplicationNow(node: "pve", id: "100-0").path == "/nodes/pve/replication/100-0/schedule_now")
        #expect(PVE.replicationLog(node: "pve", id: "100-0").path == "/nodes/pve/replication/100-0/log")
    }
}
