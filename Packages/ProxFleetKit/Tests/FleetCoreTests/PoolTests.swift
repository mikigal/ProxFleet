import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct PoolTests {
    private func connection() async throws -> ServerConnection {
        let transport = DemoTransport(cluster: .homelab)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: "root", realm: "pam"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        try #require(connection.state == .connected)
        return connection
    }

    @Test func names() {
        #expect(ResourcePool.problem(forName: "prod") == nil)
        #expect(ResourcePool.problem(forName: "prod/web_1/a-b") == nil)
        #expect(ResourcePool.problem(forName: "1prod") != nil)
        #expect(ResourcePool.problem(forName: "a/b/c/d") != nil)
        #expect(ResourcePool.problem(forName: "a//b") != nil)
        #expect(ResourcePool.problem(forName: "a b") != nil)
    }

    @Test func poolLifecycle() async throws {
        let connection = try await connection()
        let list = PoolList(connection: connection)
        await list.load()
        #expect(list.pools?.map(\.id) == ["lab"])
        #expect(connection.snapshot?.guests.first { $0.vmid == 103 }?.pool == "lab")

        try await list.create("prod", comment: " Production ")
        try await list.create("prod/web", comment: "")
        await #expect(throws: ConfigUpdateError.self) { try await list.create("other/web", comment: "") }
        #expect(list.pools?.map(\.id) == ["lab", "prod", "prod/web"])
        #expect(list.pools?.first { $0.id == "prod" }?.comment == "Production")

        // 103 moves over from the lab pool.
        try await list.addMembers(to: "prod", guests: [100, 103], storages: ["local"])
        let detail = try #require(list.details["prod"])
        #expect(detail.guests.compactMap(\.vmid) == [100, 103])
        #expect(detail.storages == ["local"])
        #expect(connection.snapshot?.guests.first { $0.vmid == 103 }?.pool == "prod")
        await list.loadDetail("lab")
        #expect(list.details["lab"]?.guests.compactMap(\.vmid) == [105])

        await #expect(throws: ConfigUpdateError.self) { try await list.delete("prod") }
        try await list.removeMembers(from: "prod", guests: [100, 103], storages: ["local"])
        #expect(list.details["prod"]?.members.isEmpty == true)
        await #expect(throws: ConfigUpdateError.self) { try await list.delete("prod") }
        try await list.delete("prod/web")
        try await list.updateComment("prod", comment: "Gone soon")
        #expect(list.details["prod"]?.comment == "Gone soon")
        try await list.delete("prod")
        #expect(list.pools?.map(\.id) == ["lab"])
    }
}
