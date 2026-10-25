import Foundation
import Observation
import PBSKit
import ProxmoxCore
import PVEKit

/// Users, groups, roles and permissions of the datacenter.
///
/// On a backup server only the users and their second factors are loaded, for the two-factor screens it shares
/// with Proxmox VE; its own access screens use `BackupServerAccess`.
@MainActor
@Observable
public final class AccessControl {
    public let connection: ServerConnection

    public private(set) var users: [AccessUser]?
    public private(set) var groups: [AccessGroup]?
    public private(set) var roles: [AccessRole]?
    public private(set) var acl: [ACLEntry]?
    public private(set) var realms: [Realm]?
    /// Second factors of every user the signed-in user may see.
    public private(set) var twoFactors: [UserTwoFactors]?
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    /// The signed-in user, e.g. `root@pam`.
    public var currentUser: String {
        let profile = connection.profile
        return profile.username.contains("@") ? profile.username : "\(profile.username)@\(profile.realm)"
    }
    /// Only root@pam may change other users' passwords without confirming its own.
    public var needsPasswordConfirmation: Bool { currentUser != "root@pam" }

    /// The backup server calls `User.Modify` `Permissions.Modify`, on `/access/users`.
    public func can(_ privilege: String) -> Bool {
        privileges?.contains(connection.isBackupServer && privilege == "User.Modify" ? "Permissions.Modify" : privilege) ?? true
    }

    public func load() async {
        if connection.isBackupServer {
            await loadBackupServer()
            return
        }
        async let privileges = try? connection.session.privileges(on: "/access")
        do {
            users = try await connection.session.send(PVE.users()).sorted { $0.userid.localizedStandardCompare($1.userid) == .orderedAscending }
            groups = try await connection.session.send(PVE.groups()).sorted { $0.groupid < $1.groupid }
            roles = try await connection.session.send(PVE.roles()).sorted { ($0.isBuiltIn ? 1 : 0, $0.roleid) < ($1.isBuiltIn ? 1 : 0, $1.roleid) }
            acl = try await connection.session.send(PVE.acl()).sorted { ($0.path, $0.subjectID, $0.role) < ($1.path, $1.subjectID, $1.role) }
            realms = try? await connection.session.send(ProxmoxAccess.realms())
            twoFactors = try? await connection.session.send(PVE.twoFactors()).sorted { $0.userid.localizedStandardCompare($1.userid) == .orderedAscending }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { self.privileges = privileges }
    }

    private func loadBackupServer() async {
        async let privileges = try? connection.session.privileges(on: "/access/users")
        do {
            users = try await connection.session.send(PBS.accessUsers()).sorted { $0.userid.localizedStandardCompare($1.userid) == .orderedAscending }
            twoFactors = try await connection.session.send(PVE.twoFactors()).sorted { $0.userid.localizedStandardCompare($1.userid) == .orderedAscending }
            realms = try? await connection.session.send(ProxmoxAccess.realms())
            groups = []
            roles = []
            acl = []
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { self.privileges = privileges }
    }

    // MARK: - Users

    public func createUser(_ draft: UserDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createUser(draft))
    }

    public func updateUser(_ userid: String, _ changes: APIParameters) async throws(ConfigUpdateError) {
        guard !changes.isEmpty else { return }
        try await perform(PVE.updateUser(userid, changes))
    }

    public func deleteUser(_ userid: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteUser(userid))
    }

    public func changePassword(of userid: String, to password: String, confirmation: String?) async throws(ConfigUpdateError) {
        try await perform(PVE.changePassword(userid: userid, password: password, confirmation: confirmation), reload: false)
    }

    /// Creates an API token and returns its secret, which the server shows only once.
    public func createToken(for userid: String, tokenid: String, comment: String?, separated: Bool, expires: Date?) async throws(ConfigUpdateError) -> CreatedToken {
        do {
            let token = try await connection.session.send(PVE.createToken(userid: userid, tokenid: tokenid, comment: comment, separated: separated, expires: expires))
            await load()
            return token
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func deleteToken(of userid: String, tokenid: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteToken(userid: userid, tokenid: tokenid))
    }

    // MARK: - Groups, roles, permissions

    public func createGroup(_ groupid: String, comment: String?) async throws(ConfigUpdateError) {
        try await perform(PVE.createGroup(groupid, comment: comment))
    }

    public func updateGroup(_ groupid: String, comment: String) async throws(ConfigUpdateError) {
        try await perform(PVE.updateGroup(groupid, comment: comment))
    }

    public func deleteGroup(_ groupid: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteGroup(groupid))
    }

    public func createRole(_ roleid: String, privileges: Set<String>) async throws(ConfigUpdateError) {
        try await perform(PVE.createRole(roleid, privileges: privileges))
    }

