import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct BackupTests {
    private let vm = GuestReference(node: "pve", vmid: 100, kind: .virtualMachine)
    private let container = GuestReference(node: "pve", vmid: 202, kind: .container)

    @Test func decodesBackupsAsRecordedFromPVE92() throws {
        let json = #"[{"format": "tar.zst", "notes": "backup-agent from test", "volid": "local:backup/vzdump-lxc-202-2026_10_21-15_08_45.tar.zst", "subtype": "lxc", "vmid": 202, "size": 4215482, "content": "backup", "ctime": 1792588125}]"#
        let backup = try #require(try JSONDecoder().decode([BackupVolume].self, from: Data(json.utf8)).first)
        #expect(backup.storage == "local")
        #expect(backup.fileName == "vzdump-lxc-202-2026_10_21-15_08_45.tar.zst")
        #expect(backup.notes == "backup-agent from test")
        #expect(!backup.isProtected)
        #expect(backup.date == Date(timeIntervalSince1970: 1_792_588_125))
        let protected = try JSONDecoder().decode(BackupVolume.self, from: Data(#"{"volid": "local:backup/a.tar.zst", "protected": 1, "notes": "x\n"}"#.utf8))
        #expect(protected.isProtected && protected.notes == "x")
    }

    @Test func backupNow() {
        var draft = BackupDraft(guest: container)
        #expect(draft.problems.keys.sorted() == ["storage"])
        draft.storage = "local"
        draft.isProtected = true
        let request = PVE.backupNow(draft)
        #expect(request.path == "/nodes/pve/vzdump")
        #expect(request.parameters.formEncoded
            == "vmid=202&storage=local&mode=snapshot&compress=zstd&remove=0&notification-mode=notification-system&notes-template=%7B%7Bguestname%7D%7D&protected=1")
        draft.notes = "  "
        draft.compression = .none
        draft.mode = .stop
        draft.prunes = true
        draft.usesLegacySendmail = true
        #expect(draft.problems.keys.sorted() == ["mailto"])
        draft.mailto = " ops@example.com "
        #expect(PVE.backupNow(draft).parameters.formEncoded
            == "vmid=202&storage=local&mode=stop&compress=0&remove=1&notification-mode=legacy-sendmail&protected=1&mailto=ops%40example.com")
    }

    /// PVE 8.0 knows no `notification-mode` and mails only when recipients are given.
    @Test func backupNowBeforeTheNotificationSystem() {
        var draft = BackupDraft(guest: container)
        draft.storage = "local"
        draft.useSendmailOnly()
        #expect(draft.problems.isEmpty && draft.usesLegacySendmail)
        #expect(PVE.backupNow(draft).parameters.formEncoded == "vmid=202&storage=local&mode=snapshot&compress=zstd&remove=0&notes-template=%7B%7Bguestname%7D%7D")
        draft.mailto = "ops@example.com"
        #expect(PVE.backupNow(draft).parameters["mailto"] == "ops@example.com")
    }

    @Test func volumeRequestsEscapeTheVolumeID() {
        let volume = "local:backup/vzdump-qemu-100-2026_10_21-15_08_47.vma.zst"
        let update = PVE.updateBackup(node: "pve", volume: volume, notes: "note\n", isProtected: true)
        #expect(update.method == .put)
        #expect(update.path == "/nodes/pve/storage/local/content/local:backup%2Fvzdump-qemu-100-2026_10_21-15_08_47.vma.zst")
        #expect(update.parameters.formEncoded == "notes=note&protected=1")
        #expect(PVE.deleteBackup(node: "pve", volume: volume).method == .delete)
        #expect(PVE.backupConfiguration(node: "pve", volume: volume).parameters["volume"] == .string(volume))
    }

    @Test func restoreOverTheGuest() {
        let backup = BackupVolume(volumeID: "local:backup/vzdump-qemu-100.vma.zst")
        var draft = RestoreDraft(backup: backup, source: vm)
        draft.sourceIsRunning = true
        #expect(draft.problems.keys.sorted() == ["force"])
        draft.sourceIsRunning = false
        #expect(draft.problems.isEmpty)
        let request = PVE.restore(draft)
        #expect(request.path == "/nodes/pve/qemu")
        #expect(request.parameters.formEncoded == "vmid=100&archive=local%3Abackup%2Fvzdump-qemu-100.vma.zst&force=1")
    }

    @Test func restoreAsNewContainerNeedsAStorage() {
        let backup = BackupVolume(volumeID: "local:backup/vzdump-lxc-202.tar.zst")
        var draft = RestoreDraft(backup: backup, source: container)
        draft.overwrites = false
        draft.sourceIsRunning = true
        #expect(draft.problems.keys.sorted() == ["storage", "vmid"])
        draft.vmid = 230
        draft.storage = "local-lvm"
        draft.uniqueMACAddresses = true
        draft.startAfterRestore = true
        #expect(draft.problems.isEmpty)
        #expect(draft.target.vmid == 230)
        #expect(PVE.restore(draft).parameters.formEncoded == "vmid=230&ostemplate=local%3Abackup%2Fvzdump-lxc-202.tar.zst&restore=1&storage=local-lvm&unique=1&start=1")
    }

    @Test func backupConfigurationHidesInternalLines() {
        let text = "agent: 1\nname: web\n#qmdump#map:scsi0:drive-scsi0:local-lvm:raw:\n"
        #expect(GuestConfig.displayLines(ofBackupConfiguration: text) == ["agent: 1", "name: web"])
    }

    @Test func restoreOverridesAndLimits() {
        var draft = RestoreDraft(backup: BackupVolume(volumeID: "local:backup/vzdump-qemu-100.vma.zst"), source: vm)
        draft.bandwidthLimit = 12.5
        draft.name = "restored"
        draft.cores = 4
        draft.sockets = 2
        draft.memoryMiB = 4096
        draft.unprivileged = true
        draft.liveRestore = true
        draft.startAfterRestore = true
        draft.isHAManaged = true
        #expect(draft.problems.isEmpty)
        // Live restore needs a Proxmox Backup Server; containers have no sockets or privilege level for VMs.
        #expect(PVE.restore(draft).parameters.formEncoded == "vmid=100&archive=local%3Abackup%2Fvzdump-qemu-100.vma.zst&force=1&start=1&ha-managed=1&bwlimit=12800&name=restored&cores=4&sockets=2&memory=4096")

        var pbs = RestoreDraft(backup: BackupVolume(volumeID: "pbs:backup/vm/100/2026-10-21T15:08:47Z", format: "pbs-vm"), source: vm)
        pbs.liveRestore = true
        pbs.startAfterRestore = true
        pbs.bandwidthLimit = 0
        #expect(pbs.backup.isOnBackupServer)
        #expect(pbs.parameters["live-restore"] == .bool(true))
        #expect(pbs.parameters["start"] == nil)
        #expect(pbs.parameters["bwlimit"] == .int(0))

        var ct = RestoreDraft(backup: BackupVolume(volumeID: "local:backup/vzdump-lxc-202.tar.zst"), source: container)
        ct.storage = "local-lvm"
        ct.name = "web 2"
        ct.sockets = 2
        ct.unprivileged = false
        #expect(ct.problems.keys.sorted() == ["hostname"])
        ct.name = "web-2"
        #expect(ct.parameters.formEncoded == "vmid=202&ostemplate=local%3Abackup%2Fvzdump-lxc-202.tar.zst&restore=1&force=1&storage=local-lvm&hostname=web-2&unprivileged=0")
    }
}
