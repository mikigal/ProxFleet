import Foundation
@testable import ProxmoxCore
import Synchronization
import Testing

struct UPIDFormatTests {
    @Test func readsProxmoxVETasks() throws {
        let upid = try #require(UPID("UPID:pve-claude:00002EE8:0004758A:6AD7F7F0:qmpause:102:root@pam:"))
        #expect(upid.node == "pve-claude")
        #expect(upid.type == "qmpause")
        #expect(upid.objectID == "102")
        #expect(upid.user == "root@pam")
        #expect(upid.startTime == Date(timeIntervalSince1970: 0x6AD7F7F0))
    }

    @Test func readsBackupServerTasksWithTheirTaskNumber() throws {
        // Recorded on Proxmox Backup Server 4.2.
        let upid = try #require(UPID(#"UPID:pbs-claude:000002CB:00000218:00000009:6ADCBCA1:verificationjob:store1\x3apf\x2dverify:root@pam:"#))
        #expect(upid.node == "pbs-claude")
        #expect(upid.type == "verificationjob")
        #expect(upid.objectID == "store1:pf-verify")
        #expect(upid.user == "root@pam")
        #expect(upid.startTime == Date(timeIntervalSince1970: 0x6ADCBCA1))
    }

    @Test(arguments: [
        (#"store1\x3act-200"#, "store1:ct/200"),
        (#"store1\x3ahost-nested\x2dhost-6ADCBC72"#, "store1:host/nested-host/6ADCBC72"),
        (#"\x2d\x3astore1\x3astore2\x3a\x3apf\x2dsync\x2dlocal"#, "-:store1:store2::pf-sync-local"),
        ("store1", "store1"),
        ("", ""),
    ])
    func unescapesTaskIDsLikeSystemd(escaped: String, plain: String) {
        #expect(UPID.unescape(escaped) == plain)
    }

    @Test func backupServerTasksWithoutIDAndWithTokens() throws {
        let logrotate = try #require(UPID("UPID:pbs-claude:000002CB:00000218:00000000:6ADC79A8:logrotate::root@pam:"))
        #expect(logrotate.type == "logrotate")
        #expect(logrotate.objectID.isEmpty)
        let token = try #require(UPID(#"UPID:pbs-claude:000002CB:00000218:0000001A:6ADCBD00:backup:store1\x3ahost-pbs\x2dclaude:root@pam!seed:"#))
        #expect(token.user == "root@pam!seed")
        #expect(token.objectID == "store1:host/pbs-claude")
    }

    @Test func rejectsOtherText() {
        #expect(UPID("not a upid") == nil)
        #expect(UPID("UPID:node:1:2:zz:type:id:user:") == nil)
    }
}

struct ProductDetectionTests {
    private let address = ServerAddress(host: "backup.lan", port: 8007)

    @Test func backupServerAnswersPing() async throws {
        let transport = MockTransport { _ in .json(#"{"data":{"pong":true},"status":200,"success":true}"#) }
        let session = ProxmoxSession(address: address, transport: transport)
        #expect(try await session.detectProduct() == .backupServer)
        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://backup.lan:8007/api2/extjs/ping")
        #expect(request.headers["Cookie"] == nil)
    }

    @Test func virtualEnvironmentRefusesItWithoutTicket() async throws {
        let transport = MockTransport { _ in HTTPResponse(statusCode: 401, body: Data()) }
        let session = ProxmoxSession(address: address, transport: transport)
        #expect(try await session.detectProduct() == .virtualEnvironment)
    }

    @Test func otherFailuresAreThrown() async {
        let certificate = CertificateDetails(sha256Fingerprint: "AB:CD")
        let transport = MockTransport { _ in throw ProxmoxError.untrustedCertificate(certificate) }
        let session = ProxmoxSession(address: address, transport: transport)
        await #expect(throws: ProxmoxError.untrustedCertificate(certificate)) {
            try await session.detectProduct()
        }
    }
}

struct BackupServerSessionTests {
    private let address = ServerAddress(host: "backup.lan", port: 8007)

    @Test func signsInAndSendsTheBackupServerCookie() async throws {
        let transport = MockTransport { request in
            if request.url.path.hasSuffix("/access/ticket") {
                return .json(#"{"data":{"username":"root@pam","ticket":"PBS:root@pam:6ADCB870::sig","CSRFPreventionToken":"6ADCB870:csrf"},"success":true}"#)
            }
            return .json(#"{"data":[],"success":true}"#)
        }
        let session = ProxmoxSession(address: address, product: .backupServer, transport: transport)
        guard case .authenticated = try await session.login(username: "root", password: "secret", realm: "pam") else {
            Issue.record("expected a full ticket")
            return
        }
        // Proxmox Backup Server refuses `realm` and `new-format`; the realm goes into the user ID.
        #expect(transport.requests.first?.parameters == ["username": "root@pam", "password": "secret"])

        _ = try await session.send(APIRequest<[String]>(.post, "/admin/datastore/store1/gc"))
        let request = try #require(transport.requests.last)
        #expect(request.headers["Cookie"] == "PBSAuthCookie=PBS%3Aroot%40pam%3A6ADCB870%3A%3Asig")
        #expect(request.headers["CSRFPreventionToken"] == "6ADCB870:csrf")
    }

    @Test func readsBackupServerSecondFactorChallenges() throws {
        let json = #"{"totp":true,"recovery":"unavailable"}"#
        let encoded = try #require(json.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let challenge = try #require(SecondFactorChallenge.parse(ticket: "PBS:!tfa!\(encoded):6ADCB870::sig", username: "tfa@pbs", product: .backupServer))
        #expect(challenge.totp)
        #expect(challenge.supportedMethods.contains(.totp))
        #expect(SecondFactorChallenge.parse(ticket: "PBS:tfa@pbs:6ADCB870::sig", username: "tfa@pbs", product: .backupServer) == nil)
    }

    @Test func secondFactorIsSentWithoutNewFormat() async throws {
        let transport = MockTransport { _ in
            .json(#"{"data":{"username":"tfa@pbs","ticket":"PBS:tfa@pbs:6ADCB870::sig","CSRFPreventionToken":"6ADCB870:csrf"},"success":true}"#)
        }
        let session = ProxmoxSession(address: address, product: .backupServer, transport: transport)
        let challenge = SecondFactorChallenge(partialTicket: "PBS:!tfa!x:6ADCB870::sig", username: "tfa@pbs", totp: true)
        _ = try await session.completeLogin(challenge, method: .totp, code: " 123456 ")
        #expect(transport.requests.first?.parameters == ["username": "tfa@pbs", "tfa-challenge": "PBS:!tfa!x:6ADCB870::sig", "password": "totp:123456"])
    }
}

/// Serves downloads from memory, writing each body to a file as a real transport would.
private final class DownloadTransport: FileDownloadTransport {
    typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse

    private let handler: Handler
    private let recorded = Mutex<[HTTPRequest]>([])

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [HTTPRequest] { recorded.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.withLock { $0.append(request) }
        return handler(request)
    }

    func download(_ request: HTTPRequest, into directory: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> HTTPDownload {
        let response = try await send(request)
        let file = directory.appending(path: "download-\(UUID().uuidString)")
        try response.body.write(to: file)
        progress(Int64(response.body.count), Int64(response.body.count))
        return HTTPDownload(statusCode: response.statusCode, headers: response.headers, file: file)
    }
}

struct DownloadTests {
    private let address = ServerAddress(host: "backup.lan", port: 8007)
    private let ticket = AuthTicket(username: "root@pam", ticket: "PBS:root@pam:6ADCB870::sig", csrfToken: "csrf", issuedAt: Date())

    private func session(_ transport: some HTTPTransport) -> ProxmoxSession {
        ProxmoxSession(address: address, product: .backupServer, transport: transport, ticket: ticket)
    }

    @Test func writesTheFileThroughThePlainJSONFormat() async throws {
        let transport = DownloadTransport { _ in HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: Data("pbs-claude\n".utf8)) }
        let request = APIRequest<Nothing>(.get, "/admin/datastore/store1/pxar-file-download", parameters: ["filepath": "ZXRj"])
        let file = try await session(transport).download(request)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try String(contentsOf: file, encoding: .utf8) == "pbs-claude\n")
        let sent = try #require(transport.requests.first)
        #expect(sent.url.absoluteString == "https://backup.lan:8007/api2/json/admin/datastore/store1/pxar-file-download?filepath=ZXRj")
        #expect(sent.headers["Cookie"]?.hasPrefix("PBSAuthCookie=") == true)
        #expect(sent.headers["CSRFPreventionToken"] == nil)
    }

    @Test func errorsCarryTheServersMessageAndLeaveNoFile() async throws {
        // Proxmox Backup Server answers a missing file with 400 and the message as plain text.
        let directory = FileManager.default.temporaryDirectory.appending(path: "download-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = DownloadTransport { _ in HTTPResponse(statusCode: 400, body: Data(#"error opening '"nope"'"#.utf8)) }

        await #expect(throws: ProxmoxError.api(status: 400, message: #"error opening '"nope"'"#, fieldErrors: [:])) {
            try await session(transport).download(APIRequest(.get, "/admin/datastore/store1/pxar-file-download"), into: directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func anExpiredTicketSignsOut() async throws {
        let transport = DownloadTransport { _ in HTTPResponse(statusCode: 401, body: Data("authentication failed".utf8)) }
        let session = session(transport)
        await #expect(throws: ProxmoxError.unauthorized("authentication failed")) {
            try await session.download(APIRequest(.get, "/admin/datastore/store1/download-decoded"))
        }
        #expect(await session.ticket == nil)
    }

    @Test func transportsWithoutDownloadsAreRefused() async {
        let transport = MockTransport { _ in .json("{}") }
        await #expect(throws: ProxmoxError.self) {
            try await session(transport).download(APIRequest(.get, "/admin/datastore/store1/download-decoded"))
        }
    }
}
