import DemoServer
import Foundation
@testable import ProxmoxConsole
import ProxmoxCore
import PVEKit
import Testing

/// The demo server's consoles, through the same clients the app uses.
struct DemoConsoleTests {
    private func session() async throws -> ProxmoxSession {
        let session = ProxmoxSession(address: ServerAddress(host: "demo", port: 8006), transport: DemoTransport(cluster: .homelab))
        _ = try await session.login(username: "root", password: "demo", realm: "pam")
        return session
    }

    @Test func containerTerminalRunsCommands() async throws {
        let terminal = try await TerminalConnection.open(.container(GuestReference(node: "pve1", vmid: 200, kind: .container)), session: try await session())
        defer { terminal.close() }
        var output = ""
        var iterator = terminal.output.makeAsyncIterator()
        while !output.contains("# ") { output += String(decoding: try #require(try await iterator.next()), as: UTF8.self) }
        #expect(output.contains("pihole"))

        try await terminal.send("hostname\r")
        output = ""
        while !output.contains("# ") { output += String(decoding: try #require(try await iterator.next()), as: UTF8.self) }
        #expect(output.contains("hostname\r\npihole\r\n"))
    }

    @Test func stoppedGuestHasNoConsole() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await TerminalConnection.open(.container(GuestReference(node: "pve2", vmid: 203, kind: .container)), session: try await session())
        }
    }

    @Test func vmConsoleShowsScreenAndReactsToKeys() async throws {
        let client = try await VNCClient.open(GuestReference(node: "pve1", vmid: 100, kind: .virtualMachine), session: try await session())
        var events = client.events.makeAsyncIterator()
        var updates = 0
        while updates == 0 {
            if case .updated = try #require(try await events.next()) { updates += 1 }
        }
        let first = await client.framebuffer
        #expect(first.width == 512)
        #expect(first.height == 384)
        #expect(first.pixels.contains { $0 > 100 }, "text is drawn")

        await client.type("root\r")
        while updates < 2 {
            if case .updated = try #require(try await events.next()) { updates += 1 }
        }
        #expect(await client.framebuffer.pixels != first.pixels)
        await client.close()
    }

    @Test func schemaIsServed() async throws {
        let schema = try await session().apiSchema()
        #expect(schema.vmConfig.contains { $0.name == "agent" && $0.properties?.isEmpty == false })
        #expect(schema.containerConfig.contains { $0.name == "features" })
    }
}
