import DemoServer
@testable import FleetCore
import Foundation
import PBSKit
import ProxmoxCore
import PVEKit
import Testing

/// What the comparison with the web interface added, against the demo backup server.
@MainActor
struct BackupServerParityTests {
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

    @Test func notesAndFingerprintOfTheServer() async throws {
        let connection = try await connectedDemo()
        #expect(connection.backupServer?.status?.certificateFingerprint?.hasPrefix("3a:9f") == true)
        let node = NodeDetail(node: PBS.node, connection: connection)
        await node.loadOptions()
        let original = BackupServerNodeOptionsDraft(try #require(node.backupServerOptions))
        #expect(original.description.hasPrefix("**Home lab backups.**"))
        var edited = original
        edited.description = "Rack 2, shelf 3"
        try await node.saveBackupServerOptions(edited.changes(from: original))
        #expect(node.backupServerOptions?.values["description"] == "Rack 2, shelf 3")
    }

    @Test func effectivePermissionsOfUsersAndTokens() async throws {
        let access = BackupServerAccess(connection: try await connectedDemo())
        let anna = try await access.effectivePermissions(of: "anna@pbs")
        #expect(anna == [EffectivePermission(path: "/datastore/main/laptops", privileges: ["Datastore.Backup", "Datastore.Prune"])])
        // A token never has more than its user, who has no entries here.
        #expect(try await access.effectivePermissions(of: "monitoring@pbs!zabbix").isEmpty)
    }

    @Test func webAuthnSettings() async throws {
        let access = BackupServerAccess(connection: try await connectedDemo())
        #expect(access.canChangeWebAuthn)
        let unset = try await access.webAuthn()
        #expect(unset.value == nil)
        var draft = BackupServerWebAuthnDraft(unset.value)
        draft.fill(host: "pbs.lan", port: 8007)
        try await access.updateWebAuthn(draft.changes(from: BackupServerWebAuthnDraft(nil), digest: unset.digest))
        let stored = try await access.webAuthn()
        #expect(stored.value == BackupServerWebAuthnConfig(relyingParty: "pbs.lan", origin: "https://pbs.lan:8007", id: "pbs.lan", allowsSubdomains: true))
        var edited = BackupServerWebAuthnDraft(stored.value)
        edited.allowsSubdomains = false
        edited.origin = ""
        try await access.updateWebAuthn(edited.changes(from: BackupServerWebAuthnDraft(stored.value), digest: stored.digest))
        #expect(try await access.webAuthn().value?.origin == nil)
        // A digest from before the change is refused.
        await #expect(throws: ConfigUpdateError.conflict) {
            try await access.updateWebAuthn(draft.changes(from: BackupServerWebAuthnDraft(nil), digest: stored.digest))
        }
    }

    @Test func s3DatastoreStatisticsThresholdsAndRefresh() async throws {
        let connection = try await connectedDemo()
        let detail = DatastoreDetail(store: "s3-archive", connection: connection)
        await detail.load()
        #expect(detail.config?.isS3 == true)
        let statistics = try #require(detail.status?.s3Statistics)
        #expect(statistics.uploaded > 0 && statistics.put > 0)
        #expect(detail.history.contains { $0.s3Uploaded != nil && $0.ioDelay != nil })

        let original = DatastoreDraft(try #require(detail.config))
        #expect(original.notificationThresholds["s3-upload"] == "500GiB")
        var edited = original
        edited.notificationThresholds["s3-get"] = "100000"
        edited.counterResetSchedule = "weekly"
        try await detail.save(edited.changes(from: original))
        #expect(DatastoreDraft(try #require(detail.config)).notificationThresholds["s3-get"] == "100000")
        #expect(detail.config?.values["counter-reset-schedule"] == "weekly")

        let refresh = try await detail.refreshFromS3()
        #expect(refresh.title == "s3-archive – S3 Refresh")
        #expect(await connection.tasks.result(of: refresh.id) == .succeeded)
        await #expect(throws: ConfigUpdateError.self) {
            try await DatastoreDetail(store: "main", connection: connection).refreshFromS3()
        }
    }

    @Test func movingANamespaceCanKeepTheSource() async throws {
        let content = DatastoreContent(store: "main", connection: try await connectedDemo())
        await content.load()
        let laptops = BackupNamespace("laptops")
        let task = try await content.moveNamespace(laptops, to: BackupNamespace("devices"), deletesSource: false)
        #expect(await content.connection.tasks.result(of: task.id) == .succeeded)
        let paths = await content.allNamespaces().map(\.path)
        #expect(paths.contains("devices") && paths.contains("laptops"))
    }
}
