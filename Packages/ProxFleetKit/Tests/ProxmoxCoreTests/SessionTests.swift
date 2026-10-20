import Foundation
@testable import ProxmoxCore
import Testing

struct SessionTests {
    private let address = ServerAddress(host: "pve.lan", port: 8006)

    private static let ticketBody = #"{"data":{"username":"root@pam","ticket":"PVE:root@pam:6900AAAA::sig+/=","CSRFPreventionToken":"6900AAAA:csrf","clustername":"homelab","cap":{}},"success":1}"#

    @Test func loginSendsCredentialsAndStoresTicket() async throws {
        let transport = MockTransport { _ in .json(Self.ticketBody) }
        let session = ProxmoxSession(address: address, transport: transport)

        let outcome = try await session.login(username: "root", password: "secret", realm: "pam")

        guard case .authenticated(let ticket) = outcome else {
            Issue.record("expected full ticket")
            return
        }
        #expect(ticket.username == "root@pam")
        #expect(ticket.csrfToken == "6900AAAA:csrf")
        #expect(ticket.clusterName == "homelab")

        let request = try #require(transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://pve.lan:8006/api2/extjs/access/ticket")
        #expect(request.parameters == ["username": "root", "password": "secret", "realm": "pam", "new-format": "1"])
        #expect(request.headers["Cookie"] == nil)
    }

    @Test func realmIsOmittedWhenUsernameContainsIt() async throws {
        let transport = MockTransport { _ in .json(Self.ticketBody) }
        let session = ProxmoxSession(address: address, transport: transport)
        _ = try await session.login(username: "admin@pve", password: "x", realm: "pam")
        #expect(transport.requests.first?.parameters["realm"] == nil)
    }

