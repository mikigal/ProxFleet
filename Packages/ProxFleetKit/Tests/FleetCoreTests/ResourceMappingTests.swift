import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct ResourceMappingTests {
    private func list() async throws -> ResourceMappingList {
        let transport = DemoTransport(cluster: .homelab)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: "root", realm: "pam"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        try #require(connection.state == .connected)
        return ResourceMappingList(connection: connection)
    }

    @Test func mappingLifecycle() async throws {
        let list = try await list()
        await list.load()
        #expect(list.mappings[.pci]?.map(\.id) == ["gpu-a2000", "igpu"])
        #expect(list.mappings[.dir]?.first?.nodes.count == 3)
        let node = try #require(list.checkedNode)

        let devices = await list.pciDevices(node: node)
        let gpu = try #require(devices.first { $0.id == "0000:01:00.0" })
        var draft = ResourceMappingDraft(kind: .pci)
        draft.id = "gpu2"
        #expect(draft.problems(isNew: true)["map"] != nil)
        draft.entries = [ResourceMappingDraft.pciEntry(gpu, node: node, allFunctions: true)]
        #expect(draft.entries[0].stringValue == "node=\(node),path=0000:01:00,id=10de:2571,subsystem-id=10de:1611,iommugroup=14")
        try await list.create(draft)
        let created = try #require(list.mappings[.pci]?.first { $0.id == "gpu2" })

        let usb = try #require(await list.usbDevices(node: node).first)
        var edited = ResourceMappingDraft(kind: .pci, created)
        let original = edited
        edited.description = "Second GPU"
        edited.liveMigration = true
        try await list.update(.pci, id: "gpu2", edited.changes(from: original), digest: created.digest)
        let changed = try #require(list.mappings[.pci]?.first { $0.id == "gpu2" })
        #expect(changed.description == "Second GPU" && changed.liveMigration)
        await #expect(throws: ConfigUpdateError.self) {
            try await list.update(.pci, id: "gpu2", ["description": "stale"], digest: created.digest)
        }

        var port = ResourceMappingDraft(kind: .usb)
        port.id = "ups"
        port.entries = [ResourceMappingDraft.usbEntry(usb, node: node, byPort: true)]
        try await list.create(port)
        #expect(list.mappings[.usb]?.first { $0.id == "ups" }?.entries.first?["path"] == usb.portID)

        try await list.delete(.pci, id: "gpu2")
        #expect(list.mappings[.pci]?.contains { $0.id == "gpu2" } == false)
    }
}
