import Foundation
import Observation
import PBSKit
import ProxmoxCore
import PVEKit

/// The privileges a user or token has on one path, from every ACL entry that applies there.
public struct EffectivePermission: Sendable, Equatable, Identifiable {
    public var path: String
    public var privileges: [String]
    public var id: String { path }
}

/// Users and their API tokens, permissions, roles and realms of a backup server.
@MainActor
@Observable
public final class BackupServerAccess {
    public let connection: ServerConnection

    public private(set) var users: [BackupServerUser]?
    public private(set) var acl: [BackupServerACLEntry]?
    public private(set) var roles: [BackupServerRole]?
    public private(set) var realms: [Realm]?
    public private(set) var loadError: String?
    private var usersDigest: String?
    private var aclDigest: String?
    /// Privileges by path: `/access/users`, `/access/acl` and `/access/domains`.
    private var privileges: [String: Set<String>] = [:]

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    /// The signed-in user, e.g. `root@pam`.
    public var currentUser: String { connection.profile.userID }
    /// Only root@pam may change other users' passwords without confirming its own.
    public var needsPasswordConfirmation: Bool { currentUser != "root@pam" }

    private func can(_ privilege: String, on path: String) -> Bool { privileges[path]?.contains(privilege) ?? true }
    /// Adding, changing and removing users and their tokens needs `Permissions.Modify` on `/access/users`.
    public var canManageUsers: Bool { can("Permissions.Modify", on: "/access/users") }
    public var canModifyPermissions: Bool { can("Permissions.Modify", on: "/access/acl") }
    public var canManageRealms: Bool { can("Realm.Allocate", on: "/access/domains") }

    /// Users and tokens, the identities permissions can be given to.
    public var authIDs: [String] { (users ?? []).flatMap(\.authIDs) }

    public func load() async {
        async let privileges = loadPrivileges()
        do {
            async let users = connection.send(PBS.users(includeTokens: true))
            async let acl = connection.send(PBS.acl())
            async let roles = connection.send(PBS.roles())
            let (loadedUsers, loadedACL) = try await (users, acl)
            self.users = loadedUsers.value.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            usersDigest = loadedUsers.digest
            self.acl = loadedACL.value.sorted { ($0.path, $0.authID, $0.role) < ($1.path, $1.authID, $1.role) }
            aclDigest = loadedACL.digest
            self.roles = (try? await roles)?.sorted { $0.id < $1.id }
            realms = try? await connection.send(ProxmoxAccess.realms())
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        self.privileges = await privileges
    }

    private func loadPrivileges() async -> [String: Set<String>] {
        var privileges: [String: Set<String>] = [:]
        for path in ["/access/users", "/access/acl", "/access/domains"] {
            if let granted = try? await connection.apiSession.backupServerPrivileges(on: path) { privileges[path] = granted }
        }
        return privileges
    }

    // MARK: - Users

    public func createUser(_ draft: BackupServerUserDraft) async throws(ConfigUpdateError) {
        try await perform(PBS.createUser(draft))
    }

    public func updateUser(_ userID: String, _ update: BackupServerConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        var update = update
        if update.digest == nil { update.digest = usersDigest }
        try await perform(PBS.updateUser(userID, update))
    }

    public func deleteUser(_ userID: String) async throws(ConfigUpdateError) {
        try await perform(PBS.deleteUser(userID))
    }

    public func changePassword(of userID: String, to password: String, confirmation: String?) async throws(ConfigUpdateError) {
        try await perform(PBS.changePassword(of: userID, to: password, confirmation: confirmation), reload: false)
    }

    /// Creates a token and returns its secret, which the server shows only this once.
    public func createToken(of userID: String, _ draft: BackupServerTokenDraft) async throws(ConfigUpdateError) -> BackupServerCreatedToken {
        let token: BackupServerCreatedToken
        do {
            token = try await connection.send(PBS.createToken(of: userID, draft))
        } catch {
            throw ConfigUpdateError(error)
        }
        await load()
        return token
    }

    public func updateToken(of userID: String, name: String, _ update: BackupServerConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PBS.updateToken(of: userID, name: name, update))
    }