    @Test func secondFactorChallengeIsParsedAndCompleted() async throws {
        let challengeJSON = #"{"totp":true,"recovery":"available","webauthn":{"challenge":"abc"}}"#
        let encoded = try #require(challengeJSON.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let partial = "PVE:!tfa!\(encoded):6900AAAA::sig"
        let transport = MockTransport { request in
            if request.parameters["tfa-challenge"] != nil {
                return .json(Self.ticketBody)
            }
            return .json(#"{"data":{"username":"root@pam","ticket":"\#(partial)","NeedTFA":1},"success":1}"#)
        }
        let session = ProxmoxSession(address: address, transport: transport)

        let outcome = try await session.login(username: "root", password: "secret", realm: "pam")
        guard case .needsSecondFactor(let challenge) = outcome else {
            Issue.record("expected a second factor challenge")
            return
        }
        #expect(challenge.totp)
        #expect(challenge.recovery)
        #expect(challenge.webAuthn)
        #expect(!challenge.yubico)
        #expect(challenge.supportedMethods == [.totp, .recovery])
        #expect(await session.ticket == nil)

        let ticket = try await session.completeLogin(challenge, method: .totp, code: " 123456 ")
        #expect(ticket.username == "root@pam")
        let second = try #require(transport.requests.last)
        #expect(second.parameters["password"] == "totp:123456")
        #expect(second.parameters["tfa-challenge"] == partial)
        #expect(second.parameters["username"] == "root@pam")
    }

    @Test func authenticatedRequestsCarryCookieAndCSRFOnlyForWrites() async throws {
        let transport = MockTransport { _ in .json(#"{"data":null,"success":1}"#) }
        let clock = TestClock()
        let session = ProxmoxSession(address: address, transport: transport, now: { clock.now })
        await session.restore(AuthTicket(username: "root@pam", ticket: "PVE:root@pam:1::a+b", csrfToken: "tok", issuedAt: clock.now))

        _ = try await session.send(APIRequest<Nothing>(.get, "/nodes", parameters: ["type": "vm"]))
        _ = try await session.send(APIRequest<Nothing>(.post, "/nodes/pve1/qemu/100/status/start"))

        let get = transport.requests[0]
        #expect(get.url.absoluteString == "https://pve.lan:8006/api2/extjs/nodes?type=vm")
        #expect(get.headers["Cookie"] == "PVEAuthCookie=PVE%3Aroot%40pam%3A1%3A%3Aa%2Bb")
        #expect(get.headers["CSRFPreventionToken"] == nil)
        #expect(get.body == nil)

        let post = transport.requests[1]
        #expect(post.headers["CSRFPreventionToken"] == "tok")
        #expect(post.headers["Content-Type"] == "application/x-www-form-urlencoded")
    }

    @Test func renewsTicketWhenDueAndUsesTheNewOne() async throws {
        let transport = MockTransport { request in
            if request.url.path().hasSuffix("/access/ticket") {
                return .json(#"{"data":{"username":"root@pam","ticket":"NEW","CSRFPreventionToken":"newtok"},"success":1}"#)
            }
            return .json(#"{"data":null,"success":1}"#)
        }
        let clock = TestClock()
        let session = ProxmoxSession(address: address, transport: transport, now: { clock.now })
        await session.restore(AuthTicket(username: "root@pam", ticket: "OLD", csrfToken: "oldtok", issuedAt: clock.now))

        _ = try await session.send(APIRequest<Nothing>(.get, "/version"))
        #expect(transport.requests.count == 1)

        clock.advance(by: 16 * 60)
        _ = try await session.send(APIRequest<Nothing>(.get, "/version"))

        #expect(transport.requests.count == 3)
        let renewal = transport.requests[1]
        #expect(renewal.parameters == ["username": "root@pam", "password": "OLD"])
        #expect(transport.requests[2].headers["Cookie"] == "PVEAuthCookie=NEW")
        #expect(await session.ticket?.issuedAt == clock.now)
    }

    @Test func expiredTicketFailsWithoutNetwork() async throws {
        let transport = MockTransport { _ in .json(#"{"data":null,"success":1}"#) }
        let clock = TestClock()
        let session = ProxmoxSession(address: address, transport: transport, now: { clock.now })
        await session.restore(AuthTicket(username: "root@pam", ticket: "T", csrfToken: "c", issuedAt: clock.now))
        clock.advance(by: 2 * 60 * 60)

        await #expect(throws: ProxmoxError.unauthorized("Session expired.")) {
            try await session.send(APIRequest<Nothing>(.get, "/version"))
        }
        #expect(transport.requests.isEmpty)
        #expect(await session.ticket == nil)
    }

    @Test func unauthorizedResponseClearsTicket() async throws {
        let transport = MockTransport { _ in HTTPResponse(statusCode: 401, body: Data()) }
        let session = ProxmoxSession(address: address, transport: transport)
        await session.restore(AuthTicket(username: "root@pam", ticket: "T", csrfToken: "c", issuedAt: Date()))

        await #expect(throws: ProxmoxError.unauthorized(nil)) {
            try await session.send(APIRequest<Nothing>(.get, "/version"))
        }
        #expect(await session.ticket == nil)
    }

    @Test func requestsWithoutTicketAreRejectedLocally() async {
        let transport = MockTransport { _ in .json(#"{"data":null}"#) }
        let session = ProxmoxSession(address: address, transport: transport)
        await #expect(throws: ProxmoxError.notAuthenticated) {
            try await session.send(APIRequest<Nothing>(.get, "/version"))
        }
    }

    @Test func realmsCanBeListedBeforeLogin() async throws {
        let transport = MockTransport { _ in
            .json(#"{"data":[{"realm":"pam","type":"pam","comment":"Linux PAM standard authentication"},{"realm":"pve","type":"pve","comment":"Proxmox VE authentication server","default":1}],"success":1}"#)
        }
        let session = ProxmoxSession(address: address, transport: transport)
        let realms = try await session.sendUnauthenticated(ProxmoxAccess.realms())
        #expect(realms.map(\.realm) == ["pam", "pve"])
        #expect(realms[1].isDefault)
        #expect(realms[0].displayName == "Linux PAM standard authentication")
    }
}
