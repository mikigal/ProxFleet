import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// Users, groups, roles and permissions of the datacenter.
@MainActor
@Observable
public final class AccessControl {
    public let connection: ServerConnection

    public private(set) var users: [AccessUser]?
    public private(set) var groups: [AccessGroup]?
    public private(set) var roles: [AccessRole]?
    public private(set) var acl: [ACLEntry]?
    public private(set) var realms: [Realm]?
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

    public func can(_ privilege: String) -> Bool { privileges?.contains(privilege) ?? true }

    public func load() async {
        async let privileges = try? connection.session.privileges(on: "/access")
        do {
            users = try await connection.session.send(PVE.users()).sorted { $0.userid.localizedStandardCompare($1.userid) == .orderedAscending }
            groups = try await connection.session.send(PVE.groups()).sorted { $0.groupid < $1.groupid }
            roles = try await connection.session.send(PVE.roles()).sorted { ($0.isBuiltIn ? 1 : 0, $0.roleid) < ($1.isBuiltIn ? 1 : 0, $1.roleid) }
            acl = try await connection.session.send(PVE.acl()).sorted { ($0.path, $0.subjectID, $0.role) < ($1.path, $1.subjectID, $1.role) }
            realms = try? await connection.session.send(ProxmoxAccess.realms())
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
