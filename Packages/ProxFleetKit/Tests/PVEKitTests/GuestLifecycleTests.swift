import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct GuestLifecycleTests {
    private let vm = GuestReference(node: "pve", vmid: 100, kind: .virtualMachine)
    private let container = GuestReference(node: "pve", vmid: 200, kind: .container)

    @Test func decodesSnapshotsAsRecordedFromPVE92() throws {
        let json = #"[{"snaptime": 1792585300, "description": "first snap\n", "name": "test1"}, {"running": 0, "parent": "test1", "digest": "6297", "description": "You are here!", "name": "current"}]"#
        let snapshots = try JSONDecoder().decode([GuestSnapshot].self, from: Data(json.utf8))
        #expect(snapshots[0].description == "first snap")
        #expect(snapshots[0].date == Date(timeIntervalSince1970: 1_792_585_300))
        #expect(snapshots[1].isCurrent && snapshots[1].parent == "test1")
    }

    @Test func snapshotTreePutsChildrenAfterParents() {
        let snapshots = [
            GuestSnapshot(name: "current", parent: "b"),
            GuestSnapshot(name: "c", date: Date(timeIntervalSince1970: 30), parent: "a"),
            GuestSnapshot(name: "b", date: Date(timeIntervalSince1970: 20), parent: "a"),
            GuestSnapshot(name: "a", date: Date(timeIntervalSince1970: 10)),
        ]
        let tree = GuestSnapshot.tree(snapshots).map { "\($0.snapshot.name):\($0.depth)" }
        #expect(tree == ["a:0", "b:1", "current:2", "c:1"])
        // Without snapshots there is only the current state.
        #expect(GuestSnapshot.tree([GuestSnapshot(name: "current")]).map(\.depth) == [0])
    }

    @Test func snapshotNames() {
        let existing = [GuestSnapshot(name: "before-upgrade")]
        #expect(GuestSnapshot.nameProblem("pre_update-2", existing: existing) == nil)
        #expect(GuestSnapshot.nameProblem("", existing: existing) != nil)
        #expect(GuestSnapshot.nameProblem("2fast", existing: existing) != nil)
        #expect(GuestSnapshot.nameProblem("with space", existing: existing) != nil)
        #expect(GuestSnapshot.nameProblem("before-upgrade", existing: existing) != nil)
        #expect(GuestSnapshot.nameProblem("current", existing: existing) != nil)
        #expect(GuestSnapshot.nameProblem(String(repeating: "a", count: 41), existing: existing) != nil)
    }

    @Test func snapshotRequests() {
        let create = PVE.createSnapshot(vm, name: "s1", description: " note \n", includeRAM: true)
        #expect(create.parameters.formEncoded == "snapname=s1&description=note&vmstate=1")
        // Containers have no memory state.
        #expect(PVE.createSnapshot(container, name: "s1", description: "", includeRAM: true).parameters.formEncoded == "snapname=s1")
        let rollback = PVE.rollbackSnapshot(vm, name: "s1", start: true)
        #expect(rollback.method == .post && rollback.path == "/nodes/pve/qemu/100/snapshot/s1/rollback")
        #expect(rollback.parameters["start"] == .bool(true))
        #expect(PVE.deleteSnapshot(container, name: "s1").path == "/nodes/pve/lxc/200/snapshot/s1")
        #expect(PVE.updateSnapshotDescription(vm, name: "s1", description: "x").method == .put)
    }

    @Test func cloneOfTemplateIsLinkedByDefault() {
        var draft = CloneDraft(source: vm, isTemplate: true, vmid: 120)
        draft.name = "web-02"
        draft.storage = "local-lvm"
        #expect(draft.problems.isEmpty)
        #expect(draft.parameters.formEncoded == "newid=120&name=web-02&full=0")
        draft.fullClone = true
        #expect(draft.parameters.formEncoded == "newid=120&name=web-02&full=1&storage=local-lvm")
    }

    @Test func cloneOfGuestCopiesAndCanStartFromSnapshot() {
        var draft = CloneDraft(source: container, isTemplate: false, vmid: 210)
        #expect(draft.fullClone)
        draft.name = "proxy-2"
        draft.targetNode = "pve2"
        draft.pool = "lab"
        draft.snapshot = "before-upgrade"
        let request = PVE.clone(draft)
        #expect(request.path == "/nodes/pve/lxc/200/clone")
        #expect(request.parameters.formEncoded == "newid=210&hostname=proxy-2&target=pve2&pool=lab&snapname=before-upgrade")
        draft.name = "bad name"
        draft.vmid = 5
        #expect(draft.problems.keys.sorted() == ["hostname", "newid"])
    }

    @Test func destroyAndTemplate() {
        #expect(PVE.destroy(vm, purge: true, destroyUnreferencedDisks: true).parameters.formEncoded == "purge=1&destroy-unreferenced-disks=1")
        let destroy = PVE.destroy(container, purge: false, destroyUnreferencedDisks: false)
        #expect(destroy.method == .delete && destroy.path == "/nodes/pve/lxc/200" && destroy.parameters.isEmpty)
        #expect(PVE.convertToTemplate(vm).path == "/nodes/pve/qemu/100/template")
    }
}
