import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct AccessControlModelTests {
    private func connection(username: String = "root") async throws -> ServerConnection {
        let transport = DemoTransport(cluster: .homelab)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: username, realm: username == "root" ? "pam" : "pve"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        try #require(connection.state == .connected)
        return connection
    }

    @Test func usersGroupsRolesAndPermissions() async throws {
        let access = AccessControl(connection: try await connection())
        await access.load()
        #expect(access.currentUser == "root@pam" && !access.needsPasswordConfirmation)
        #expect(access.users?.map(\.userid) == ["anna@pve", "auditor@pve", "ci@pve", "intern@pve", "root@pam"])
        #expect(access.groups?.first { $0.groupid == "admins" }?.members == ["anna@pve"])
        #expect(access.roles?.first?.roleid == "LabOperator")
        #expect(access.permissions(of: .token, "anna@pve!monitoring").map(\.role) == ["PVEAuditor"])
        #expect(access.realms?.map(\.realm).contains("pve") == true)

        try await access.createGroup("ops", comment: "Operations")
        var draft = UserDraft()
        draft.name = "bob"
        draft.password = "correct horse"
        draft.passwordConfirmation = "correct horse"
        draft.groups = ["ops"]
        try await access.createUser(draft)
        await access.load()
        #expect(access.groups?.first { $0.groupid == "ops" }?.members == ["bob@pve"])

        try await access.createRole("Viewer", privileges: ["VM.Audit"])
        try await access.addPermission(ACLEntry(path: "/vms/100", subject: .group, subjectID: "ops", role: "Viewer"))
        #expect(access.permissions(of: .group, "ops").map(\.path) == ["/vms/100"])
        try await access.updateRole("Viewer", privileges: ["VM.Audit", "VM.Console"])
        #expect(access.roles?.first { $0.roleid == "Viewer" }?.privileges == ["VM.Audit", "VM.Console"])
        await #expect(throws: ConfigUpdateError.self) { try await access.updateRole("PVEAuditor", privileges: []) }

        let token = try await access.createToken(for: "bob@pve", tokenid: "ci", comment: nil, separated: true, expires: nil)
        #expect(token.fullID == "bob@pve!ci" && !token.secret.isEmpty)
        #expect(access.users?.first { $0.userid == "bob@pve" }?.tokens.map(\.tokenid) == ["ci"])
        try await access.changePassword(of: "bob@pve", to: "another one", confirmation: nil)

        let bob = try #require(access.users?.first { $0.userid == "bob@pve" })
        var edit = UserDraft(bob)
        edit.isEnabled = false
        edit.comment = "Left"
        try await access.updateUser(bob.userid, edit.changes(from: UserDraft(bob)))
        #expect(access.users?.first { $0.userid == "bob@pve" }?.isEnabled == false)

        try await access.removePermission(ACLEntry(path: "/vms/100", subject: .group, subjectID: "ops", role: "Viewer"))
        try await access.deleteToken(of: "bob@pve", tokenid: "ci")
        try await access.deleteUser("bob@pve")
        try await access.deleteRole("Viewer")
        try await access.deleteGroup("ops")
        #expect(access.users?.contains { $0.userid == "bob@pve" } == false && access.groups?.contains { $0.groupid == "ops" } == false)
        await #expect(throws: ConfigUpdateError.self) { try await access.deleteUser("root@pam") }
    }

    @Test func otherUsersConfirmWithTheirOwnPassword() async throws {
        let access = AccessControl(connection: try await connection(username: "anna"))
        await access.load()
        #expect(access.needsPasswordConfirmation)
        await #expect(throws: ConfigUpdateError.invalid(message: "Parameter verification failed.", fields: ["confirmation-password": "password is required to modify user"])) {
            try await access.changePassword(of: "ci@pve", to: "new secret", confirmation: nil)
        }
        await #expect(throws: ConfigUpdateError.failed("invalid credentials")) {
            try await access.changePassword(of: "ci@pve", to: "new secret", confirmation: "wrong")
        }
        // A wrong confirmation does not sign the user out.
        #expect(access.connection.state == .connected)
        try await access.changePassword(of: "ci@pve", to: "new secret", confirmation: "demo")
    }

    @Test func auditorCannotChangeAccess() async throws {
        let access = AccessControl(connection: try await connection(username: "auditor"))
        await access.load()
        #expect(!access.can("User.Modify"))
        await #expect(throws: ConfigUpdateError.self) { try await access.createGroup("x", comment: nil) }
    }
}
