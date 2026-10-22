import DemoServer
import Foundation
import Observation
import ProxmoxCore
import ProxmoxURLSession

/// Dependencies of the app domain, swappable for tests and previews.
public struct FleetEnvironment: Sendable {
    public var profiles: any ServerProfileStore
    public var credentials: any CredentialStore
    public var makeTransport: @Sendable (ServerProfile) -> any HTTPTransport

    public init(profiles: any ServerProfileStore, credentials: any CredentialStore, makeTransport: @escaping @Sendable (ServerProfile) -> any HTTPTransport) {
        self.profiles = profiles
        self.credentials = credentials
        self.makeTransport = makeTransport
    }

    /// Real network, Keychain and files.
    public static func live() -> FleetEnvironment {
        FleetEnvironment(profiles: FileServerProfileStore.standard(), credentials: KeychainCredentialStore(), makeTransport: defaultTransport)
    }

    /// Nothing persisted. Real servers still use the network.
    public static func inMemory(_ profiles: [ServerProfile] = []) -> FleetEnvironment {
        FleetEnvironment(profiles: InMemoryServerProfileStore(profiles), credentials: InMemoryCredentialStore(), makeTransport: defaultTransport)
    }

    @Sendable public static func defaultTransport(for profile: ServerProfile) -> any HTTPTransport {
        profile.isDemo ? DemoTransport() : URLSessionTransport(pinnedFingerprints: Set(profile.trustedFingerprints))
    }
}

/// All saved servers and their live connections. The root model of the app.
@MainActor
@Observable
public final class Fleet {
    public private(set) var profiles: [ServerProfile]
    @ObservationIgnored private var connections: [UUID: ServerConnection] = [:]
    let environment: FleetEnvironment

    public init(environment: FleetEnvironment) {
        self.environment = environment
        profiles = environment.profiles.load()
    }

    public func connection(for id: UUID) -> ServerConnection? {
        if let existing = connections[id] { return existing }
        guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
        let connection = makeConnection(profile)
        connections[id] = connection
        return connection
    }

    public func profile(id: UUID) -> ServerProfile? {
        profiles.first { $0.id == id }
    }

    /// Another saved server that belongs to the same cluster, if any.
    public func profile(inCluster clusterName: String, excluding id: UUID? = nil) -> ServerProfile? {
        profiles.first { $0.clusterName == clusterName && $0.id != id && !$0.isDemo }
    }

    /// Adds a server, keeping the session that was used to sign in so the user does not log in twice.
    @discardableResult
    func add(_ profile: ServerProfile, session: ProxmoxSession?, transport: (any HTTPTransport)?) -> ServerConnection {
        profiles.append(profile)
        persist()
        let connection = makeConnection(profile, session: session, transport: transport)
        connections[profile.id] = connection
        if session != nil {
            Task { await connection.refresh() }
        }
        return connection
    }

    public func update(_ profile: ServerProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        connections[profile.id]?.updateProfile(profile)
        persist()
    }

    public func rename(_ id: UUID, to name: String) {
        guard var profile = self.profile(id: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profile.name = trimmed
        update(profile)
    }

    public func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        connections[id] = nil
        environment.credentials.removeAll(for: id)
        persist()
    }

    /// Forgets every saved server and its secrets, as when the app lock's PIN is forgotten.
    public func removeAllServers() {
        for profile in profiles {
            remove(profile.id)
        }
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { profiles[$0] }
        var remaining = profiles.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
        profiles = remaining
        persist()
    }

    /// Adds the built-in demo cluster, or returns it when it already exists.
    @discardableResult
    public func addDemoServer() -> ServerProfile {
        if let existing = profiles.first(where: \.isDemo) { return existing }
        let profile = ServerProfile(
            name: "Demo Cluster",
            addresses: [ServerAddress(host: "demo.proxfleet.invalid", port: 8006)],
            username: "demo",
            realm: "pve",
            clusterName: "homelab",
            isDemo: true
        )
        return addSaved(profile, password: "demo")
    }

    /// Adds a server whose password is already known, e.g. from a development configuration.
    @discardableResult
    public func addSaved(_ profile: ServerProfile, password: String?) -> ServerProfile {
        environment.credentials.setPassword(password, for: profile.id)
        add(profile, session: nil, transport: nil)
        return profile
    }

    public func makeOnboarding() -> ServerOnboarding {
        ServerOnboarding(fleet: self)
    }

    private func makeConnection(_ profile: ServerProfile, session: ProxmoxSession? = nil, transport: (any HTTPTransport)? = nil) -> ServerConnection {
        ServerConnection(profile: profile, environment: environment, session: session, transport: transport) { [weak self] updated in
            self?.update(updated)
        }
    }

    private func persist() {
        environment.profiles.save(profiles)
    }
}
