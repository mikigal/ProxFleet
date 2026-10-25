import DemoServer
@testable import FleetCore
import Foundation
import PBSKit
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct BackupServerConfigurationTests {
    private func connectedDemo() async throws -> ServerConnection {
        let fleet = Fleet(environment: FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in
            DemoBackupServerTransport()
        })
        let profile = fleet.addSaved(ServerProfile(name: "pbs", product: .backupServer, addresses: [ServerAddress(host: "pbs.lan", port: 8007)],
                                                   username: "root", realm: "pam"), password: "secret")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        return connection
    }

    @Test func usersTokensAndPermissions() async throws {
        let access = BackupServerAccess(connection: try await connectedDemo())
        await access.load()
        #expect(access.loadError == nil)
        #expect(access.users?.map(\.id).contains("backup@pbs") == true)
        #expect(access.authIDs.contains("backup@pbs!pve"))
        #expect(access.roles?.contains { $0.id == "DatastoreAdmin" } == true)
        #expect(access.realms?.map(\.realm) == ["pam", "pbs", "home"])
        #expect(access.canManageUsers && access.canModifyPermissions && access.canManageRealms)

        var draft = BackupServerUserDraft()
        draft.userID = "sync@pbs"
        draft.password = "a-long-password"
        draft.passwordConfirmation = "a-long-password"
        draft.comment = "Sync"
        try await access.createUser(draft)
        let created = try #require(access.users?.first { $0.id == "sync@pbs" })
        #expect(created.comment == "Sync")
        var edited = BackupServerUserDraft(created)
        edited.isEnabled = false
        edited.comment = ""
        try await access.updateUser(created.id, edited.changes(from: BackupServerUserDraft(created)))
        #expect(access.users?.first { $0.id == "sync@pbs" }?.isEnabled == false)
        #expect(access.users?.first { $0.id == "sync@pbs" }?.comment == nil)
        try await access.changePassword(of: "sync@pbs", to: "another-password", confirmation: nil)
        await #expect(throws: ConfigUpdateError.self) { try await access.changePassword(of: "sync@pbs", to: "short", confirmation: nil) }

        var token = BackupServerTokenDraft()
        token.name = "remote"
        let secret = try await access.createToken(of: "sync@pbs", token)
        #expect(secret.tokenID == "sync@pbs!remote")
        #expect(!secret.secret.isEmpty)
        #expect(access.users?.first { $0.id == "sync@pbs" }?.tokens.map(\.id) == ["sync@pbs!remote"])
        #expect(try await !access.regenerateToken(of: "sync@pbs", name: "remote").secret.isEmpty)

        let entry = BackupServerACLEntry(path: "/datastore/main", authID: "sync@pbs!remote", role: "DatastoreBackup")
        try await access.addPermission(entry)
        #expect(access.permissions(of: "sync@pbs!remote") == [entry])
        try await access.removePermission(entry)
        #expect(access.permissions(of: "sync@pbs!remote").isEmpty)

        try await access.deleteToken(of: "sync@pbs", name: "remote")
        try await access.deleteUser("sync@pbs")
        #expect(access.users?.contains { $0.id == "sync@pbs" } == false)
        await #expect(throws: ConfigUpdateError.self) { try await access.deleteUser("root@pam") }
    }

    @Test func realmsAndSync() async throws {
        let connection = try await connectedDemo()
        let access = BackupServerAccess(connection: connection)
        await access.load()
        let home = try await access.realmConfig(.ldap, "home")
        let stored = BackupServerRealmDraft(kind: .ldap, realm: "home", config: home.value)
        #expect(stored.mode == "ldaps")
        #expect(stored.verifiesCertificate)

        var edited = stored
        edited.comment = "Family directory"
        edited.isDefault = true
        try await access.updateRealm(.ldap, "home", edited.update(from: stored, digest: home.digest))
        #expect(access.realms?.first { $0.realm == "home" }?.isDefault == true)
        #expect(access.realms?.first { $0.realm == "pam" }?.isDefault == false)

        let dryRun = try await access.syncRealm("home", dryRun: true, enableNew: true, removeVanished: [])
        #expect(await connection.tasks.result(of: dryRun.id) == .succeeded)
        await access.load()
        #expect(access.users?.contains { $0.id == "maria@home" } == false)
        let sync = try await access.syncRealm("home", dryRun: false, enableNew: true, removeVanished: [.acl])
        #expect(await connection.tasks.result(of: sync.id) == .succeeded)
        await access.load()
        #expect(access.users?.contains { $0.id == "maria@home" } == true)

        var openID = BackupServerRealmDraft(kind: .openid)
        openID.realm = "sso"
        openID.issuerURL = "https://sso.example.com"
        openID.clientID = "pbs"
        try await access.createRealm(openID)
        #expect(access.realms?.contains { $0.realm == "sso" && $0.type == "openid" } == true)
        try await access.deleteRealm(.openid, "sso")
        #expect(access.realms?.contains { $0.realm == "sso" } == false)
    }

    @Test func secondFactorsThroughTheSharedScreensModel() async throws {
        let access = AccessControl(connection: try await connectedDemo())
        await access.load()
        #expect(access.loadError == nil)
        #expect(access.twoFactors(of: "root@pam")?.entries.map(\.type) == ["totp"])
        #expect(access.users?.isEmpty == false)
        #expect(access.can("User.Modify"))
        let keys = try await access.addRecoveryKeys(for: "anna@pbs", password: nil)
        #expect(keys.count == 10)
        #expect(access.twoFactors(of: "anna@pbs")?.hasRecoveryKeys == true)
        try await access.deleteTwoFactor(of: "anna@pbs", id: "recovery", password: nil)
        #expect(access.twoFactors(of: "anna@pbs") == nil)
    }

    @Test func notificationsThroughTheSharedScreensModel() async throws {
        let settings = DatacenterSettings(connection: try await connectedDemo())
        await settings.loadNotifications()
        #expect(settings.loadError == nil)
        #expect(settings.targets?.map(\.name) == ["mail-to-root", "phone"])
        #expect(settings.matchers?.map(\.name) == ["default-matcher", "failed-jobs"])
        #expect(settings.fieldValues.contains { $0.field == "type" && $0.value == "gc" })
        #expect(settings.canModifyNotifications && settings.canModifyEndpoints)

        let matcher = try #require(settings.matchers?.first { $0.name == "failed-jobs" })
        var draft = NotificationMatcherDraft(matcher)
        draft.comment = ""
        draft.severities = []
        // Two cleared settings: the backup server takes them as two `delete` parameters.
        try await settings.updateMatcher(matcher.name, draft.changes(from: NotificationMatcherDraft(matcher)), digest: nil)
        let updated = try #require(settings.matchers?.first { $0.name == "failed-jobs" })
        #expect(updated.comment == nil)
        try await settings.test("mail-to-root")
        await #expect(throws: ConfigUpdateError.self) { try await settings.test("phone") }
    }

    @Test func trafficControlAndMetricServers() async throws {
        let settings = BackupServerSettings(connection: try await connectedDemo())
        await settings.loadTrafficControl()
        #expect(settings.trafficRules?.map(\.name) == ["office-hours"])
        #expect((settings.currentTraffic["office-hours"]?.currentRateIn ?? 0) > 0)
        var rule = TrafficControlDraft()
        rule.name = "nightly-sync"
        rule.networks = ["10.0.20.0/24"]
        rule.rateOut = ByteRate(amount: "200", unit: .mib)
        try await settings.createTrafficRule(rule)
        let created = try #require(settings.trafficRules?.first { $0.name == "nightly-sync" })
        #expect(created.networks == ["10.0.20.0/24"])
        var edited = TrafficControlDraft(created)
        edited.timeframes = ["0:00-6:00"]
        try await settings.updateTrafficRule(created.name, edited.changes(from: TrafficControlDraft(created)))
        #expect(settings.trafficRules?.first { $0.name == "nightly-sync" }?.timeframes == ["0:00-6:00"])
        try await settings.deleteTrafficRule("nightly-sync")

        await settings.loadMetricServers()
        let grafana = try #require(settings.metricServers?.first)
        #expect(grafana.kind == .influxDBHTTP)
        let config = try await settings.metricServerConfig(grafana)
        #expect(BackupServerMetricServerDraft(kind: .influxDBHTTP, name: grafana.name, config: config.value).bucket == "pbs")
        var udp = BackupServerMetricServerDraft(kind: .influxDBUDP)
        udp.name = "telegraf"
        udp.host = "telegraf.lan:8089"
        try await settings.createMetricServer(udp)
        #expect(settings.metricServers?.contains { $0.name == "telegraf" && $0.server == "telegraf.lan:8089" } == true)
        try await settings.deleteMetricServer(.influxDBUDP, "telegraf")
        #expect(settings.metricServers?.map(\.name) == ["grafana"])
    }

    @Test func s3EndpointsAndEncryptionKeys() async throws {
        let settings = BackupServerSettings(connection: try await connectedDemo())
        await settings.loadS3Endpoints()
        let minio = try #require(settings.s3Endpoints?.first)
        #expect(minio.usesPathStyle)
        guard case .success(let buckets) = await settings.buckets(of: minio.id) else { Issue.record("expected buckets"); return }
        #expect(buckets == ["pbs-offsite", "photos"])
        var edited = S3EndpointDraft(minio)
        edited.region = "eu-central-1"
        edited.secretKey = "rotated"
        try await settings.updateS3Endpoint(minio.id, edited.update(from: S3EndpointDraft(minio), digest: nil))
        #expect(settings.s3Endpoints?.first?.region == "eu-central-1")
        // The secret is not listed.
        #expect(settings.s3Endpoints?.first?.values["secret-key"] == nil)

        await settings.loadEncryptionKeys()
        #expect(settings.encryptionKeys?.map(\.id) == ["cloud-2026", "cloud-2025"])
        try await settings.createEncryptionKey("offsite-2027")
        try await settings.archiveEncryptionKey("offsite-2027")
        #expect(settings.encryptionKeys?.first { $0.id == "offsite-2027" }?.isArchived == true)
        try await settings.deleteEncryptionKey("offsite-2027")
        // A key a sync job uses stays.
        await #expect(throws: ConfigUpdateError.self) { try await settings.deleteEncryptionKey("cloud-2026") }
    }
}
