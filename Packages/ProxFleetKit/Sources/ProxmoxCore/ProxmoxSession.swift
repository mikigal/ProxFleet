import Foundation

/// An authenticated connection to one Proxmox API endpoint.
///
/// Handles the ticket lifecycle the same way the web UI does: the ticket goes in a cookie, writes carry the
/// CSRF token, and the ticket is renewed in the background well before its two-hour lifetime ends.
public actor ProxmoxSession {
    public nonisolated let address: ServerAddress
    public nonisolated let product: ProxmoxProduct
    let transport: any HTTPTransport
    nonisolated let transportForWebSockets: (any WebSocketTransport)?
    private let now: @Sendable () -> Date

    public private(set) var ticket: AuthTicket? {
        didSet { if ticket != nil { ticketWasDropped = false } }
    }
    /// Whether the last ticket expired or was rejected, as opposed to nobody having signed in.
    private var ticketWasDropped = false
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
        var parameters: APIParameters
        switch product {
        case .virtualEnvironment:
            parameters = ["username": .string(username), "password": .string(password), "new-format": true]
            if !username.contains("@"), let realm, !realm.isEmpty {
                parameters["realm"] = .string(realm)
            }
        case .backupServer:
            // Proxmox Backup Server takes neither `realm` nor `new-format`; the user ID must name the realm.
            var userID = username
            if !username.contains("@"), let realm, !realm.isEmpty {
                userID += "@\(realm)"
            }
            parameters = ["username": .string(userID), "password": .string(password)]
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
        var parameters: APIParameters = [
            "username": .string(challenge.username),
            "tfa-challenge": .string(challenge.partialTicket),
            "password": .string("\(method.rawValue):\(code.trimmingCharacters(in: .whitespacesAndNewlines))"),
        ]
        if product == .virtualEnvironment { parameters["new-format"] = true }
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
        ticketWasDropped = false
    }

    /// Renews the ticket now. Concurrent callers share one renewal request.
    @discardableResult
    public func renewTicket() async throws -> AuthTicket {
        if let renewal { return try await renewal.value }
        let current = try requireTicket()

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
            dropTicket()
            throw ProxmoxError.unauthorized(message)
        }
    }

    /// Forgets a ticket that expired or that the server rejected.
    private func dropTicket() {
        ticket = nil
        ticketWasDropped = true
    }

    /// The ticket for an authenticated request. Requests sent together with the one that found the ticket expired
    /// fail the same way, so callers sign in again instead of reporting that nobody signed in.
    private func requireTicket() throws -> AuthTicket {
        guard let ticket else { throw ticketWasDropped ? ProxmoxError.unauthorized("Session expired.") : ProxmoxError.notAuthenticated }
        return ticket
    }

    // MARK: - Requests

    /// Sends an authenticated API request, renewing the ticket first when it is due.
    public func send<Response>(_ request: APIRequest<Response>) async throws -> Response {
        try await prepareAuthenticatedRequest()
        do {
            return try await perform(request, authenticated: true)
        } catch ProxmoxError.unauthorized(let message) {
            dropTicket()
            throw ProxmoxError.unauthorized(message)
        }
    }

    /// Checks the ticket before an authenticated request and renews it when it is due.
    func prepareAuthenticatedRequest() async throws {
        let current = try requireTicket()
        if current.isExpired(at: now()) {
            dropTicket()
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
    }

    /// Sends a request that does not need a ticket, such as listing realms before login.
    public func sendUnauthenticated<Response>(_ request: APIRequest<Response>) async throws -> Response {
        try await perform(request, authenticated: false)
    }

    /// Fetches a file the web interface serves outside the API, such as the API schema. No login is sent.
    public func fetchStaticFile(_ path: String) async throws -> Data {
        guard var components = URLComponents(url: address.baseURL, resolvingAgainstBaseURL: false) else {
            throw ProxmoxError.invalidResponse("invalid address")
        }
        components.percentEncodedPath = path
        guard let url = components.url else { throw ProxmoxError.invalidResponse("invalid path \(path)") }
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(method: .get, url: url))
        } catch let error as ProxmoxError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProxmoxError.transport(error.localizedDescription)
        }
        guard response.statusCode == 200 else {
            throw ProxmoxError.api(status: response.statusCode, message: "HTTP \(response.statusCode)", fieldErrors: [:])
        }
        return response.body
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

    func buildRequest<Response>(_ request: APIRequest<Response>, authenticated: Bool, pathPrefix: String = APIFormat.pathPrefix) throws -> HTTPRequest {
        let path = pathPrefix + (request.path.hasPrefix("/") ? request.path : "/" + request.path)
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
            let ticket = try requireTicket()
            headers["Cookie"] = "\(product.authCookieName)=\(APIParameters.escape(ticket.ticket))"
            if request.method != .get {
                headers["CSRFPreventionToken"] = ticket.csrfToken
            }
        }

        guard let url = components.url else { throw ProxmoxError.invalidResponse("invalid path \(request.path)") }
        return HTTPRequest(method: request.method, url: url, headers: headers, body: body, timeout: request.timeout)
    }

    private func makeTicket(from response: TicketResponse) throws -> AuthTicket {
        guard let csrf = response.csrfToken else {
            throw ProxmoxError.invalidResponse("ticket without CSRF token")
        }
        return AuthTicket(username: response.username, ticket: response.ticket, csrfToken: csrf, issuedAt: now(), clusterName: response.clusterName)
    }
}