    /// A new secret for a token; the old one stops working.
    public func regenerateToken(of userID: String, name: String) async throws(ConfigUpdateError) -> BackupServerCreatedToken {
        do {
            return try await connection.send(PBS.regenerateToken(of: userID, name: name))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func deleteToken(of userID: String, name: String) async throws(ConfigUpdateError) {
        try await perform(PBS.deleteToken(of: userID, name: name))
    }

    // MARK: - Permissions

    public func permissions(of authID: String) -> [BackupServerACLEntry] {
        (acl ?? []).filter { $0.authID == authID }
    }

    public func addPermission(_ entry: BackupServerACLEntry) async throws(ConfigUpdateError) {
        try await perform(PBS.setACL(entry))
    }

    public func removePermission(_ entry: BackupServerACLEntry) async throws(ConfigUpdateError) {
        try await perform(PBS.setACL(entry, remove: true, digest: aclDigest))
    }

    // MARK: - Realms

    public func realmConfig(_ kind: BackupServerRealmDraft.Kind, _ realm: String) async throws(ConfigUpdateError) -> Digested<BackupServerRealmConfig> {
        do {
            return try await connection.send(PBS.realmConfig(kind, realm))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func createRealm(_ draft: BackupServerRealmDraft) async throws(ConfigUpdateError) {
        try await perform(PBS.createRealm(draft))
    }

    public func updateRealm(_ kind: BackupServerRealmDraft.Kind, _ realm: String, _ update: BackupServerConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PBS.updateRealm(kind, realm, update))
    }

    public func deleteRealm(_ kind: BackupServerRealmDraft.Kind, _ realm: String) async throws(ConfigUpdateError) {
        try await perform(PBS.deleteRealm(kind, realm))
    }

    /// Syncs users from a directory realm; a dry run only reports what would change. Users reload when it ends.
    @discardableResult
    public func syncRealm(_ realm: String, dryRun: Bool, enableNew: Bool?, removeVanished: Set<RealmSyncRemoval>) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        let task: TaskCenter.TrackedTask
        do {
            task = try connection.tasks.track(try await connection.send(PBS.syncRealm(realm, dryRun: dryRun, enableNew: enableNew, removeVanished: removeVanished)))
        } catch {
            throw ConfigUpdateError(error)
        }
        Task { [weak self, tasks = connection.tasks] in
            _ = await tasks.result(of: task.id)
            await self?.load()
        }
        return task
    }

    private func perform(_ request: APIRequest<Nothing>, reload: Bool = true) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.send(request)
        } catch {
            let failure = ConfigUpdateError(error)
            if failure == .conflict { await load() }
            throw failure
        }
        if reload { await load() }
    }

    // MARK: - Effective permissions and WebAuthn

    /// What a user or token may do, by path, sorted by path, with the privileges sorted too.
    public func effectivePermissions(of authID: String) async throws(ConfigUpdateError) -> [EffectivePermission] {
        let permissions: [String: [String: Bool]]
        do {
            permissions = try await connection.send(PBS.effectivePermissions(of: authID))
        } catch {
            throw ConfigUpdateError(error)
        }
        return permissions.map { path, privileges in EffectivePermission(path: path, privileges: privileges.filter(\.value).map(\.key).sorted()) }
            .filter { !$0.privileges.isEmpty }
            .sorted { $0.path < $1.path }
    }

    /// Only root@pam may change the WebAuthn settings; everyone can read them.
    public var canChangeWebAuthn: Bool { currentUser == "root@pam" }

