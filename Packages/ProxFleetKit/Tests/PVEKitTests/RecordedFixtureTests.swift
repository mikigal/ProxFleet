import Foundation
import ProxmoxCore
@testable import PVEKit
import Testing

private struct FixtureEnvelope<T: Decodable>: Decodable {
    var data: T
}

/// Responses recorded from a real Proxmox VE 9.2 standalone node (`scripts/seed-test-server.py` contents).
struct RecordedFixtureTests {
    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/pve-9.2-standalone"))
        return try JSONDecoder().decode(FixtureEnvelope<T>.self, from: Data(contentsOf: url)).data
    }

    @Test func standaloneNodeSnapshot() throws {
        let snapshot = ClusterSnapshot(
            status: try fixture("cluster-status", as: [ClusterStatusEntry].self),
            resources: try fixture("cluster-resources", as: [ClusterResource].self),
            fetchedAt: Date()
        )

        #expect(snapshot.topology == .standalone)
        #expect(snapshot.nodes.count == 1)
        let node = try #require(snapshot.nodes.first)
        #expect(node.name == "pve-claude")
        #expect(node.isOnline)
        #expect(node.isLocal)
        #expect(node.ip == "10.10.100.150")
        #expect(node.cpuCount == 6)
        #expect(node.memoryTotal > 0)

        #expect(snapshot.virtualMachines.map(\.vmid) == [100, 101, 102, 9000])
        #expect(snapshot.containers.map(\.vmid) == [200, 201, 202])
        #expect(snapshot.guests.first { $0.vmid == 100 }?.tags == ["prod", "web"])
        #expect(snapshot.guests.first { $0.vmid == 9000 }?.isTemplate == true)
        #expect(snapshot.guests.first { $0.vmid == 202 }?.state == .stopped)
        #expect(snapshot.storages.map(\.name).sorted() == ["local", "local-lvm"])
    }

    @Test func versionAndRealms() throws {
        #expect(try fixture("version", as: PVEVersion.self).version.hasPrefix("9.2"))
        let realms = try fixture("access-domains", as: [Realm].self)
        #expect(Set(realms.map(\.realm)) == ["pam", "pve"])
        #expect(realms.allSatisfy { !$0.isDefault })
    }
}
