import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// Live state of one saved server: its session, login state and latest cluster snapshot.
@MainActor
@Observable
public final class ServerConnection: Identifiable {
    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        /// No saved password, or the saved one was rejected.
        case needsPassword(message: String?)
        case needsSecondFactor(SecondFactorChallenge)
        /// `previouslyTrusted` is true when a different certificate was trusted before, which may mean
        /// the certificate was renewed, or that someone is intercepting the connection.
        case untrustedCertificate(CertificateDetails, previouslyTrusted: Bool)
        case connected
        case failed(String)
    }

    public private(set) var profile: ServerProfile
    public private(set) var state: State = .disconnected
    public private(set) var snapshot: ClusterSnapshot?
    /// Error of the most recent background refresh, while older data is still shown.
    public private(set) var refreshError: String?
    public private(set) var isRefreshing = false
    /// Message for the sign-in screens, e.g. a rejected second-factor code.
    public private(set) var signInError: String?

    public nonisolated let id: UUID
    private let environment: FleetEnvironment
    private let onProfileChange: @MainActor (ServerProfile) -> Void
    private var transport: any HTTPTransport
    private(set) var session: ProxmoxSession
    /// Tasks started from the app on this server.
    public let tasks: TaskCenter
    private var addressIndex = 0

    init(profile: ServerProfile, environment: FleetEnvironment, session: ProxmoxSession? = nil, transport: (any HTTPTransport)? = nil, onProfileChange: @escaping @MainActor (ServerProfile) -> Void) {
        self.id = profile.id
        self.profile = profile
        self.environment = environment
        self.onProfileChange = onProfileChange
        let transport = transport ?? environment.makeTransport(profile)
        self.transport = transport
        let address = profile.primaryAddress ?? ServerAddress(host: "invalid", port: profile.product.defaultPort)
        self.session = session ?? ProxmoxSession(address: address, product: profile.product, transport: transport, ticket: environment.credentials.ticket(for: profile.id))
        if session != nil { state = .connected }

        let owner = WeakReference<ServerConnection>()
        tasks = TaskCenter(
            fetchStatus: { upid in
                guard let connection = owner.value else { throw CancellationError() }
                return try await connection.session.send(PVE.taskStatus(node: upid.node, upid: upid.rawValue))
            },
            onFinish: { _ in await owner.value?.refresh() }
        )
        owner.value = self
    }

    public var currentAddress: ServerAddress { session.address }

    // MARK: - Connecting

    /// Loads data using the saved ticket or password. Does nothing when already connected.
    public func connect() async {
        switch state {
        case .connected, .connecting: return
        default: break
        }
        state = .connecting
        await establish()
    }

    /// Signs in with a password typed by the user.
    public func signIn(password: String, remember: Bool) async {
        state = .connecting
        signInError = nil
        environment.credentials.setPassword(remember ? password : nil, for: profile.id)
        await login(password: password)
    }

    public func submitSecondFactor(_ challenge: SecondFactorChallenge, method: SecondFactorMethod, code: String) async {
        state = .connecting
        signInError = nil
        do {
            let ticket = try await session.completeLogin(challenge, method: method, code: code)
            await didAuthenticate(ticket)
        } catch ProxmoxError.unauthorized {
            state = .needsSecondFactor(challenge)
            signInError = "The code was not accepted."
        } catch {
            handle(error)
        }
    }

    /// Accepts a certificate the user confirmed and connects again.
    public func trust(_ certificate: CertificateDetails) async {
        (transport as? any CertificatePinning)?.pin(certificate.sha256Fingerprint)
        if !profile.trustedFingerprints.contains(certificate.sha256Fingerprint) {
            profile.trustedFingerprints.append(certificate.sha256Fingerprint)
            onProfileChange(profile)
        }
        state = .connecting
        await establish()
    }

    public func cancelSignIn() {
        state = .disconnected
    }

    public func signOut() async {
        await session.logout()
        environment.credentials.setTicket(nil, for: profile.id)
        snapshot = nil
        state = .disconnected
    }

    func updateProfile(_ profile: ServerProfile) {
        self.profile = profile
    }

    private func establish() async {
        if await session.ticket != nil {
            do {
                try await loadSnapshot()
                state = .connected
                return
            } catch ProxmoxError.unauthorized {
                // Saved ticket expired; fall through to a password login.
            } catch {
                if await failOver(after: error) { return await establish() }
                handle(error)
                return
            }
        }
        guard let password = environment.credentials.password(for: profile.id) else {
            state = .needsPassword(message: nil)
            return
        }
        await login(password: password)
    }

    private func login(password: String) async {
        do {
            switch try await session.login(username: profile.username, password: password, realm: profile.realm) {
            case .authenticated(let ticket):
                await didAuthenticate(ticket)
            case .needsSecondFactor(let challenge):
                state = .needsSecondFactor(challenge)
            }
        } catch ProxmoxError.unauthorized {
            environment.credentials.setPassword(nil, for: profile.id)
            state = .needsPassword(message: "The user name or password was not accepted.")
        } catch {
            if await failOver(after: error) { return await login(password: password) }
            handle(error)
        }
    }

    private func didAuthenticate(_ ticket: AuthTicket) async {
        environment.credentials.setTicket(ticket, for: profile.id)
        refreshError = nil
        signInError = nil
        if let clusterName = ticket.clusterName, profile.clusterName != clusterName {
            profile.clusterName = clusterName
            onProfileChange(profile)
        }
        do {
            try await loadSnapshot()
            state = .connected
        } catch {
            handle(error)
        }
    }

    /// Moves to the next known address after a network failure. Tickets are valid on every node of a cluster.
    private func failOver(after error: any Error) async -> Bool {
        guard case ProxmoxError.transport = error, addressIndex + 1 < profile.addresses.count else { return false }
        addressIndex += 1
        let ticket = await session.ticket
        session = ProxmoxSession(address: profile.addresses[addressIndex], product: profile.product, transport: transport, ticket: ticket)
        return true
    }

    private func handle(_ error: any Error) {
        switch error {
        case ProxmoxError.untrustedCertificate(let details):
            state = .untrustedCertificate(details, previouslyTrusted: !profile.trustedFingerprints.isEmpty)
        case ProxmoxError.unauthorized:
            state = .needsPassword(message: "Your session has expired. Sign in again.")
        case is CancellationError:
            state = .disconnected
        default:
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Refreshing

    /// Reloads the snapshot. Errors keep the previous data and are reported in `refreshError`.
    public func refresh() async {
        guard state == .connected, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await loadSnapshot()
            refreshError = nil
        } catch ProxmoxError.unauthorized {
            state = .connecting
            await establish()
        } catch is CancellationError {
        } catch {
            if await failOver(after: error) {
                await refresh()
                return
            }
            refreshError = error.localizedDescription
        }
    }

    /// Refreshes periodically until the calling task is cancelled, e.g. when a view disappears.
    public func keepRefreshing(every interval: Duration = .seconds(5)) async {
        // Catch up right away when the data is older than one interval, e.g. after coming back from another screen.
        if let fetchedAt = snapshot?.fetchedAt, Date().timeIntervalSince(fetchedAt) > Double(interval.components.seconds) {
            await refresh()
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { break }
            await refresh()
        }
    }

    private func loadSnapshot() async throws {
        let snapshot = try await session.fetchClusterSnapshot()
        self.snapshot = snapshot
        // Servers added by address alone get a meaningful name once we know what they are.
        if profile.name == profile.primaryAddress?.host,
           let name = snapshot.clusterName ?? snapshot.nodes.first(where: \.isLocal)?.name {
            profile.name = name
            onProfileChange(profile)
        }
        if let ticket = await session.ticket {
            environment.credentials.setTicket(ticket, for: profile.id)
        }
    }

    /// Starts a power action and follows its task.
    /// - Parameter reportsFailure: false when the caller shows a failure itself.
    @discardableResult
    public func perform(_ action: PowerAction, on guest: GuestReference, reportsFailure: Bool = true) async throws -> TaskCenter.TrackedTask {
        let upid = try await session.send(PVE.powerAction(action, on: guest))
        return try tasks.track(upid, reportsFailure: reportsFailure)
    }

    /// Sends a request that starts a task, such as creating a guest, and follows the task.
    /// The caller shows the outcome; validation errors come back by parameter name.
    public func start(_ request: APIRequest<String>) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        do {
            return try tasks.track(try await session.send(request), reportsFailure: false)
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    /// The authenticated session, for features such as consoles that talk to the API directly.
    public var apiSession: ProxmoxSession { session }

    @ObservationIgnored private var schemaTask: Task<APISchema, any Error>?

    /// The server's API schema, loaded once per connection; it describes every configuration key.
    public func apiSchema() async throws -> APISchema {
        if let schemaTask { return try await schemaTask.value }
        let session = session
        let task = Task { try await session.apiSchema() }
        schemaTask = task
        do {
            return try await task.value
        } catch {
            schemaTask = nil
            throw error
        }
    }

    /// Direct API access for feature screens.
    public func send<Response>(_ request: APIRequest<Response>) async throws -> Response {
        try await session.send(request)
    }
}

@MainActor
final class WeakReference<Object: AnyObject> {
    weak var value: Object?
}
