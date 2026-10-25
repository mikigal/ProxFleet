import Foundation
@testable import PBSKit
import ProxmoxCore
import PVEKit
import Testing

/// Settings and data of the web interface that came with the comparison after M9.
struct WebUIParityTests {
    @Test func webAuthnSettings() throws {
        let unset = try JSONDecoder().decode(Digested<BackupServerWebAuthnConfig?>.self, from: Data(#"{"data": null, "digest": "abc"}"#.utf8))
        #expect(unset.value == nil && unset.digest == "abc")
        var draft = BackupServerWebAuthnDraft(unset.value)
        #expect(draft.problems.keys.sorted() == ["id", "rp"])
        draft.fill(host: "pbs.lan", port: 8007)
        #expect(draft.relyingParty == "pbs.lan" && draft.id == "pbs.lan" && draft.origin == "https://pbs.lan:8007")
        #expect(draft.problems.isEmpty)
        let created = draft.changes(from: BackupServerWebAuthnDraft(nil), digest: "abc").parameters
        #expect(created["rp"] == "pbs.lan" && created["id"] == "pbs.lan" && created["origin"] == "https://pbs.lan:8007" && created["digest"] == "abc",
                "\(created.formEncoded)")
        var ipv6 = BackupServerWebAuthnDraft()
        ipv6.fill(host: "fd00::6", port: 443)
        #expect(ipv6.origin == "https://[fd00::6]")
        #expect(ipv6.problems.isEmpty)

        let stored = try JSONDecoder().decode(BackupServerWebAuthnConfig.self, from: Data(#"{"rp": "pbs", "id": "pbs.lan", "origin": "https://pbs.lan:8007", "allow-subdomains": false}"#.utf8))
        let original = BackupServerWebAuthnDraft(stored)
        #expect(!original.allowsSubdomains)
        var edited = original
        edited.origin = ""
        edited.allowsSubdomains = true
        // Both may be removed; the ID and name never are.
        #expect(edited.changes(from: original).parameters.formEncoded == "delete=allow-subdomains&delete=origin")
        edited.id = "https://pbs.lan"
        #expect(edited.problems["id"] != nil)
        edited.id = "pbs.lan"
        edited.origin = "pbs.lan"
        #expect(edited.problems["origin"] != nil)
        #expect(PBS.updateWebAuthnConfig(edited.changes(from: original)).path == "/config/access/tfa/webauthn")
    }

    @Test func effectivePermissionsAskForTheAuthID() {
        let request = PBS.effectivePermissions(of: "sync@pbs!remote")
        #expect(request.path == "/access/permissions")
        #expect(request.parameters == ["auth-id": "sync@pbs!remote"])
    }

    @Test func certificateFingerprintOfTheServer() throws {
        let status = try JSONDecoder().decode(NodeStatus.self, from: Data(#"{"cpu": 0.1, "info": {"fingerprint": "8e:58:18"}, "memory": {"used": 1, "total": 2}, "root": {"used": 1, "total": 2}}"#.utf8))
        #expect(status.certificateFingerprint == "8e:58:18")
    }

    @Test func s3StatisticsRefreshAndHistory() throws {
        let status = try JSONDecoder().decode(DatastoreStatus.self, from: Data(#"""
            {"total": 100, "used": 10, "avail": 90, "backend-type": "s3", "counts": {},
             "s3-statistics": {"uploaded": 1024, "downloaded": 512, "get": 3, "put": 4, "post": 1, "head": 9, "delete": 2}}
            """#.utf8))
        #expect(status.s3Statistics == S3Statistics(uploaded: 1024, downloaded: 512, get: 3, put: 4, post: 1, head: 9, delete: 2))
        let refresh = PBS.refreshFromS3("s3 archive")
        #expect(refresh.method == .put)
        #expect(refresh.path == "/admin/datastore/s3%20archive/s3-refresh")

        let points = try JSONDecoder().decode([DatastoreRRDPoint].self, from: Data(#"""
            [{"time": 1, "read_ios": 30, "write_ios": 10, "io_ticks": 0.02, "s3/uploaded": 2048, "s3/downloaded": 64},
             {"time": 2, "read_ios": 0, "write_ios": 0, "io_ticks": 0}, {"time": 3}]
            """#.utf8))
        // As the web interface works it out: busy time per operation in milliseconds.
        #expect(points[0].ioDelay == 0.5)
        #expect(points[0].s3Uploaded == 2048 && points[0].s3Downloaded == 64)
        #expect(points[1].ioDelay == 0)
        #expect(points[2].ioDelay == nil)
    }

    @Test func s3NotificationThresholds() throws {
        let config = try JSONDecoder().decode(DatastoreConfig.self, from: Data(#"""
            {"name": "s3-archive", "path": "/mnt/s3-cache", "backend": "type=s3,client=minio,bucket=pbs",
             "notification-thresholds": "s3-put=200000,s3-upload=500GiB", "counter-reset-schedule": "monthly"}
            """#.utf8))
        let original = DatastoreDraft(config)
        #expect(original.kind == .s3)
        #expect(original.notificationThresholds["s3-put"] == "200000")
        #expect(original.counterResetSchedule == "monthly")
        var edited = original
        edited.notificationThresholds["s3-get"] = "50000"
        edited.notificationThresholds["s3-upload"] = nil
        edited.counterResetSchedule = ""
        let update = edited.changes(from: original)
        #expect(update.parameters["notification-thresholds"] == "s3-put=200000,s3-get=50000")
        #expect(update.parameters.formEncoded.contains("delete=counter-reset-schedule"))
        edited.notificationThresholds["s3-get"] = "many"
        #expect(edited.problems(isNew: false)["notification-thresholds"] != nil)
        edited.notificationThresholds["s3-get"] = "5"
        edited.notificationThresholds["s3-download"] = "1.5 TiB"
        #expect(edited.problems(isNew: false)["notification-thresholds"] == nil)

        // Other datastores never send them.
        let local = DatastoreDraft(try JSONDecoder().decode(DatastoreConfig.self, from: Data(#"{"name": "main", "path": "/mnt/main"}"#.utf8)))
        #expect(local.serialized()["notification-thresholds"] == nil)
    }

    @Test func s3EndpointDeletesObjectsOneByOne() throws {
        let endpoint = try JSONDecoder().decode(S3Endpoint.self, from: Data(#"{"id": "minio", "endpoint": "minio.lan", "access-key": "pbs", "provider-quirks": ["delete-objects-via-delete-object", "future-quirk"]}"#.utf8))
        let original = S3EndpointDraft(endpoint)
        #expect(original.deletesObjectsOneByOne && !original.skipsIfNoneMatch)
        var edited = original
        edited.deletesObjectsOneByOne = false
        edited.skipsIfNoneMatch = true
        // Quirks the app does not know stay.
        #expect(edited.update(from: original, digest: nil).parameters.formEncoded == "provider-quirks=future-quirk&provider-quirks=skip-if-none-match-header")
        #expect(PBSFeature.s3DeleteObjectsOneByOne.introduced == PVEVersionNumber(4, 2))
    }

    @Test func snapshotNamesForClients() {
        let snapshot = BackupGroupReference(type: .vm, backupID: "102").snapshot(at: 1_792_850_992)
        #expect(snapshot.name == "vm/102/2026-10-24T14:09:52Z")
    }

    @Test func namespaceMovesCanKeepTheSource() {
        let namespace = BackupNamespace("homelab/old")
        let full = PBS.moveNamespace("main", namespace, to: BackupNamespace("archive/old"), mergeGroups: true)
        #expect(full.parameters == ["ns": "homelab/old", "target-ns": "archive/old", "merge-groups": true])
        let partial = PBS.moveNamespace("main", namespace, to: BackupNamespace("archive/old"), mergeGroups: false, deletesSource: false, maxDepth: 0)
        #expect(partial.parameters == ["ns": "homelab/old", "target-ns": "archive/old", "merge-groups": false, "delete-source": false, "max-depth": 0])
    }
}
