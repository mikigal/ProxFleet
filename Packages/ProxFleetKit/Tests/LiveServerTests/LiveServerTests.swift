import CryptoKit
import Foundation
import ProxmoxCore
import ProxmoxURLSession
import ProxmoxConsole
import PVEKit
import Testing

/// Settings from the env file named by `PROXFLEET_TEST_SERVER_ENV` (see `Config/TestServer.example.env`).
/// Without it, every test in this file is skipped.
private struct LiveServer {
    var values: [String: String]

    static let current: LiveServer? = {
        guard let path = ProcessInfo.processInfo.environment["PROXFLEET_TEST_SERVER_ENV"],
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return LiveServer(values: values)
    }()

    var address: ServerAddress { ServerAddress(parsing: values["ADDRESS"] ?? "", defaultPort: 8006)! }

    subscript(key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
}

@Suite(.enabled(if: LiveServer.current != nil, "Set PROXFLEET_TEST_SERVER_ENV to run against a real server"), .serialized, .timeLimit(.minutes(1)))
struct LiveServerTests {
    private let server = LiveServer.current!

    /// Accepts the certificate the way a user would, and returns a session using it.
    private func trustedSession() async throws -> ProxmoxSession {
        let transport = URLSessionTransport()
        let probe = ProxmoxSession(address: server.address, transport: transport)
        do {
            _ = try await probe.sendUnauthenticated(ProxmoxAccess.realms())
        } catch ProxmoxError.untrustedCertificate(let certificate) {
            if let expected = server["FINGERPRINT"] {
                #expect(certificate.sha256Fingerprint == expected.uppercased())
            }
            transport.pin(certificate.sha256Fingerprint)
        }
        return ProxmoxSession(address: server.address, transport: transport)
    }

    @Test func selfSignedCertificateIsRejectedUntilPinned() async throws {
        let session = ProxmoxSession(address: server.address, transport: URLSessionTransport())
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.sendUnauthenticated(ProxmoxAccess.realms())
        }
        let realms = try await trustedSession().sendUnauthenticated(ProxmoxAccess.realms())
        #expect(realms.contains { $0.realm == "pam" })
    }

