import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

/// Users, groups, roles and permissions, with responses recorded from Proxmox VE 9.2.
struct AccessControlTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func users() throws {
        let users = try decode([AccessUser].self, #"""
        [{"comment": "Read-only test user", "userid": "limited@pve", "groups": "", "realm-type": "pve", "enable": 1, "tokens": null, "expire": 0, "email": ""},
         {"userid": "anna@pve", "groups": "admins,developers", "enable": 0, "expire": 1788220800, "firstname": "Anna", "lastname": "Nowak",
          "tokens": [{"tokenid": "grafana", "comment": "", "privsep": 1, "expire": 0}], "keys": "x"}]
        """#)
        #expect(users[0].name == "limited" && users[0].realm == "pve" && users[0].groups.isEmpty && users[0].email == nil)
        #expect(users[0].tokens.isEmpty && users[0].expires == nil && users[0].displayName == nil)
        #expect(users[1].groups == ["admins", "developers"] && !users[1].isEnabled && users[1].displayName == "Anna Nowak")
        #expect(users[1].tokens.map(\.tokenid) == ["grafana"] && users[1].tokens[0].isSeparated && users[1].hasLegacyKeys)
        #expect(users[1].isExpired(at: Date(timeIntervalSince1970: 1_800_000_000)))

        let single = try decode(AccessUser.self, #"{"comment": "Read-only test user", "expire": 0, "tokens": null, "groups": ["auditors"], "email": "", "enable": 1}"#)
        #expect(single.groups == ["auditors"])
    }

    @Test func rolesAndPermissions() throws {
        let roles = try decode([AccessRole].self, #"""
        [{"privs": "Pool.Audit", "special": 1, "roleid": "PVEPoolUser"},
         {"privs": "VM.PowerMgmt,VM.Audit,Sys.Audit", "roleid": "Operator"},
         {"roleid": "NoAccess", "special": 1, "privs": ""}]
        """#)
        #expect(roles[1].privileges == ["Sys.Audit", "VM.Audit", "VM.PowerMgmt"] && !roles[1].isBuiltIn && roles[2].privileges.isEmpty)
        let areas = AccessRole.privilegesByArea(roles)
        #expect(areas.map(\.area) == ["Pool", "Sys", "VM"] && areas[2].privileges == ["VM.Audit", "VM.PowerMgmt"])

        let acl = try decode([ACLEntry].self, #"[{"propagate": 1, "type": "user", "path": "/", "ugid": "limited@pve", "roleid": "PVEAuditor"}, {"propagate": 0, "type": "token", "path": "/vms/100", "ugid": "anna@pve!ci", "roleid": "PVEVMUser"}]"#)
        #expect(acl[0].subject == .user && acl[0].propagates)
        #expect(acl[1].subject == .token && !acl[1].propagates)
        #expect(PVE.addPermission(acl[1]).parameters.formEncoded == "path=%2Fvms%2F100&roles=PVEVMUser&tokens=anna%40pve%21ci&propagate=0")
        #expect(PVE.removePermission(acl[0]).parameters.formEncoded == "path=%2F&roles=PVEAuditor&users=limited%40pve&delete=1")
        #expect(PVE.createRole("Operator", privileges: ["VM.PowerMgmt", "VM.Audit"]).parameters.formEncoded == "roleid=Operator&privs=VM.Audit%2CVM.PowerMgmt")
    }

    @Test func userDrafts() throws {
        var draft = UserDraft()
        #expect(draft.problems(isNew: true).keys.sorted() == ["password", "userid"])
        draft.name = "bob"
        draft.password = "correct horse"
        draft.passwordConfirmation = "correct horse"
        draft.email = "bob@example.com"
        draft.groups = ["developers", "admins"]
        #expect(draft.problems(isNew: true).isEmpty)
        #expect(PVE.createUser(draft).parameters.formEncoded
            == "userid=bob%40pve&email=bob%40example.com&enable=1&groups=admins%2Cdevelopers&password=correct%20horse")
        draft.realm = "pam"
        #expect(!PVE.createUser(draft).parameters.formEncoded.contains("password"))

        let user = try decode(AccessUser.self, #"{"userid": "anna@pve", "email": "anna@example.com", "groups": "admins", "enable": 1, "comment": "Lead"}"#)
        let original = UserDraft(user)
        #expect(original.changes(from: original).isEmpty)
        var edit = original
        edit.email = ""
        edit.isEnabled = false
        edit.expires = Date(timeIntervalSince1970: 1_800_000_000)
        // No `delete` here: cleared fields go as empty strings.
        #expect(edit.changes(from: original).formEncoded == "email=&enable=0&expire=1800000000")
        edit.email = "not-an-address"
        #expect(edit.problems(isNew: false).keys.sorted() == ["email"])
    }

    @Test func tokens() throws {
        let token = try decode(CreatedToken.self, #"{"full-tokenid": "anna@pve!ci", "value": "8f6c2b1e-1111-2222-3333-444455556666", "info": {"privsep": 1}}"#)
        #expect(token.fullID == "anna@pve!ci" && token.secret.count == 36)
        #expect(PVE.createToken(userid: "anna@pve", tokenid: "ci", comment: "Pipeline", separated: false, expires: nil).path == "/access/users/anna@pve/token/ci")
        #expect(PVE.changePassword(userid: "anna@pve", password: "new secret", confirmation: "mine").parameters.formEncoded
            == "userid=anna%40pve&password=new%20secret&confirmation-password=mine")
    }
}
