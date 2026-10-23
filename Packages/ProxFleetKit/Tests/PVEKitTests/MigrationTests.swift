import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct MigrationTests {
    private let vm = GuestReference(node: "pve-claude", vmid: 100, kind: .virtualMachine)
    private let container = GuestReference(node: "pve-claude", vmid: 200, kind: .container)

    /// VM 100 of the test cluster on PVE 9.2: running, with a disk on local-lvm and an ISO on local.
    private let vmJSON = #"""
    {"not_allowed_nodes": {"test2": {}, "test3": {}}, "local_disks": [{"is_vmstate": 0, "cdrom": 0, "volid": "local-lvm:vm-100-disk-0", "is_cloudinit": 0, "is_tpmstate": 0, "drivename": "scsi0", "is_attached": 1, "size": 4294967296, "shared": 0, "replicate": 1, "is_unused": 0}, {"volid": "local:iso/alpine-virt-3.24.2-x86_64.iso", "is_vmstate": 0, "cdrom": 1, "is_tpmstate": 0, "is_cloudinit": 0, "replicate": 1, "shared": 0, "drivename": "ide2", "size": 69206016, "is_attached": 1, "is_unused": 0}], "mapped-resources": [], "local_resources": [], "running": 1, "mapped-resource-info": {}, "has-dbus-vmstate": 1, "allowed_nodes": ["test3", "test2"]}
    """#

    private func preconditions(_ json: String) throws -> MigrationPreconditions {
        try JSONDecoder().decode(MigrationPreconditions.self, from: Data(json.utf8))
    }

    private func draft(_ guest: GuestReference, _ preconditions: MigrationPreconditions, target: String = "test2", conntrack: Bool = true) -> MigrationDraft {
        var draft = MigrationDraft(guest: guest, target: target)
        draft.preconditions = preconditions
        draft.targetSupportsConntrackState = conntrack
        return draft
    }

    @Test func decodesVMPreconditionsAsRecordedFromPVE92() throws {
        let decoded = try preconditions(vmJSON)
        #expect(decoded.isRunning && decoded.supportsConntrackState)
        #expect(decoded.allowedNodes == ["test3", "test2"] && decoded.restrictions["test2"] == .init())
        #expect(decoded.localDisks.map(\.volumeID) == ["local-lvm:vm-100-disk-0", "local:iso/alpine-virt-3.24.2-x86_64.iso"])
        #expect(decoded.localDisks[0].size == 4_294_967_296 && !decoded.localDisks[0].isCDROM && decoded.localDisks[1].isCDROM)
    }

    @Test func decodesContainerPreconditionsWithTheirOwnKeys() throws {
        let json = #"{"allowed-nodes": ["test3", "test2"], "running": 1, "not-allowed-nodes": {"test3": {"blocking-ha-resources": [{"sid": "ct:201", "cause": "resource-affinity"}]}}, "dependent-ha-resources": ["vm:102"]}"#
        let decoded = try preconditions(json)
        #expect(decoded.isRunning && decoded.allowedNodes == ["test3", "test2"] && decoded.localDisks.isEmpty)
        #expect(decoded.restrictions["test3"]?.blockingHAResources == [.init(sid: "ct:201", cause: "resource-affinity")])
        #expect(decoded.dependentHAResources == ["vm:102"])
    }

    @Test func localISOBlocksAndLocalDisksWarn() throws {
        let draft = draft(vm, try preconditions(vmJSON))
        #expect(draft.mode == .online && draft.showsTargetStorage && draft.showsConntrackState)
        #expect(draft.notes.map(\.severity) == [.error, .warning])
        #expect(draft.notes[0].text.contains("local CD/DVD") && draft.notes[1].text.contains("local-lvm:vm-100-disk-0 (4 GB)"))
        #expect(!draft.canMigrate)
    }

    @Test func runningVMMovesLiveWithItsDisks() {
        let preconditions = MigrationPreconditions(
            isRunning: true, localDisks: [.init(volumeID: "local-lvm:vm-102-disk-0", size: 1 << 30)], supportsConntrackState: true
        )
        var draft = draft(GuestReference(node: "pve-claude", vmid: 102, kind: .virtualMachine), preconditions)
        #expect(draft.canMigrate)
        #expect(draft.parameters.formEncoded == "target=test2&online=1&with-local-disks=1&with-conntrack-state=1")
        draft.targetStorage = "local-lvm"
        draft.withConntrackState = false
        #expect(draft.parameters.formEncoded == "target=test2&online=1&with-local-disks=1&targetstorage=local-lvm")
        #expect(draft.notes.contains { $0.severity == .warning && $0.text.hasPrefix("Conntrack state migration disabled") })

        // A target without the dbus-vmstate helper cannot take the conntrack state.
        let old = self.draft(draft.guest, preconditions, conntrack: false)
        #expect(!old.showsConntrackState && old.parameters["with-conntrack-state"] == nil)
        #expect(old.notes.contains { $0.severity == .warning && $0.text.contains("target node lacks support") })
        #expect(old.canMigrate)
    }

    @Test func offlineVMNeedsItsStoragesOnTheTarget() {
        let preconditions = MigrationPreconditions(
            isRunning: false, allowedNodes: ["test3"], restrictions: ["test2": .init(unavailableStorages: ["tank"])],
            localDisks: [.init(volumeID: "tank:vm-101-disk-0", size: 1 << 30)]
        )
        var draft = draft(GuestReference(node: "pve-claude", vmid: 101, kind: .virtualMachine), preconditions)
        #expect(draft.mode == .offline && !draft.showsTargetStorage && !draft.showsConntrackState)
        #expect(draft.notes.first?.severity == .error && draft.notes.first?.text.contains("Storage (tank)") == true)
        #expect(!draft.canMigrate)
        draft.target = "test3"
        #expect(draft.canMigrate)
        // Offline migration copies local disks but never to another storage, as in the web interface.
        draft.targetStorage = "local-lvm"
        #expect(draft.parameters.formEncoded == "target=test3&with-local-disks=1")
    }

    @Test func hostDevicesBlockUnlessForcedOffline() {
        let stopped = MigrationPreconditions(isRunning: false, localResources: ["usb0", "hostpci0"], mappedResources: ["hostpci0": false])
        var draft = draft(vm, stopped)
        #expect(draft.blockingLocalResources == ["usb0"] && draft.showsForce)
        #expect(!draft.canMigrate)
        draft.force = true
        #expect(draft.canMigrate && draft.notes.map(\.severity) == [.warning])
        #expect(draft.parameters.formEncoded == "target=test2&force=1")

        // Running VMs cannot be forced, and mapped devices without live migration block them too.
        let running = MigrationPreconditions(isRunning: true, localResources: ["hostpci0"], mappedResources: ["hostpci0": false], supportsConntrackState: true)
        var live = self.draft(vm, running)
        live.force = true
        #expect(!live.showsForce && live.parameters["force"] == nil)
        #expect(live.notes.first?.text == "Cannot migrate a running VM with mapped devices: hostpci0.")
        let liveMappable = MigrationPreconditions(isRunning: true, localResources: ["hostpci0"], mappedResources: ["hostpci0": true], supportsConntrackState: true)
        #expect(self.draft(vm, liveMappable).canMigrate)
    }

    @Test func runningContainerRestartsAndHARulesApply() {
        let preconditions = MigrationPreconditions(
            isRunning: true, restrictions: ["test3": .init(blockingHAResources: [.init(sid: "ct:201", cause: "resource-affinity")])],
            dependentHAResources: ["vm:102"]
        )
        var draft = draft(container, preconditions)
        #expect(draft.mode == .restart && !draft.showsConntrackState && !draft.showsTargetStorage)
        #expect(draft.parameters.formEncoded == "target=test2&restart=1")
        #expect(draft.notes == [.init(.warning, "HA resource vm:102 has a positive affinity to the container and migrates to the target node too.")])
        draft.target = "test3"
        #expect(draft.notes.first == .init(.error, "Cannot migrate: HA resource ct:201 has a negative affinity to the container on the target node."))
        #expect(!draft.canMigrate)
        // Nothing to check before the preconditions are loaded, and the source is never a target.
        #expect(!MigrationDraft(guest: container, target: "test2").canMigrate)
        #expect(!self.draft(container, MigrationPreconditions(isRunning: false), target: "pve-claude").canMigrate)
    }

    @Test func migrationRequests() {
        let draft = draft(container, MigrationPreconditions(isRunning: false))
        let request = PVE.migrate(draft)
        #expect(request.method == .post && request.path == "/nodes/pve-claude/lxc/200/migrate" && request.parameters.formEncoded == "target=test2")
        #expect(PVE.migrationPreconditions(vm, target: "test2").path == "/nodes/pve-claude/qemu/100/migrate")
        #expect(PVE.migrationPreconditions(vm, target: "test2").parameters["target"] == .string("test2"))
        #expect(PVE.qemuMigrationCapabilities(node: "test2").path == "/nodes/test2/capabilities/qemu/migration")
        #expect(TaskDescription.title(type: "qmigrate", objectID: "100") == "VM 100 – Migrate")
        #expect(TaskDescription.title(type: "bulk-migrate", objectID: nil) == "Bulk Migrate")
    }

    @Test func bulkMigration() {
        var draft = NodeBulkActionDraft(action: .migrate, vmids: [202, 100])
        #expect(draft.maxWorkers == 1)
        draft.target = "test2"
        #expect(PVE.bulkAction(node: "pve-claude", draft).path == "/nodes/pve-claude/migrateall")
        #expect(PVE.bulkAction(node: "pve-claude", draft).parameters.formEncoded == "vms=100%2C202&max-workers=1&target=test2&with-local-disks=1")
        draft.withLocalDisks = false
        let cluster = PVE.clusterBulkAction(draft)
        #expect(cluster.path == "/cluster/bulk-action/guest/migrate")
        #expect(cluster.parameters.formEncoded == "vms=100&vms=202&max-workers=1&target=test2&online=1")
        // Other bulk actions keep the datacenter's default.
        #expect(NodeBulkActionDraft(action: .start, vmids: [100]).maxWorkers == nil)
    }
}