    public func updateRole(_ roleid: String, privileges: Set<String>) async throws(ConfigUpdateError) {
        try await perform(PVE.updateRole(roleid, privileges: privileges))
    }

    public func deleteRole(_ roleid: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteRole(roleid))
    }

    public func addPermission(_ entry: ACLEntry) async throws(ConfigUpdateError) {
        try await perform(PVE.addPermission(entry))
    }

    public func removePermission(_ entry: ACLEntry) async throws(ConfigUpdateError) {
        try await perform(PVE.removePermission(entry))
    }

    // MARK: - Two-factor authentication

    public func twoFactors(of userid: String) -> UserTwoFactors? {
        twoFactors?.first { $0.userid == userid }
    }

    /// `password` is the signed-in user's own password, which everyone but root@pam must give.
    public func addTOTP(for userid: String, secret: TOTPSecret, code: String, description: String, password: String?) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(PVE.addTOTP(userid: userid, secret: secret, code: code, description: description, password: password))
        } catch {
            throw ConfigUpdateError(error)
        }
        await load()
    }

    /// Creates recovery keys and returns them; the server never shows them again.
    public func addRecoveryKeys(for userid: String, password: String?) async throws(ConfigUpdateError) -> [String] {
        do {
            let added = try await connection.session.send(PVE.addRecoveryKeys(userid: userid, password: password))
            await load()
            return added.recoveryKeys
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func updateTwoFactor(of userid: String, id: String, description: String, isEnabled: Bool, password: String?) async throws(ConfigUpdateError) {
        try await perform(PVE.updateTwoFactor(userid: userid, id: id, description: description, isEnabled: isEnabled, password: password))
    }

    public func deleteTwoFactor(of userid: String, id: String, password: String?) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteTwoFactor(userid: userid, id: id, password: password))
    }

    public func unlockTwoFactor(of userid: String) async throws(ConfigUpdateError) {
        try await perform(PVE.unlockTwoFactor(userid: userid))
    }

    // MARK: - Realms

    public func realmConfig(_ realm: String) async throws(ConfigUpdateError) -> RealmConfig {
        do {
            return try await connection.session.send(PVE.realmConfig(realm))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func createRealm(_ draft: RealmDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createRealm(draft))
    }

    /// Sends the changes with the digest of the configuration the form was opened with.
    public func updateRealm(_ realm: String, _ update: GuestConfigUpdate, digest: String?) async throws(ConfigUpdateError) {
        var update = update
        update.digest = digest
        try await perform(PVE.updateRealm(realm, update))
    }

    public func deleteRealm(_ realm: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteRealm(realm))
    }

    /// Starts a sync; with `dryRun` its log lists what would change without changing anything.
    public func syncRealm(_ realm: String, scope: String, enableNew: Bool, removeVanished: Set<VanishedRemoval>, dryRun: Bool) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await connection.start(PVE.syncRealm(realm, scope: scope, enableNew: enableNew, removeVanished: removeVanished, dryRun: dryRun))
    }

    // MARK: - Realm sync jobs

    public func realmSyncJobs() async throws(ConfigUpdateError) -> [RealmSyncJob] {
        do {
            return try await connection.session.send(PVE.realmSyncJobs()).sorted { $0.id < $1.id }
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    /// The next runs of a schedule, or the server's error for it.
    public func nextRuns(of schedule: String) async -> Result<[Date], ConfigUpdateError> {
        do {
            return .success(try await connection.session.send(PVE.scheduleRuns(schedule)).map(\.date))
        } catch {
            return .failure(ConfigUpdateError(error))
        }
    }

    public func createRealmSyncJob(_ draft: RealmSyncJobDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createRealmSyncJob(id: draft.resolvedID(), draft), reload: false)
    }

    public func updateRealmSyncJob(_ draft: RealmSyncJobDraft, _ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PVE.updateRealmSyncJob(draft, update), reload: false)
    }

    public func deleteRealmSyncJob(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteRealmSyncJob(id), reload: false)
    }

    /// Syncs now with the job's options, like the web interface's Run Now.
    public func runRealmSyncJob(_ job: RealmSyncJob) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await syncRealm(job.realm, scope: job.options.scope.isEmpty ? "both" : job.options.scope, enableNew: job.options.enableNew ?? true,
                            removeVanished: job.options.removeVanished, dryRun: false)
    }

    /// Permissions granted directly to a user, a group or a token.
    public func permissions(of subject: ACLEntry.Subject, _ id: String) -> [ACLEntry] {
        (acl ?? []).filter { $0.subject == subject && $0.subjectID == id }
    }

    private func perform(_ request: APIRequest<Nothing>, reload: Bool = true) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
        if reload { await load() }
    }
}
