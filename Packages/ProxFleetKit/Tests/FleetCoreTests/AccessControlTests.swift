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

    @Test func twoFactorAuthentication() async throws {
        let access = AccessControl(connection: try await connection())
        await access.load()
        #expect(access.twoFactors(of: "anna@pve")?.entries.map(\.type) == ["totp", "recovery"])
        #expect(access.twoFactors(of: "auditor@pve")?.isLocked() == true)
        try await access.unlockTwoFactor(of: "auditor@pve")
        #expect(access.twoFactors(of: "auditor@pve")?.isLocked() == false)

        let secret = TOTPSecret.random(issuer: "Proxmox - demo", account: "ci@pve")
        await #expect(throws: ConfigUpdateError.self) {
            try await access.addTOTP(for: "ci@pve", secret: secret, code: "12", description: "Phone", password: nil)
        }
        try await access.addTOTP(for: "ci@pve", secret: secret, code: "123456", description: "Phone", password: nil)
        let keys = try await access.addRecoveryKeys(for: "ci@pve", password: nil)
        #expect(keys.count == 10)
        await #expect(throws: ConfigUpdateError.self) { _ = try await access.addRecoveryKeys(for: "ci@pve", password: nil) }
        let totp = try #require(access.twoFactors(of: "ci@pve")?.entries.first { $0.type == "totp" })
        try await access.updateTwoFactor(of: "ci@pve", id: totp.id, description: "Old phone", isEnabled: false, password: nil)
        #expect(access.twoFactors(of: "ci@pve")?.entries.first { $0.id == totp.id }?.isEnabled == false)
        for entry in access.twoFactors(of: "ci@pve")?.entries ?? [] {
            try await access.deleteTwoFactor(of: "ci@pve", id: entry.id, password: nil)
        }
        #expect(access.twoFactors(of: "ci@pve") == nil)
    }

    @Test func usersConfirmTheirOwnSecondFactorChanges() async throws {
        let access = AccessControl(connection: try await connection(username: "anna"))
        await access.load()
        let recovery = try #require(access.twoFactors(of: "anna@pve")?.entries.first { $0.type == "recovery" })
        await #expect(throws: ConfigUpdateError.self) { try await access.deleteTwoFactor(of: "anna@pve", id: recovery.id, password: nil) }
        try await access.deleteTwoFactor(of: "anna@pve", id: recovery.id, password: "demo")
        #expect(access.twoFactors(of: "anna@pve")?.hasRecoveryKeys == false)
    }

    @Test func realms() async throws {
        let access = AccessControl(connection: try await connection())
        await access.load()
        #expect(access.realms?.map(\.realm) == ["pam", "pve", "corp", "sso"])
        let corp = try #require(RealmDraft(realm: "corp", try await access.realmConfig("corp")))
        #expect(corp.type == .ad && corp.domain == "corp.example.com" && corp.emailAttribute == "mail")
        #expect(corp.syncDefaults.removeVanished == [.acl, .entry])

        var ldap = RealmDraft(type: .ldap)
        ldap.realm = "lab"
        ldap.server1 = "ldap.lab"
        ldap.baseDN = "dc=lab"
        ldap.userAttribute = "uid"
        ldap.isDefault = true
        try await access.createRealm(ldap)
        #expect(access.realms?.first { $0.isDefault }?.realm == "lab")
        var edit = try #require(RealmDraft(realm: "lab", try await access.realmConfig("lab")))
        let original = edit
        edit.comment = "Lab directory"
        try await access.updateRealm("lab", edit.changes(from: original), digest: nil)
        #expect(access.realms?.first { $0.realm == "lab" }?.comment == "Lab directory")

        let task = try await access.syncRealm("lab", scope: "users", enableNew: true, removeVanished: [], dryRun: false)
        #expect(await access.connection.tasks.result(of: task.id) == .succeeded)
        await access.load()
        #expect(access.users?.contains { $0.userid == "j.smith@lab" } == true)

        try await access.deleteRealm("lab")
        #expect(access.realms?.contains { $0.realm == "lab" } == false)
        await #expect(throws: ConfigUpdateError.self) { try await access.deleteRealm("pam") }
    }

    @Test func auditorCannotChangeAccess() async throws {
        let access = AccessControl(connection: try await connection(username: "auditor"))
        await access.load()
        #expect(!access.can("User.Modify"))
        await #expect(throws: ConfigUpdateError.self) { try await access.createGroup("x", comment: nil) }
    }
}
