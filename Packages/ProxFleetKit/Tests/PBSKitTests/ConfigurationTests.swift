import Foundation
@testable import PBSKit
import ProxmoxCore
import PVEKit
import Testing

struct ConfigurationTests {
    @Test func usersSendTheirDefaultsOnlyWhenChanged() throws {
        var draft = BackupServerUserDraft()
        draft.userID = "sync@pbs"
        draft.password = "short"
        draft.email = "nobody"
        #expect(Set(draft.problems(isNew: true, realms: ["pam", "pbs"]).keys) == ["password", "email"])
        draft.password = "a-long-password"
        draft.passwordConfirmation = "a-long-passwort"
        #expect(draft.problems(isNew: true, realms: ["pbs"])["password"] == "The passwords do not match.")
        draft.passwordConfirmation = "a-long-password"
        draft.email = "sync@example.com"
        draft.comment = "Sync user"
        #expect(draft.problems(isNew: true, realms: ["pam", "pbs"]).isEmpty)
        #expect(draft.creationParameters == ["userid": "sync@pbs", "password": "a-long-password", "comment": "Sync user", "email": "sync@example.com"])
        draft.userID = "sync@nowhere"
        #expect(draft.problems(isNew: true, realms: ["pam", "pbs"])["userid"] != nil)
        draft.userID = "no-realm"
        #expect(draft.problems(isNew: true, realms: [])["userid"] != nil)

        let user = try JSONDecoder().decode(BackupServerUser.self, from: Data(#"{"userid":"anna@pbs","comment":"Laptop","enable":true}"#.utf8))
        let original = BackupServerUserDraft(user)
        var edited = original
        edited.isEnabled = false
        edited.expires = Date(timeIntervalSince1970: 1_800_000_000)
        edited.comment = ""
        let update = edited.changes(from: original)
        #expect(update.values == ["enable": "0", "expire": "1800000000"])
        #expect(update.deletions == ["comment"])
        #expect(PBS.updateUser("anna@pbs", update).parameters.values("delete") == ["comment"])
    }

    @Test func tokensAndPasswords() throws {
        var token = BackupServerTokenDraft()
        token.name = "s"
        #expect(!token.problems.isEmpty)
        token.name = "sync"
        token.comment = "Remote sync"
        let create = PBS.createToken(of: "sync@pbs", token)
        #expect(create.path == "/access/users/sync@pbs/token/sync")
        #expect(create.parameters == ["comment": "Remote sync"])
        #expect(PBS.regenerateToken(of: "sync@pbs", name: "sync").parameters == ["regenerate": true])
        #expect(PBS.changePassword(of: "anna@pbs", to: "new-password", confirmation: "mine").parameters["confirmation-password"] == "mine")
        #expect(PBS.changePassword(of: "anna@pbs", to: "new-password", confirmation: nil).parameters["confirmation-password"] == nil)
        let created = try JSONDecoder().decode(BackupServerCreatedToken.self, from: Data(#"{"tokenid":"sync@pbs!sync","value":"abc"}"#.utf8))
        #expect(created.secret == "abc")
        let regenerated = try JSONDecoder().decode(BackupServerCreatedToken.self, from: Data(#"{"secret":"def"}"#.utf8))
        #expect(regenerated.secret == "def")
        // Proxmox VE's `full` parameter is unknown to the backup server.
        #expect(PBS.accessUsers().parameters.isEmpty)
    }

    @Test func directoryRealms() {
        var ldap = BackupServerRealmDraft(kind: .ldap)
        ldap.realm = "company"
        #expect(Set(ldap.problems(isNew: true).keys) == ["server1", "base-dn"])
        ldap.server1 = "ldap.example.com"
        ldap.baseDN = "dc=example,dc=com"
        ldap.password = "bind-secret"
        #expect(ldap.problems(isNew: true).isEmpty)
        let parameters = ldap.creationParameters
        #expect(parameters == ["realm": "company", "base-dn": "dc=example,dc=com", "server1": "ldap.example.com", "user-attr": "uid", "password": "bind-secret"])
        #expect(PBS.createRealm(ldap).path == "/config/access/ldap")

        let stored = BackupServerRealmDraft(kind: .ldap, realm: "company", config: BackupServerRealmConfig(values: [
            "server1": "ldap.example.com", "base-dn": "dc=example,dc=com", "user-attr": "uid", "mode": "ldaps", "verify": "1",
        ]))
        #expect(stored.update(from: stored, digest: nil).isEmpty)
        var edited = stored
        edited.mode = "ldap"
        let update = edited.update(from: stored, digest: "d")
        // Plain LDAP is the default, so it is deleted rather than set.
        #expect(update.deletions == ["mode"])
        #expect(update.values.isEmpty)
        #expect(PBS.updateRealm(.ldap, "company", update).path == "/config/access/ldap/company")

        var ad = BackupServerRealmDraft(kind: .ad)
        ad.realm = "corp"
        ad.server1 = "dc1.corp.example"
        #expect(ad.problems(isNew: true).isEmpty)
        #expect(ad.creationParameters["user-attr"] == nil)
    }

    @Test func openIDAndBuiltInRealms() {
        var openID = BackupServerRealmDraft(kind: .openid)
        openID.realm = "sso"
        openID.issuerURL = "issuer"
        #expect(Set(openID.problems(isNew: true).keys) == ["issuer-url", "client-id"])
        openID.issuerURL = "https://sso.example.com/realms/main"
        openID.clientID = "pbs"
        openID.autocreate = true
        #expect(openID.creationParameters["autocreate"] == "1")
        #expect(openID.creationParameters["client-key"] == nil)

        var pam = BackupServerRealmDraft(kind: .pam, realm: "pam", config: BackupServerRealmConfig(values: ["comment": "Linux PAM"]))
        let original = pam
        pam.isDefault = true
        let update = pam.update(from: original, digest: nil)
        #expect(update.values == ["default": "1"])
        #expect(PBS.updateRealm(.pam, "pam", update).path == "/config/access/pam")
        #expect(PBS.realmConfig(.pbs, "pbs").path == "/config/access/pbs")

        let sync = PBS.syncRealm("company", dryRun: true, enableNew: false, removeVanished: [.entry, .acl])
        #expect(sync.path == "/access/domains/company/sync")
        #expect(sync.parameters == ["dry-run": true, "enable-new": false, "remove-vanished": "acl;entry"])
    }

    @Test func trafficControlListsAreRepeated() throws {
        var draft = TrafficControlDraft()
        draft.name = "office"
        draft.networks = ["10.0.0.0/8", "192.168.0.0/16"]
        #expect(draft.problems(isNew: true)["rate-in"] != nil)
        draft.rateIn = ByteRate(amount: "50", unit: .mib)
        draft.timeframes = ["mon..fri 8:00-18:00"]
        #expect(draft.problems(isNew: true).isEmpty)
        let parameters = PBS.createTrafficControlRule(draft).parameters
        #expect(parameters.values("network") == ["10.0.0.0/8", "192.168.0.0/16"])
        #expect(parameters["rate-in"] == "50 MiB")
        #expect(parameters.values("timeframe") == ["mon..fri 8:00-18:00"])

        let rule = try JSONDecoder().decode(TrafficControlRule.self, from: Data(
            #"{"name":"office","network":["10.0.0.0/8"],"rate-in":"50 MiB","timeframe":["mon..fri 8:00-18:00"]}"#.utf8))
        let original = TrafficControlDraft(rule)
        var edited = original
        edited.timeframes = []
        edited.networks.append("172.16.0.0/12")
        let update = edited.changes(from: original)
        #expect(update.deletions == ["timeframe"])
        #expect(update.lists == ["network": ["10.0.0.0/8", "172.16.0.0/12"]])
        edited.networks = ["not a network"]
        #expect(edited.problems(isNew: false)["network"] != nil)
    }

    @Test func metricServers() throws {
        var http = BackupServerMetricServerDraft(kind: .influxDBHTTP)
        http.name = "grafana"
        http.url = "influx.lan"
        #expect(http.problems(isNew: true)["url"] != nil)
        http.url = "https://influx.lan:8086"
        http.token = "secret"
        http.verifiesTLS = false
        let parameters = http.creationParameters
        #expect(parameters == ["name": "grafana", "url": "https://influx.lan:8086", "verify-tls": "0", "token": "secret"])
        #expect(PBS.createMetricServer(http).path == "/config/metrics/influxdb-http")

        let stored = BackupServerMetricServerDraft(kind: .influxDBUDP, name: "udp", config: BackupServerRealmConfig(values: ["host": "influx.lan:8089", "enable": "0"]))
        #expect(!stored.isEnabled)
        var edited = stored
        edited.isEnabled = true
        edited.mtu = 9000
        let update = edited.update(from: stored, digest: nil)
        #expect(update.deletions == ["enable"])
        #expect(update.values == ["mtu": "9000"])

        let list = try JSONDecoder().decode([BackupServerMetricServer].self, from: Data(
            #"[{"name":"grafana","type":"influxdb-http","server":"https://influx.lan:8086","enable":true}]"#.utf8))
        #expect(list.first?.kind == .influxDBHTTP)
    }

    @Test func s3EndpointsKeepTheirSecretAndQuirks() throws {
        var draft = S3EndpointDraft()
        draft.id = "minio"
        draft.endpoint = "minio.lan"
        draft.accessKey = "pbs"
        #expect(draft.problems(isNew: true)["secret-key"] != nil)
        draft.secretKey = "secret"
        draft.usesPathStyle = true
        draft.skipsIfNoneMatch = true
        let parameters = draft.creationParameters
        #expect(parameters["secret-key"] == "secret")
        #expect(parameters["path-style"] == "1")
        #expect(parameters.values("provider-quirks") == [.string(S3EndpointDraft.skipIfNoneMatchQuirk)])

        let endpoint = try JSONDecoder().decode(S3Endpoint.self, from: Data(
            #"{"id":"minio","endpoint":"minio.lan","access-key":"pbs","path-style":true,"provider-quirks":["skip-if-none-match-header"]}"#.utf8))
        let original = S3EndpointDraft(endpoint)
        #expect(original.update(from: original, digest: nil).isEmpty)
        var edited = original
        edited.skipsIfNoneMatch = false
        edited.secretKey = "new"
        let update = edited.update(from: original, digest: nil)
        #expect(update.values == ["secret-key": "new"])
        #expect(update.deletions == ["provider-quirks"])
    }

    @Test func encryptionKeyCalls() {
        #expect(PBS.createEncryptionKey("offsite").parameters == ["id": "offsite"])
        #expect(PBS.createEncryptionKey("offsite", importing: "{}").parameters["key"] == "{}")
        #expect(PBS.archiveEncryptionKey("offsite").method == .post)
        #expect(PBS.archiveEncryptionKey("offsite").path == "/config/encryption-keys/offsite")
    }

    @Test func notificationRequestsMoveAndRepeatDeletions() {
        let targets = PBS.notificationRequest(PVE.notificationTargets())
        #expect(targets.path == "/config/notifications/targets")
        let update = PBS.notificationRequest(PVE.updateNotificationMatcher("failed", ["delete": "comment,match-severity", "mode": "any"], digest: "d"))
        #expect(update.path == "/config/notifications/matchers/failed")
        #expect(update.parameters.values("delete") == ["comment", "match-severity"])
        #expect(update.parameters["mode"] == "any")
        #expect(update.parameters["digest"] == "d")
    }

    @Test func realmFixturesDecode() throws {
        let ldap = try envelopeFixture("config-access-ldap", as: Digested<[BackupServerRealmConfig]>.self)
        _ = ldap.value
        let pam = try envelopeFixture("config-access-pam", as: Digested<BackupServerRealmConfig>.self)
        let stored = BackupServerRealmDraft(kind: .pam, realm: "pam", config: pam.value)
        #expect(stored.isDefault)
        #expect(stored.comment == "Linux PAM standard authentication")
    }
}
