import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

/// How the app adapts to older Proxmox VE releases, with answers recorded from a PVE 8.4 node.
struct ServerFeatureTests {
    private func version(_ text: String) -> PVEVersion { PVEVersion(version: text) }

    @Test func parsesAndComparesVersions() {
        #expect(PVEVersionNumber(parsing: "8.4.0") == PVEVersionNumber(8, 4, 0))
        #expect(PVEVersionNumber(parsing: "9.2.21") == PVEVersionNumber(9, 2, 21))
        #expect(PVEVersionNumber(parsing: "8.4") == PVEVersionNumber(8, 4))
        #expect(PVEVersionNumber(parsing: "9.0.0~11") == PVEVersionNumber(9, 0, 0))
        #expect(PVEVersionNumber(parsing: "unknown") == nil)
        #expect(PVEVersionNumber(8, 4, 17) < PVEVersionNumber(9, 0) && PVEVersionNumber(9, 1, 9) < PVEVersionNumber(9, 2))
    }

    @Test func featuresFollowTheRelease() {
        let pve84 = version("8.4.0")
        #expect(pve84.supports(.notifications) && pve84.supports(.directoryMappings))
        #expect(!pve84.supports(.haRules) && !pve84.supports(.sdnFabrics) && !pve84.supports(.datacenterBulkActions))
        let pve91 = version("9.1.4")
        #expect(pve91.supports(.haRules) && pve91.supports(.datacenterBulkActions) && !pve91.supports(.haArming))
        #expect(version("9.2.21").supports(.haArming))
        // Unknown versions get everything, as before the app knew about versions.
        #expect(version("unknown").supports(.sdnRouteFilters))
    }

    @Test func cephReleasesWithoutTheReleaseList() {
        #expect(CephRelease.fallback(for: PVEVersionNumber(8, 2)).map(\.name) == ["quincy", "reef"])
        let pve84 = CephRelease.fallback(for: PVEVersionNumber(8, 4))
        #expect(pve84.map(\.name) == ["quincy", "reef", "squid"] && pve84.first(where: \.isDefault)?.name == "reef")
        #expect(CephRelease.fallback(for: PVEVersionNumber(8, 3)).last?.isUnsupported == true)
        #expect(CephRelease.fallback(for: PVEVersionNumber(9, 0)).map(\.name) == ["squid"])
    }

    /// `/cluster/resources` of a PVE 8.4 node: SDN zones have `type` `sdn` and no `network-type`.
    @Test func sdnZonesOfOlderServers() throws {
        let json = #"[{"node": "pve4-8", "type": "sdn", "id": "sdn/pve4-8/localnetwork", "status": "ok", "sdn": "localnetwork"}, {"node": "pve4-8", "type": "node", "id": "node/pve4-8", "status": "online"}]"#
        let networks = try JSONDecoder().decode([SDNNodeNetwork].self, from: Data(json.utf8)).filter { $0.kind != nil }
        #expect(networks.count == 1 && networks[0].kind == .zone && networks[0].isLocalNetwork && networks[0].status == "ok")
    }

    /// PVE 8 answers HA migrations with `null`.
    @Test func haMoveOfOlderServers() {
        #expect(HAMoveResult.self is any NullDecodable.Type)
        #expect(HAMoveResult.nullValue.blockingResources.isEmpty && HAMoveResult.nullValue.movedAlong.isEmpty)
    }

    @Test func bulkActionWorkersOfOlderServers() {
        var migrate = NodeBulkActionDraft(action: .migrate, vmids: [100])
        migrate.target = "pve2"
        migrate.maxWorkers = 2
        #expect(PVE.bulkAction(node: "pve1", migrate).parameters["max-workers"] == .int(2))
        let legacy = PVE.bulkAction(node: "pve1", migrate, legacyWorkers: true).parameters
        #expect(legacy["maxworkers"] == .int(2) && legacy["max-workers"] == nil)
        var start = NodeBulkActionDraft(action: .start, vmids: [100])
        start.maxWorkers = 4
        let legacyStart = PVE.bulkAction(node: "pve1", start, legacyWorkers: true).parameters
        #expect(legacyStart["max-workers"] == nil && legacyStart["maxworkers"] == nil)
    }

    @Test func noConntrackStateBeforePVE9() throws {
        let json = #"{"running": 1, "allowed_nodes": ["pve2"], "local_disks": [], "local_resources": [], "not_allowed_nodes": {}}"#
        var draft = MigrationDraft(guest: GuestReference(node: "pve1", vmid: 100, kind: .virtualMachine), target: "pve2")
        draft.preconditions = try JSONDecoder().decode(MigrationPreconditions.self, from: Data(json.utf8))
        #expect(draft.notes.contains { $0.text.contains("conntrack") })
        draft.offersConntrackState = false
        #expect(!draft.notes.contains { $0.text.contains("conntrack") } && !draft.showsConntrackState)
        #expect(draft.parameters["with-conntrack-state"] == nil)
    }

    @Test func agentFreezeKeyOfOlderServers() {
        var draft = VMOptionsDraft(GuestConfig(values: ["agent": "1,freeze-fs-on-backup=0"]))
        #expect(!draft.agentFreezeFS)
        draft.agentFreezeKey = "freeze-fs-on-backup"
        #expect(draft.serialized()["agent"] == "enabled=1,freeze-fs-on-backup=0")
        draft.agentFreezeKey = "freeze-fs"
        #expect(draft.serialized()["agent"] == "enabled=1,freeze-fs=0")
    }

    @Test func efiDiskWithoutMicrosoftCertificateRecord() {
        #expect(GuestConfig.efiDiskValue(storage: "local-lvm", preEnrolledKeys: true).contains("ms-cert=2023k"))
        #expect(GuestConfig.efiDiskValue(storage: "local-lvm", preEnrolledKeys: true, microsoft2023Certificates: false)
            == "local-lvm:1,efitype=4m,pre-enrolled-keys=1")
    }
}
