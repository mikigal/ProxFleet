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
    /// Proxmox VE version of the node the app talks to, loaded with the first snapshot.
    public private(set) var version: PVEVersion?
    /// The state of a Proxmox Backup Server, which has no cluster snapshot.
    public internal(set) var backupServer: BackupServerSnapshot?
    /// Error of the most recent background refresh, while older data is still shown.
    public private(set) var refreshError: String?
    public private(set) var isRefreshing = false
    /// Message for the sign-in screens, e.g. a rejected second-factor code.
    public private(set) var signInError: String?

    public nonisolated let id: UUID
    private let environment: FleetEnvironment
    private let onProfileChange: @MainActor (ServerProfile) -> Void
    /// Nil for the demo, which does not count towards asking for a rating.
    private let reviewPrompt: ReviewPrompt?
    private var transport: any HTTPTransport
    private(set) var session: ProxmoxSession
    /// Tasks started from the app on this server.
    public let tasks: TaskCenter
    private var addressIndex = 0
    @ObservationIgnored private var connectAttempt: Task<Void, Never>?

    init(profile: ServerProfile, environment: FleetEnvironment, session: ProxmoxSession? = nil, transport: (any HTTPTransport)? = nil, reviewPrompt: ReviewPrompt?, onProfileChange: @escaping @MainActor (ServerProfile) -> Void) {
        self.id = profile.id
        self.profile = profile
        self.environment = environment
        self.onProfileChange = onProfileChange
        self.reviewPrompt = reviewPrompt
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
            onFinish: { task in
                if task.state == .succeeded { owner.value?.reviewPrompt?.recordSucceededTask() }
                await owner.value?.refresh()
            }
        )
        owner.value = self
        // A server added right after signing in starts connected.
        if state == .connected { reviewPrompt?.recordUse() }
    }

    public var currentAddress: ServerAddress { session.address }

    // MARK: - Connecting

    /// Loads data using the saved ticket or password. Does nothing when already connected.
    ///
    /// The attempt runs on its own and callers wait for it, also a second caller while it runs: a screen that
    /// appears twice in a row (as navigation sometimes does) would otherwise cancel the first attempt, which ends
    /// disconnected, while the second caller already returned because a connection was in progress.
    public func connect() async {
        if state == .connected { return }
        if let attempt = connectAttempt {
            await attempt.value
            return
        }
        // Signing in with a password or a trusted certificate is under way.
        if state == .connecting { return }
        state = .connecting
        let attempt = Task { await establish() }
        connectAttempt = attempt
        await attempt.value
        connectAttempt = nil
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

    /// Trusts a certificate the server itself reported over the trusted connection, for example after the
    /// node's certificate was replaced from the app, so the connection survives pveproxy's restart.
    public func trustFingerprint(_ fingerprint: String) {
        let fingerprint = fingerprint.uppercased()
        (transport as? any CertificatePinning)?.pin(fingerprint)
        if !profile.isDemo, !profile.trustedFingerprints.contains(fingerprint) {
            profile.trustedFingerprints.append(fingerprint)
            onProfileChange(profile)
        }
    }

    public func cancelSignIn() {
        state = .disconnected
    }

    public func signOut() async {
        await session.logout()
        environment.credentials.setTicket(nil, for: profile.id)
        snapshot = nil
        version = nil
        backupServer = nil
        state = .disconnected
    }

    func updateProfile(_ profile: ServerProfile) {
        self.profile = profile
    }

    private func establish() async {
        if await session.ticket != nil {
            do {
                try await loadSnapshot()
                didConnect()
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
            didConnect()
        } catch {
            handle(error)
        }
    }

    private func didConnect() {
        state = .connected
        reviewPrompt?.recordUse()
    }

    /// Moves to the next known address after a network failure. Tickets are valid on every node of a cluster.
    private func failOver(after error: any Error) async -> Bool {
        guard case ProxmoxError.transport = error, addressIndex + 1 < profile.addresses.count else { return false }
        addressIndex += 1
        // Nodes of a cluster can run different versions while it is upgraded.
        version = nil
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
        if let fetchedAt = snapshot?.fetchedAt ?? backupServer?.fetchedAt, Date().timeIntervalSince(fetchedAt) > Double(interval.components.seconds) {
            await refresh()
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { break }
            await refresh()
        }
    }

    private func loadSnapshot() async throws {
        let name: String?
        if isBackupServer {
            let backupServer = try await fetchBackupServerSnapshot(previous: backupServer)
            self.backupServer = backupServer
            name = backupServer.nodeName
        } else {
            let session = session
            let needsVersion = version == nil
            // Optional: without it, the app offers everything, as servers refuse what they lack anyway.
            async let loadedVersion = needsVersion ? try? await session.send(PVE.version()) : nil
            let snapshot = try await session.fetchClusterSnapshot()
            if let loadedVersion = await loadedVersion { version = loadedVersion }
            self.snapshot = snapshot
            name = snapshot.clusterName ?? snapshot.nodes.first(where: \.isLocal)?.name
        }
        // Servers added by address alone get a meaningful name once we know what they are.
        if profile.name == profile.primaryAddress?.host, let name {
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

    /// Runs a bulk action for guests on every node, as the datacenter's Bulk Actions do. Failures show in the task list.
    @discardableResult
    public func runBulkAction(_ draft: NodeBulkActionDraft) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        do {
            return try tasks.track(try await session.send(PVE.clusterBulkAction(draft)))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    /// Stops a running task. A task the app follows does not report the resulting failure.
    public func stopTask(node: String, upid: String) async throws {
        tasks.markStopped(upid)
        _ = try await session.send(PVE.stopTask(node: node, upid: upid))
    }

    /// Whether the user may stop a task: their own tasks always, others with `Sys.Modify` on the node, or on
    /// `/system/tasks` of a backup server.
    public func canStopTask(startedBy user: String, node: String) async -> Bool {
        if user == profile.userID { return true }
        return (try? await session.privileges(on: isBackupServer ? "/system/tasks" : "/nodes/\(node)"))?.contains("Sys.Modify") ?? true
    }

    /// Whether the server's Proxmox VE release has a feature; true while its version is unknown.
    public func supports(_ feature: PVEFeature) -> Bool {
        version?.supports(feature) ?? true
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