    public func webAuthn() async throws(ConfigUpdateError) -> Digested<BackupServerWebAuthnConfig?> {
        do {
            return try await connection.send(PBS.webAuthnConfig())
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func updateWebAuthn(_ update: BackupServerConfigUpdate) async throws(ConfigUpdateError) {
        try await perform(PBS.updateWebAuthnConfig(update), reload: false)
    }
}

/// Traffic control, metric servers, S3 endpoints and encryption keys of a backup server.
@MainActor
@Observable
public final class BackupServerSettings {
    public let connection: ServerConnection

    public private(set) var trafficRules: [TrafficControlRule]?
    /// The traffic each rule lets through right now, by rule name.
    public private(set) var currentTraffic: [String: TrafficControlRule] = [:]
    public private(set) var metricServers: [BackupServerMetricServer]?
    public private(set) var s3Endpoints: [S3Endpoint]?
    public private(set) var encryptionKeys: [EncryptionKeyEntry]?
    public private(set) var loadError: String?
    private var digests: [String: String] = [:]
    private var systemPrivileges: Set<String>?

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    /// Changing these settings needs `Sys.Modify` on `/system` (or `/` for metric servers and traffic control).
    public var canModify: Bool { systemPrivileges?.contains("Sys.Modify") ?? true }

    private func loadPrivileges() async {
        if let granted = try? await connection.apiSession.backupServerPrivileges(on: "/system") { systemPrivileges = granted }
    }

    private func load<Value>(_ request: APIRequest<Digested<Value>>, key: String, store: (Value) -> Void) async {
        do {
            let digested = try await connection.send(request)
            store(digested.value)
            digests[key] = digested.digest
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func loadTrafficControl() async {
        await loadPrivileges()
        await load(PBS.trafficControlRules(), key: "traffic") { trafficRules = $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        await loadCurrentTraffic()
    }

    public func loadCurrentTraffic() async {
        if let status = try? await connection.send(PBS.trafficControlStatus()) {
            currentTraffic = Dictionary(status.map { ($0.name, $0) }) { first, _ in first }
        }
    }

    public func loadMetricServers() async {
        await loadPrivileges()
        await load(PBS.metricServers(), key: "metrics") { metricServers = $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    }

    public func loadS3Endpoints() async {
        await loadPrivileges()
        await load(PBS.s3Endpoints(), key: "s3") { s3Endpoints = $0.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending } }
    }

    public func loadEncryptionKeys() async {
        await loadPrivileges()
        await load(PBS.encryptionKeys(includeArchived: true), key: "keys") { keys in
            encryptionKeys = keys.sorted { ($0.isArchived ? 1 : 0, $0.id) < ($1.isArchived ? 1 : 0, $1.id) }
        }
    }

    // MARK: - Changes

    private func perform(_ request: APIRequest<Nothing>, then reload: () async -> Void) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.send(request)
        } catch {
            let failure = ConfigUpdateError(error)
            if failure == .conflict { await reload() }
            throw failure
        }
        await reload()
    }

    private func withDigest(_ update: BackupServerConfigUpdate, _ key: String) -> BackupServerConfigUpdate {
        var update = update
        if update.digest == nil { update.digest = digests[key] }
        return update
    }

    public func createTrafficRule(_ draft: TrafficControlDraft) async throws(ConfigUpdateError) {
        try await perform(PBS.createTrafficControlRule(draft)) { await loadTrafficControl() }
    }

    public func updateTrafficRule(_ name: String, _ update: BackupServerConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PBS.updateTrafficControlRule(name, withDigest(update, "traffic"))) { await loadTrafficControl() }
    }

    public func deleteTrafficRule(_ name: String) async throws(ConfigUpdateError) {
        try await perform(PBS.deleteTrafficControlRule(name, digest: digests["traffic"])) { await loadTrafficControl() }
    }

    public func metricServerConfig(_ server: BackupServerMetricServer) async throws(ConfigUpdateError) -> Digested<BackupServerRealmConfig> {
        guard let kind = server.kind else { throw ConfigUpdateError.failed(String(localized: "The app does not know this kind of metric server.")) }
        do {
            return try await connection.send(PBS.metricServer(kind, server.name))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func createMetricServer(_ draft: BackupServerMetricServerDraft) async throws(ConfigUpdateError) {
        try await perform(PBS.createMetricServer(draft)) { await loadMetricServers() }
    }

    public func updateMetricServer(_ kind: BackupServerMetricServer.Kind, _ name: String, _ update: BackupServerConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PBS.updateMetricServer(kind, name, update)) { await loadMetricServers() }
    }

    public func deleteMetricServer(_ kind: BackupServerMetricServer.Kind, _ name: String) async throws(ConfigUpdateError) {
        try await perform(PBS.deleteMetricServer(kind, name)) { await loadMetricServers() }
    }

    public func createS3Endpoint(_ draft: S3EndpointDraft) async throws(ConfigUpdateError) {
        try await perform(PBS.createS3Endpoint(draft)) { await loadS3Endpoints() }
    }

    public func updateS3Endpoint(_ id: String, _ update: BackupServerConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PBS.updateS3Endpoint(id, withDigest(update, "s3"))) { await loadS3Endpoints() }
    }

    public func deleteS3Endpoint(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PBS.deleteS3Endpoint(id)) { await loadS3Endpoints() }
    }

    /// Lists the endpoint's buckets, which also checks that its address and keys work.
    public func buckets(of endpoint: String) async -> Result<[String], ConfigUpdateError> {
        do {
            return .success(try await connection.send(PBS.s3Buckets(endpoint)).names)
        } catch {
            return .failure(ConfigUpdateError(error))
        }
    }

    public func createEncryptionKey(_ id: String, importing key: String? = nil) async throws(ConfigUpdateError) {
        try await perform(PBS.createEncryptionKey(id, importing: key)) { await loadEncryptionKeys() }
    }

    public func archiveEncryptionKey(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PBS.archiveEncryptionKey(id)) { await loadEncryptionKeys() }
    }

    public func deleteEncryptionKey(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PBS.deleteEncryptionKey(id)) { await loadEncryptionKeys() }
    }
}
