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
        #expect(request.parameters.formEncoded == "vmid=202&storage=local&mode=snapshot&compress=zstd&remove=0&notes-template=%7B%7Bguestname%7D%7D&protected=1")
        draft.notes = "  "
        draft.compression = .none
        draft.mode = .stop
        #expect(PVE.backupNow(draft).parameters.formEncoded == "vmid=202&storage=local&mode=stop&compress=0&remove=0&protected=1")
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
}
