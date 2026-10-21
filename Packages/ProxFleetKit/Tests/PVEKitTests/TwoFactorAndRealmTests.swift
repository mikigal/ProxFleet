import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct TwoFactorAndRealmTests {
    @Test func base32MatchesRFC4648() {
        #expect(TOTPSecret.base32(Array("f".utf8)) == "MY")
        #expect(TOTPSecret.base32(Array("foob".utf8)) == "MZXW6YQ")
        #expect(TOTPSecret.base32(Array("foobar".utf8)) == "MZXW6YTBOI")
        let secret = TOTPSecret.random(issuer: "Proxmox - pve", account: "anna@pve")
        #expect(secret.secret.count == 32)
        #expect(secret.secret.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) })
    }

    @Test func totpURIAndRequest() {
        let secret = TOTPSecret(secret: "JBSWY3DPEHPK3PXP", issuer: "Proxmox - pve", account: "anna@pve")
        #expect(secret.uri == "otpauth://totp/Proxmox%20-%20pve:anna@pve?secret=JBSWY3DPEHPK3PXP&period=30&digits=6&algorithm=SHA1&issuer=Proxmox%20-%20pve")
        #expect(secret.grouped == "JBSW Y3DP EHPK 3PXP")
        let request = PVE.addTOTP(userid: "anna@pve", secret: secret, code: "123 456", description: " Phone ", password: "secret")
        #expect(request.method == .post)
        #expect(request.path == "/access/tfa/anna@pve")
        #expect(request.parameters["value"] == "123456")
        #expect(request.parameters["description"] == "Phone")
        #expect(request.parameters["password"] == "secret")
        #expect(PVE.deleteTwoFactor(userid: "root@pam", id: "totp-1", password: nil).parameters.isEmpty)
    }

    @Test func decodesTwoFactorList() throws {
        let json = #"""
        [{"userid":"anna@pve","totp-locked":1,"entries":[{"id":"totp-1","type":"totp","description":"Phone","created":1792000000},
          {"id":"recovery","type":"recovery","description":"","created":1792000100,"enable":0}]},
         {"userid":"ci@pve","entries":[],"tfa-locked-until":4102444800}]
        """#
        let users = try JSONDecoder().decode([UserTwoFactors].self, from: Data(json.utf8))
        #expect(users[0].isTOTPLocked && users[0].isLocked())
        #expect(users[0].hasRecoveryKeys)
        #expect(users[0].entries[1].isEnabled == false)
        #expect(users[0].entries[0].created == Date(timeIntervalSince1970: 1_792_000_000))
        #expect(users[1].isLocked(at: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(!users[1].isLocked(at: Date(timeIntervalSince1970: 4_102_444_801)))
    }

    @Test func ldapRealmRoundTrip() {
        let config = RealmConfig(type: "ldap", values: [
            "server1": "ldap.example.com", "base_dn": "dc=example,dc=com", "user_attr": "uid", "mode": "ldaps", "verify": "1",
            "bind_dn": "cn=pve,dc=example,dc=com", "sync_attributes": "email=mail,firstname=givenName", "tfa": "type=oath,digits=8",
            "sync-defaults-options": "scope=users,enable-new=0,remove-vanished=acl;entry", "comment": "Office",
        ], digest: "abc")
        let original = try! #require(RealmDraft(realm: "office", config))
        #expect(original.emailAttribute == "mail")
        #expect(original.twoFactor.kind == .oath && original.twoFactor.digits == "8")
        #expect(original.syncDefaults.scope == "users" && original.syncDefaults.enableNew == false)
        #expect(original.syncDefaults.removeVanished == [.acl, .entry])
        #expect(original.changes(from: original).isEmpty)

        var draft = original
        draft.emailAttribute = ""
        draft.comment = ""
        draft.server2 = "ldap2.example.com"
        draft.mode = "ldap"
        draft.twoFactor.kind = .none
        draft.syncDefaults.removeVanished = [.properties]
        draft.password = "bind-secret"
        draft.checksConnection = true
        let update = draft.changes(from: original)
        #expect(update.values == [
            "server2": "ldap2.example.com", "sync_attributes": "firstname=givenName",
            "sync-defaults-options": "scope=users,enable-new=0,remove-vanished=properties", "password": "bind-secret",
            "check-connection": "1",
        ])
        #expect(update.deletions == ["comment", "mode", "tfa"])
    }

    @Test func newRealmsAndProblems() {
        var draft = RealmDraft(type: .openid)
        #expect(draft.problems(isNew: true).keys.sorted() == ["client-id", "issuer-url", "realm"])
        draft.realm = "sso"
        draft.issuerURL = "auth.example.com"
        draft.clientID = "proxmox"
        #expect(draft.problems(isNew: true).keys.sorted() == ["issuer-url"])
        draft.issuerURL = "https://auth.example.com/realms/main"
        draft.usernameClaim = "email"
        draft.autocreateUsers = true
        draft.twoFactor.kind = .oath
        #expect(draft.problems(isNew: true).isEmpty)
        let request = PVE.createRealm(draft)
        #expect(request.parameters.items.map(\.name) == ["realm", "type", "autocreate", "client-id", "issuer-url", "username-claim"])
        // OpenID realms leave second factors to the provider.
        #expect(request.parameters["tfa"] == nil)

        var ad = RealmDraft(type: .ad)
        ad.realm = "1corp"
        ad.port = "70000"
        ad.twoFactor.kind = .yubico
        #expect(ad.problems(isNew: true).keys.sorted() == ["domain", "port", "realm", "server1", "tfa"])

        let sync = PVE.syncRealm("office", scope: "both", enableNew: true, removeVanished: [], dryRun: true)
        #expect(sync.parameters.formEncoded == "scope=both&enable-new=1&remove-vanished=none&dry-run=1")
    }
}
