import DemoServer
import Foundation
import ProxmoxCore
@testable import PVEKit
import Testing

struct ClusterSnapshotTests {
    // Shapes follow the PVE API documentation. Replace with fixtures recorded from the test server.
    private static let status = #"""
    [{"type":"cluster","id":"cluster","name":"lab","nodes":2,"quorate":1,"version":4},
     {"type":"node","id":"node/b","name":"b","ip":"10.0.0.2","online":1,"local":0,"nodeid":2,"level":""},
     {"type":"node","id":"node/a","name":"a","ip":"10.0.0.1","online":1,"local":1,"nodeid":1,"level":""}]
    """#

    private static let resources = #"""
    [{"id":"node/a","type":"node","node":"a","status":"online","cpu":0.25,"maxcpu":8,"mem":4294967296,"maxmem":17179869184,"uptime":3600},
     {"id":"node/b","type":"node","node":"b","status":"online","cpu":"0.5","maxcpu":"4","mem":1073741824,"maxmem":8589934592,"uptime":60},
     {"id":"qemu/101","type":"qemu","vmid":101,"name":"web","node":"a","status":"running","cpu":0.1,"maxcpu":2,"mem":536870912,"maxmem":2147483648,"maxdisk":34359738368,"tags":"prod;web","template":0,"uptime":100},
     {"id":"lxc/100","type":"lxc","vmid":"100","name":"dns","node":"b","status":"stopped","maxcpu":1,"maxmem":536870912},
     {"id":"qemu/9000","type":"qemu","vmid":9000,"name":"tpl","node":"a","status":"stopped","template":1},
     {"id":"storage/a/local","type":"storage","storage":"local","node":"a","status":"available","plugintype":"dir","content":"iso,backup","shared":0,"disk":10,"maxdisk":100},
     {"id":"pool/prod","type":"pool","pool":"prod"},
     {"id":"sdn/a/localnetwork","type":"sdn","sdn":"localnetwork","node":"a","status":"ok"}]
    """#

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func combinesStatusAndResources() throws {
        let snapshot = ClusterSnapshot(
            status: try decode([ClusterStatusEntry].self, Self.status),
            resources: try decode([ClusterResource].self, Self.resources),
            fetchedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(snapshot.topology == .cluster(name: "lab", quorate: true))
        #expect(snapshot.clusterName == "lab")
        #expect(snapshot.nodes.map(\.name) == ["a", "b"])
        #expect(snapshot.nodes[0].ip == "10.0.0.1")
        #expect(snapshot.nodes[0].isLocal)
        #expect(snapshot.nodes[1].cpuUsage == 0.5)
        #expect(snapshot.nodes[1].cpuCount == 4)

        #expect(snapshot.guests.map(\.vmid) == [100, 101, 9000])
        let web = try #require(snapshot.guests.first { $0.vmid == 101 })
        #expect(web.kind == .virtualMachine)
        #expect(web.state == .running)
        #expect(web.tags == ["prod", "web"])
        #expect(web.memoryTotal == 2_147_483_648)
        #expect(snapshot.containers.map(\.name) == ["dns"])
        #expect(snapshot.guests.first { $0.vmid == 9000 }?.isTemplate == true)

        #expect(snapshot.storages.map(\.id) == ["storage/a/local"])
        #expect(snapshot.storages[0].content == ["iso", "backup"])
    }

    @Test func standaloneNodeHasNoClusterEntry() throws {
        let status = #"[{"type":"node","id":"node/pve","name":"pve","ip":"192.168.1.2","online":1,"local":1,"nodeid":0,"level":""}]"#
        let resources = #"[{"id":"node/pve","type":"node","node":"pve","status":"online","maxcpu":4}]"#
        let snapshot = ClusterSnapshot(status: try decode([ClusterStatusEntry].self, status), resources: try decode([ClusterResource].self, resources), fetchedAt: Date())
        #expect(snapshot.topology == .standalone)
        #expect(snapshot.clusterName == nil)
        #expect(snapshot.nodes.count == 1)
    }

    @Test func unknownResourceTypesAreIgnored() throws {
        let resources = #"[{"id":"future/1","type":"future-thing"}]"#
        let decoded = try decode([ClusterResource].self, resources)
        #expect(decoded[0].type == .other("future-thing"))
        let snapshot = ClusterSnapshot(status: [], resources: decoded, fetchedAt: Date())
        #expect(snapshot.guests.isEmpty && snapshot.nodes.isEmpty && snapshot.storages.isEmpty)
    }

    @Test func tagsAcceptAllSeparators() {
        #expect(GuestSummary.parseTags("a;b,c d") == ["a", "b", "c", "d"])
        #expect(GuestSummary.parseTags(nil) == [])
    }

    @Test func demoServerProducesConsistentSnapshot() async throws {
        let session = ProxmoxSession(address: ServerAddress(host: "demo", port: 8006), transport: DemoTransport(cluster: .homelab))
        _ = try await session.login(username: "root", password: "demo", realm: "pam")
        let snapshot = try await session.fetchClusterSnapshot()

        #expect(snapshot.topology == .cluster(name: "homelab", quorate: true))
        #expect(snapshot.nodes.count == 3)
        #expect(snapshot.nodes.filter(\.isOnline).count == 2)
        #expect(snapshot.virtualMachines.count == 7)
        #expect(snapshot.containers.count == 4)
        #expect(snapshot.guests.first { $0.vmid == 105 }?.state == .unknown) // on the offline node
        // local and local-lvm on each node, plus the shared NFS, PBS and ESXi storages.
        #expect(snapshot.storages.count == 15)
        let nas = snapshot.storages.filter { $0.name == "nas" }
        #expect(nas.count == 3 && nas.allSatisfy(\.isShared))
    }

    @Test func demoServerRequiresSecondFactorForTFAUsers() async throws {
        let session = ProxmoxSession(address: ServerAddress(host: "demo", port: 8006), transport: DemoTransport())
        let outcome = try await session.login(username: "tfa-user", password: "demo", realm: "pve")
        guard case .needsSecondFactor(let challenge) = outcome else {
            Issue.record("expected challenge")
            return
        }
        #expect(challenge.supportedMethods == [.totp, .recovery])
        await #expect(throws: ProxmoxError.unauthorized("authentication failure")) {
            try await session.completeLogin(challenge, method: .totp, code: "000000")
        }
        let ticket = try await session.completeLogin(challenge, method: .totp, code: DemoTransport.totpCode)
        #expect(ticket.username == "tfa-user@pve")
        #expect(ticket.clusterName == "homelab")
    }
}
