import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct HighAvailabilityTests {
    /// `GET /cluster/ha/status/current` of the test cluster on PVE 9.2 with two resources.
    private let statusJSON = #"""
    [{"node": "pve-claude", "quorate": 1, "type": "quorum", "id": "quorum", "status": "OK"}, {"timestamp": 1792754627, "status": "test3 (active, Fri Oct 23 13:23:47 2026)", "id": "master", "node": "test3", "type": "master"}, {"armed-state": "armed", "type": "fencing", "node": "test3", "id": "fencing", "status": "armed (CRM watchdog active)"}, {"status": "pve-claude (active, watchdog active, Fri Oct 23 13:23:51 2026)", "timestamp": 1792754631, "id": "lrm:pve-claude", "type": "lrm", "node": "pve-claude"}, {"id": "lrm:test2", "timestamp": 1792754630, "status": "test2 (idle, watchdog standby, Fri Oct 23 13:23:50 2026)", "node": "test2", "type": "lrm"}, {"auto-rebalance": 1, "type": "service", "node": "pve-claude", "sid": "ct:202", "id": "service:ct:202", "max_relocate": 1, "crm_state": "stopped", "max_restart": 1, "failback": 1, "state": "stopped", "request_state": "stopped", "status": "ct:202 (pve-claude, stopped)"}, {"status": "vm:231 (pve-claude, started)", "request_state": "started", "state": "started", "comment": "probe", "max_restart": 2, "failback": 1, "crm_state": "started", "max_relocate": 1, "sid": "vm:231", "id": "service:vm:231", "node": "pve-claude", "type": "service", "auto-rebalance": 1}]
    """#
    private let resourcesJSON = #"[{"type": "ct", "sid": "ct:202", "digest": "56736a48", "state": "stopped"}, {"comment": "probe", "state": "started", "sid": "vm:231", "max_restart": 2, "type": "vm", "digest": "56736a48"}]"#
    private let rulesJSON = #"[{"strict": 0, "comment": "prefer", "affinity": "positive", "resources": "vm:231", "order": 1, "type": "node-affinity", "nodes": "pve-claude:2,test2", "digest": "f610a736", "rule": "pf-node"}, {"order": 2, "type": "resource-affinity", "digest": "f610a736", "rule": "pf-res", "affinity": "negative", "resources": "ct:202,vm:231", "disable": 1, "errors": {"resources": ["rule defines more resources than available nodes"]}}]"#

    @Test func decodesStatusAsRecordedFromPVE92() throws {
        let status = try JSONDecoder().decode([HAStatusEntry].self, from: Data(statusJSON.utf8))
        #expect(status.map(\.kind) == [.quorum, .master, .fencing, .lrm, .lrm, .service, .service])
        #expect(status[0].isQuorate == true && status[2].armedState == "armed" && status[1].node == "test3")
        #expect(status[6].sid == "vm:231" && status[6].state == "started" && status[6].requestedState == "started" && status[6].node == "pve-claude")
    }

    @Test func decodesResourcesWithDefaults() throws {
        let resources = try JSONDecoder().decode([HAResource].self, from: Data(resourcesJSON.utf8))
        #expect(resources[0].sid == "ct:202" && resources[0].kind == .container && resources[0].vmid == 202 && resources[0].state == "stopped")
        #expect(resources[0].maxRestart == 1 && resources[0].maxRelocate == 1 && resources[0].failback && resources[0].autoRebalance)
        #expect(resources[1].maxRestart == 2 && resources[1].comment == "probe" && resources[1].kind == .virtualMachine)
        #expect(HAResource.sid(for: 200, kind: .container) == "ct:200")
    }

    @Test func decodesRules() throws {
        let rules = try JSONDecoder().decode([HARule].self, from: Data(rulesJSON.utf8))
        #expect(rules[0].kind == .nodeAffinity && rules[0].resources == ["vm:231"] && !rules[0].isStrict && rules[0].isEnabled)
        #expect(rules[0].nodes.map(\.name) == ["pve-claude", "test2"] && rules[0].nodes.map(\.priority) == [2, nil])
        #expect(rules[1].kind == .resourceAffinity && rules[1].affinity == "negative" && !rules[1].isEnabled)
        #expect(rules[1].errors == ["resources": ["rule defines more resources than available nodes"]])
    }

    @Test func resourceDraftLeavesDefaultsOut() throws {
        var draft = HAResourceDraft(guest: 100, kind: .virtualMachine)
        #expect(draft.problems.isEmpty)
        #expect(PVE.createHAResource(draft).parameters.formEncoded == "sid=vm%3A100&state=started")
        draft.maxRestart = "3"
        draft.failback = false
        draft.comment = " db "
        #expect(PVE.createHAResource(draft).parameters.formEncoded == "sid=vm%3A100&comment=db&failback=0&max_restart=3&state=started")

        let resource = try #require(try JSONDecoder().decode([HAResource].self, from: Data(resourcesJSON.utf8)).last)
        let original = HAResourceDraft(resource)
        var edited = original
        edited.maxRestart = "1"
        edited.comment = ""
        edited.state = "disabled"
        let update = edited.changes(from: original)
        #expect(update.values == ["state": "disabled"] && update.deletions == ["max_restart", "comment"])
        #expect(PVE.updateHAResource("vm:231", update).path == "/cluster/ha/resources/vm:231")

        draft.maxRelocate = "11"
        #expect(draft.problems["max_relocate"] != nil)
        #expect(HAResourceDraft(guest: 0, kind: .container).problems["sid"] != nil)
    }

    @Test func ruleDrafts() throws {
        var node = HARuleDraft(kind: .nodeAffinity)
        #expect(Set(node.problems.keys) == ["resources", "nodes"])
        node.resources = ["vm:231", "ct:202"]
        node.nodes = ["test2": nil, "pve-claude": 2]
        node.isStrict = true
        #expect(node.problems.isEmpty)
        #expect(PVE.createHARule(node, id: "r1").parameters.formEncoded == "rule=r1&type=node-affinity&nodes=pve-claude%3A2%2Ctest2&resources=ct%3A202%2Cvm%3A231&strict=1")

        var together = HARuleDraft(kind: .resourceAffinity)
        together.resources = ["vm:231"]
        #expect(together.problems["resources"] != nil)
        together.resources.insert("ct:202")
        together.affinity = "negative"
        #expect(PVE.createHARule(together, id: "r2").parameters.formEncoded == "rule=r2&type=resource-affinity&affinity=negative&resources=ct%3A202%2Cvm%3A231")

        let rule = try #require(try JSONDecoder().decode([HARule].self, from: Data(rulesJSON.utf8)).first)
        let original = HARuleDraft(rule)
        var edited = original
        edited.isEnabled = false
        edited.comment = ""
        edited.affinity = "negative"
        let update = edited.changes(from: original)
        #expect(update.values == ["disable": "1", "affinity": "negative"] && update.deletions == ["comment"])
        // The type goes with every change.
        #expect(PVE.updateHARule("pf-node", kind: .nodeAffinity, update).parameters["type"] == .string("node-affinity"))
        #expect(HARuleDraft.newID().hasPrefix("ha-rule-") && HARuleDraft.newID().count == 21)
    }

    @Test func nodeRuleDefaultsAreDeleted() {
        var original = HARuleDraft(kind: .nodeAffinity)
        original.resources = ["vm:231"]
        original.nodes = ["pve-claude": nil]
        original.isStrict = true
        original.affinity = "negative"
        var edited = original
        edited.isStrict = false
        edited.affinity = "positive"
        let update = edited.changes(from: original)
        #expect(update.values.isEmpty && update.deletions == ["strict", "affinity"])
    }

    @Test func moveResultsAndRequests() throws {
        let blocked = #"{"blocking-resources": [{"cause": "node-affinity", "sid": "vm:231"}], "sid": "vm:231", "requested-node": "test3"}"#
        let result = try JSONDecoder().decode(HAMoveResult.self, from: Data(blocked.utf8))
        #expect(result.blockingResources == [.init(sid: "vm:231", cause: "node-affinity")] && result.movedAlong.isEmpty)
        #expect(PVE.moveHAResource("vm:231", to: "test2").path == "/cluster/ha/resources/vm:231/migrate")
        #expect(PVE.moveHAResource("vm:231", to: "test2", relocate: true).path == "/cluster/ha/resources/vm:231/relocate")
        #expect(PVE.deleteHAResource("vm:231").parameters.formEncoded == "")
        #expect(PVE.deleteHAResource("vm:231", purge: false).parameters.formEncoded == "purge=0")
        #expect(PVE.disarmHA(resourceMode: "freeze").parameters.formEncoded == "resource-mode=freeze")
        #expect(TaskDescription.title(type: "hamigrate", objectID: "231") == "HA 231 – Migrate")
    }
}
