import DemoServer
import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

/// Backup jobs, with responses recorded from Proxmox VE 9.2.
struct BackupJobTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func jobs() throws {
        let jobs = try decode([BackupJob].self, #"""
        [{"enabled": 1, "type": "vzdump", "notes-template": "{{guestname}}", "prune-backups": {"keep-last": "2"}, "vmid": "200,201",
          "comment": "probe", "id": "7cc37d47-abd2", "compress": "zstd", "schedule": "sat 02:00", "storage": "local", "mode": "snapshot",
          "next-run": 1792800000},
         {"schedule": "sat 02:00", "storage": "local", "mode": "snapshot", "exclude": "201", "prune-backups": {"keep-daily": "3", "keep-weekly": "2"},
          "enabled": 0, "id": "second", "all": 1, "compress": "zstd", "type": "vzdump"},
         {"id": "old", "dow": "mon,tue", "starttime": "02:30", "pool": "lab", "prune-backups": "keep-all=1"}]
        """#)
        #expect(jobs[0].selection == .guests([200, 201]) && jobs[0].prune?.serialized == "keep-last=2")
        #expect(jobs[0].nextRun == Date(timeIntervalSince1970: 1_792_800_000) && jobs[0].notesTemplate == "{{guestname}}")
        #expect(jobs[1].selection == .all(excluding: [201]) && !jobs[1].isEnabled && jobs[1].prune?.serialized == "keep-daily=3,keep-weekly=2")
        #expect(jobs[2].schedule == "mon,tue 02:30" && jobs[2].selection == .pool("lab") && jobs[2].prune?.keepAll == true)

        let draft = BackupJobDraft(jobs[1])
        #expect(draft.selectionMode == .exclude && draft.guests == [201] && draft.customRetention)
    }

    @Test func switchingSelectionDeletesTheOtherSettings() throws {
        let job = try decode(BackupJob.self, #"{"id": "j", "vmid": "200,201", "storage": "local", "schedule": "21:00", "mode": "snapshot", "compress": "zstd", "enabled": 1}"#)
        let original = BackupJobDraft(job)
        #expect(original.changes(from: original).isEmpty && !original.customRetention)
        var draft = original
        draft.selectionMode = .all
        draft.customRetention = true
        draft.prune.counts = ["keep-daily": "7"]
        let update = draft.changes(from: original)
        #expect(update.values == ["all": "1", "prune-backups": "keep-daily=7"])
        #expect(update.deletions == ["vmid"])

        var empty = BackupJobDraft()
        empty.selectionMode = .guests
        empty.schedule = " "
        #expect(empty.problems.keys.sorted() == ["schedule", "storage", "vmid"])
        empty.customRetention = true
        #expect(empty.serialized()["prune-backups"] == "keep-all=1")
    }

    @Test func creationParameters() {
        var draft = BackupJobDraft()
        draft.storage = "pbs"
        draft.schedule = "sat 02:00"
        draft.selectionMode = .guests
        draft.guests = [201, 100]
        draft.comment = "Weekly"
        #expect(draft.problems.isEmpty)
        #expect(PVE.createBackupJob(draft).parameters.formEncoded
            == "comment=Weekly&compress=zstd&enabled=1&mode=snapshot&notes-template=%7B%7Bguestname%7D%7D&schedule=sat%2002%3A00&storage=pbs&vmid=100%2C201")
    }

    @Test func runNowGoesToTheNodesOfTheGuests() async throws {
        let session = ProxmoxSession(address: ServerAddress(host: "demo", port: 8006), transport: DemoTransport())
        _ = try await session.login(username: "root", password: "pw", realm: "pam")
        let snapshot = try await session.fetchClusterSnapshot()
        let jobs = try await session.send(PVE.backupJobs())

        let nightly = try #require(jobs.first { $0.comment == "Nightly, everything" })
        let all = nightly.runNowRequests(in: snapshot)
        // pve3 is offline.
        #expect(all.map(\.node) == ["pve1", "pve2"])
        #expect(all[0].request.parameters.formEncoded == "storage=local&mode=snapshot&compress=zstd&notes-template=%7B%7Bguestname%7D%7D&all=1&exclude=9000")

        let weekly = try #require(jobs.first { $0.storage == "pbs" })
        let byNode = weekly.runNowRequests(in: snapshot)
        #expect(byNode.map(\.node) == ["pve1"])
        #expect(byNode[0].request.parameters["vmid"] == .string("100,101,200"))
        #expect(byNode[0].request.parameters["prune-backups"] == .string("keep-weekly=8"))
    }
}