    @Test func passwordLoginRenewalAndSnapshot() async throws {
        let session = try await trustedSession()
        let outcome = try await session.login(username: try #require(server["USER"]), password: try #require(server["PASSWORD"]), realm: server["REALM"])
        guard case .authenticated(let ticket) = outcome else {
            Issue.record("expected a full ticket")
            return
        }
        #expect(ticket.username.contains("@"))

        // Tickets carry a timestamp in seconds, so a renewal in the same second may return the same ticket.
        let renewed = try await session.renewTicket()
        #expect(renewed.username == ticket.username)
        #expect(!renewed.csrfToken.isEmpty)

        let snapshot = try await session.fetchClusterSnapshot()
        #expect(!snapshot.nodes.isEmpty)
        #expect(snapshot.nodes.allSatisfy { $0.cpuCount > 0 })
        let version = try await session.send(PVE.version())
        #expect(!version.version.isEmpty)
    }

    @Test func wrongPasswordIsUnauthorized() async throws {
        let session = try await trustedSession()
        await #expect(throws: ProxmoxError.unauthorized("authentication failure")) {
            _ = try await session.login(username: try #require(server["USER"]), password: "not-the-password", realm: server["REALM"])
        }
    }

    @Test func apiErrorsCarryMessagesAndFieldErrors() async throws {
        let session = try await trustedSession()
        _ = try await session.login(username: try #require(server["USER"]), password: try #require(server["PASSWORD"]), realm: server["REALM"])
        let node = try #require(try await session.fetchClusterSnapshot().nodes.first?.name)

        do {
            _ = try await session.send(APIRequest<Nothing>(.get, "/nodes/\(node)/qemu/99999/status/current"))
            Issue.record("expected an error")
        } catch ProxmoxError.api(let status, let message, _) {
            #expect(status == 500)
            #expect(message?.contains("does not exist") == true)
        }

        do {
            _ = try await session.send(APIRequest<Nothing>(.put, "/nodes/\(node)/qemu/99999/config", parameters: ["memory": "abc"]))
            Issue.record("expected an error")
        } catch ProxmoxError.api(let status, _, let fieldErrors) {
            #expect(status == 400)
            #expect(fieldErrors["memory"] != nil)
        }
    }

    /// Pauses and resumes VM 102 from the seed script, and checks that a failing task reports its message.
    @Test func powerActionTasks() async throws {
        let session = try await trustedSession()
        _ = try await session.login(username: try #require(server["USER"]), password: try #require(server["PASSWORD"]), realm: server["REALM"])
        let node = try #require(try await session.fetchClusterSnapshot().nodes.first?.name)
        let vm = GuestReference(node: node, vmid: 102, kind: .virtualMachine)
        try #require(try await session.send(PVE.guestStatus(vm)).powerState == .running)

        func finish(_ upid: String) async throws -> TaskStatus {
            for _ in 0..<60 {
                let status = try await session.send(PVE.taskStatus(node: node, upid: upid))
                if !status.isRunning { return status }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw ProxmoxError.invalidResponse("task did not finish")
        }

        #expect(try await finish(try await session.send(PVE.powerAction(.pause, on: vm))).succeeded)
        #expect(try await session.send(PVE.guestStatus(vm)).powerState == .paused)
        #expect(try await finish(try await session.send(PVE.powerAction(.resume, on: vm))).succeeded)
        #expect(try await session.send(PVE.guestStatus(vm)).powerState == .running)

        let failed = try await finish(try await session.send(PVE.powerAction(.start, on: vm)))
        #expect(!failed.succeeded)
        #expect(failed.exitStatus == "VM 102 already running")

        let config = try await session.send(PVE.guestConfig(vm))
        #expect(config.name == "db-server")
        #expect(!config.disks.isEmpty)
        let history = try await session.send(PVE.guestRRD(vm, timeframe: .hour))
        #expect(!history.isEmpty)
        #expect(try await session.privileges(on: vm.aclPath).contains("VM.PowerMgmt"))
    }

    private func rootSession() async throws -> (ProxmoxSession, String) {
        let session = try await trustedSession()
        _ = try await session.login(username: try #require(server["USER"]), password: try #require(server["PASSWORD"]), realm: server["REALM"])
        let node = try #require(try await session.fetchClusterSnapshot().nodes.first?.name)
        return (session, node)
    }

    /// Container 200 from the seed script shows a login prompt on its console after Enter.
    @Test func containerTerminal() async throws {
        let (session, node) = try await rootSession()
        let terminal = try await TerminalConnection.open(.container(GuestReference(node: node, vmid: 200, kind: .container)), session: session)
        defer { terminal.close() }
        try await terminal.resize(columns: 80, rows: 24)
        try await Task.sleep(for: .seconds(1))
        try await terminal.send("\r")

        var text = ""
        for try await chunk in terminal.output {
            text += String(decoding: chunk, as: UTF8.self)
            if text.contains("login:") { break }
        }
        #expect(text.contains("login:"), "terminal output: \(text.suffix(300))")
    }

    @Test func nodeShell() async throws {
        let (session, node) = try await rootSession()
        let terminal = try await TerminalConnection.open(.node(node), session: session)
        defer { terminal.close() }
        try await terminal.resize(columns: 100, rows: 30)
        try await terminal.send("hostname; echo shell-$((6*7))\n")
        var text = ""
        let deadline = Date().addingTimeInterval(15)
        for try await chunk in terminal.output {
            text += String(decoding: chunk, as: UTF8.self)
            if text.contains("shell-42") || Date() > deadline { break }
        }
        #expect(text.contains("shell-42"), "shell output: \(text.suffix(300))")
    }

    /// VM 100 boots the Alpine ISO (see README). Connects, waits for a screen and types into it.
    @Test func vmConsole() async throws {
        let (session, node) = try await rootSession()
        let vm = GuestReference(node: node, vmid: 100, kind: .virtualMachine)
        try #require(try await session.send(PVE.guestStatus(vm)).powerState == .running)

        let client = try await VNCClient.open(vm, session: session)
        var updates = 0
        var sawPixels = false
        for try await event in client.events {
            if case .updated = event {
                updates += 1
                let framebuffer = await client.framebuffer
                sawPixels = framebuffer.pixels.contains { $0 != 0 }
                if updates == 1 {
                    await client.type("root\n")
                }
                if sawPixels && updates >= 2 { break }
            }
        }
        let framebuffer = await client.framebuffer
        print("VNC screen \(framebuffer.width)x\(framebuffer.height), name \(await client.name), updates \(updates)")
        #expect(framebuffer.width > 0 && framebuffer.height > 0)
        #expect(sawPixels)
        await client.close()
    }

    @Test(.enabled(if: LiveServer.current?["LIMITED_USER"] != nil))
    func readOnlyUserLacksPowerManagement() async throws {
        let session = try await trustedSession()
        _ = try await session.login(username: try #require(server["LIMITED_USER"]), password: try #require(server["LIMITED_PASSWORD"]), realm: server["LIMITED_REALM"])
        let privileges = try await session.privileges(on: "/vms/100")
        #expect(privileges.contains("VM.Audit"))
        #expect(!privileges.contains("VM.PowerMgmt"))
    }

    @Test(.enabled(if: LiveServer.current?["TFA_TOTP_SECRET"] != nil))
    func totpSecondFactor() async throws {
        let session = try await trustedSession()
        let outcome = try await session.login(username: try #require(server["TFA_USER"]), password: try #require(server["TFA_PASSWORD"]), realm: server["TFA_REALM"])
        guard case .needsSecondFactor(let challenge) = outcome else {
            Issue.record("expected a second factor challenge")
            return
        }
        #expect(challenge.supportedMethods.contains(.totp))

        await #expect(throws: ProxmoxError.self) {
            _ = try await session.completeLogin(challenge, method: .totp, code: "000000")
        }
        let code = try TOTP.code(secret: try #require(server["TFA_TOTP_SECRET"]))
        let ticket = try await session.completeLogin(challenge, method: .totp, code: code)
        #expect(ticket.username.hasPrefix(server["TFA_USER"]! + "@"))
        _ = try await session.fetchClusterSnapshot()
    }
}

enum TOTP {
    static func code(secret: String, at date: Date = Date()) throws -> String {
        let key = SymmetricKey(data: try base32Decode(secret))
        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        let offset = Int(digest[19] & 0x0F)
        let value = (UInt32(digest[offset] & 0x7F) << 24) | (UInt32(digest[offset + 1]) << 16) | (UInt32(digest[offset + 2]) << 8) | UInt32(digest[offset + 3])
        return String(format: "%06u", value % 1_000_000)
    }

    private static func base32Decode(_ text: String) throws -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var buffer: UInt32 = 0
        var bytes: [UInt8] = []
        for character in text.uppercased() where character != "=" {
            guard let index = alphabet.firstIndex(of: character) else { throw ProxmoxError.invalidResponse("bad base32") }
            buffer = (buffer << 5) | UInt32(index)
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return Data(bytes)
    }
}
