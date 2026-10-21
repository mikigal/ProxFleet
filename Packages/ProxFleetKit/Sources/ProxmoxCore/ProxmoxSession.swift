import Foundation

/// An authenticated connection to one Proxmox API endpoint.
///
/// Handles the ticket lifecycle the same way the web UI does: the ticket goes in a cookie, writes carry the
/// CSRF token, and the ticket is renewed in the background well before its two-hour lifetime ends.
public actor ProxmoxSession {
    public nonisolated let address: ServerAddress
    public nonisolated let product: ProxmoxProduct
    private let transport: any HTTPTransport
    nonisolated let transportForWebSockets: (any WebSocketTransport)?
    private let now: @Sendable () -> Date

    public private(set) var ticket: AuthTicket?
    private var renewal: Task<AuthTicket, any Error>?

    /// Renew once the ticket is older than this. The web UI uses the same interval.
    public static let renewalInterval: TimeInterval = 15 * 60

    public init(
        address: ServerAddress,
        product: ProxmoxProduct = .virtualEnvironment,
        transport: any HTTPTransport,
        ticket: AuthTicket? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.address = address
        self.product = product
        self.transport = transport
        self.transportForWebSockets = transport as? any WebSocketTransport
        self.ticket = ticket
        self.now = now
    }

    // MARK: - Authentication

    /// First login step. `username` may already contain the realm (`root@pam`), in which case `realm` is ignored.
    public func login(username: String, password: String, realm: String?) async throws -> LoginOutcome {
        var parameters: APIParameters = ["username": .string(username), "password": .string(password), "new-format": true]
        if !username.contains("@"), let realm, !realm.isEmpty {
            parameters["realm"] = .string(realm)
        }
        let response: TicketResponse = try await perform(APIRequest(.post, "/access/ticket", parameters: parameters), authenticated: false)

        if let challenge = SecondFactorChallenge.parse(ticket: response.ticket, username: response.username, product: product) {
            ticket = nil
            return .needsSecondFactor(challenge)
        }
        let ticket = try makeTicket(from: response)
        self.ticket = ticket
        return .authenticated(ticket)
    }

    /// Second login step, after `login` returned `.needsSecondFactor`.
    public func completeLogin(_ challenge: SecondFactorChallenge, method: SecondFactorMethod, code: String) async throws -> AuthTicket {
        let parameters: APIParameters = [
            "username": .string(challenge.username),
            "tfa-challenge": .string(challenge.partialTicket),
            "password": .string("\(method.rawValue):\(code.trimmingCharacters(in: .whitespacesAndNewlines))"),
            "new-format": true,
        ]
        let response: TicketResponse = try await perform(APIRequest(.post, "/access/ticket", parameters: parameters), authenticated: false)
        let ticket = try makeTicket(from: response)
        self.ticket = ticket
        return ticket
    }

    /// Reuses a ticket saved earlier, for example after the app was relaunched.
    public func restore(_ ticket: AuthTicket) {
        self.ticket = ticket
    }

    public func logout() {
        renewal?.cancel()
        renewal = nil
        ticket = nil
    }

    /// Renews the ticket now. Concurrent callers share one renewal request.
    @discardableResult
    public func renewTicket() async throws -> AuthTicket {
        if let renewal { return try await renewal.value }
        guard let current = ticket else { throw ProxmoxError.notAuthenticated }

        let task = Task<AuthTicket, any Error> {
            let parameters: APIParameters = ["username": .string(current.username), "password": .string(current.ticket)]
            let response: TicketResponse = try await self.perform(APIRequest(.post, "/access/ticket", parameters: parameters), authenticated: false)
            return try self.makeTicket(from: response)
        }
        renewal = task
        defer { renewal = nil }
        do {
            let renewed = try await task.value
            ticket = renewed
            return renewed
        } catch ProxmoxError.unauthorized(let message) {
            ticket = nil
            throw ProxmoxError.unauthorized(message)
        }
    }

    // MARK: - Requests

    /// Sends an authenticated API request, renewing the ticket first when it is due.
    public func send<Response>(_ request: APIRequest<Response>) async throws -> Response {
        guard let current = ticket else { throw ProxmoxError.notAuthenticated }
        if current.isExpired(at: now()) {
            ticket = nil
            throw ProxmoxError.unauthorized("Session expired.")
        }
        if now().timeIntervalSince(current.issuedAt) > Self.renewalInterval {
            // A failed renewal is not fatal while the current ticket is still valid.
            do {
                try await renewTicket()
            } catch ProxmoxError.unauthorized(let message) {
                throw ProxmoxError.unauthorized(message)
            } catch {}
        }
        do {
            return try await perform(request, authenticated: true)
        } catch ProxmoxError.unauthorized(let message) {
            ticket = nil
            throw ProxmoxError.unauthorized(message)
        }
    }

    /// Sends a request that does not need a ticket, such as listing realms before login.
    public func sendUnauthenticated<Response>(_ request: APIRequest<Response>) async throws -> Response {
        try await perform(request, authenticated: false)
    }

    private func perform<Response>(_ request: APIRequest<Response>, authenticated: Bool) async throws -> Response {
        let httpRequest = try buildRequest(request, authenticated: authenticated)
        let response: HTTPResponse
        do {
            response = try await transport.send(httpRequest)
        } catch let error as ProxmoxError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProxmoxError.transport(error.localizedDescription)
        }
        return try ResponseDecoder.decode(Response.self, from: response)
    }

    func buildRequest<Response>(_ request: APIRequest<Response>, authenticated: Bool) throws -> HTTPRequest {
        let path = APIFormat.pathPrefix + (request.path.hasPrefix("/") ? request.path : "/" + request.path)
        guard var components = URLComponents(url: address.baseURL, resolvingAgainstBaseURL: false) else {
            throw ProxmoxError.invalidResponse("invalid address")
        }
        components.percentEncodedPath = path

        var headers = ["Accept": "application/json"]
        var body: Data?
        switch request.method {
        case .get, .delete:
            if !request.parameters.isEmpty {
                components.percentEncodedQuery = request.parameters.formEncoded
            }
        case .post, .put:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            body = Data(request.parameters.formEncoded.utf8)
        }

        if authenticated {
            guard let ticket else { throw ProxmoxError.notAuthenticated }
            headers["Cookie"] = "\(product.authCookieName)=\(APIParameters.escape(ticket.ticket))"
            if request.method != .get {
                headers["CSRFPreventionToken"] = ticket.csrfToken
            }
        }

        guard let url = components.url else { throw ProxmoxError.invalidResponse("invalid path \(request.path)") }
        return HTTPRequest(method: request.method, url: url, headers: headers, body: body)
    }

    private func makeTicket(from response: TicketResponse) throws -> AuthTicket {
        guard let csrf = response.csrfToken else {
            throw ProxmoxError.invalidResponse("ticket without CSRF token")
        }
        return AuthTicket(username: response.username, ticket: response.ticket, csrfToken: csrf, issuedAt: now(), clusterName: response.clusterName)
    }
}
