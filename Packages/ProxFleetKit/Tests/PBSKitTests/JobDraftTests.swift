import Foundation
@testable import PBSKit
import ProxmoxCore
import Testing

struct JobDraftTests {
    private func syncJob(_ json: String) throws -> SyncJob {
        try JSONDecoder().decode(SyncJob.self, from: Data(json.utf8))
    }

    @Test func pushJobRoundTripsWithoutChanges() throws {
        let job = try #require(try fixture("admin-sync-push", as: [SyncJob].self).first)
        let draft = SyncJobDraft(job)
        #expect(draft.direction == .push)
        #expect(draft.groupFilters == [GroupFilter(kind: .type, value: "host")])
        #expect(draft.changes(from: draft).isEmpty)
        // The state fields of the list are not settings.
        #expect(draft.serialized()["last-run-state"] == nil)
    }

    @Test func groupFiltersAreSentOneByOneAndClearedWithDelete() throws {
        let original = SyncJobDraft(try syncJob(#"{"id":"s","store":"a","remote":"r","remote-store":"b","group-filter":["type:vm","exclude:group:vm/103"]}"#))
        #expect(original.groupFilters == [GroupFilter(kind: .type, value: "vm"), GroupFilter(kind: .group, value: "vm/103", excludes: true)])
        var draft = original
        draft.groupFilters.append(GroupFilter(kind: .regex, value: "^ct/2\\d\\d$"))
        let added = draft.changes(from: original, digest: "abc").parameters
        #expect(added.values("group-filter") == ["type:vm", "exclude:group:vm/103", #"regex:^ct/2\d\d$"#])
        #expect(added["digest"] == "abc")
        draft.groupFilters = []
        let cleared = draft.changes(from: original).parameters
        #expect(cleared.values("delete") == ["group-filter"])
        #expect(cleared.values("group-filter").isEmpty)
    }

    @Test func switchingToALocalPullDropsTheRemoteAndRate() throws {
        let original = SyncJobDraft(try syncJob(#"{"id":"s","store":"a","remote":"r","remote-store":"b","rate-in":"20 MiB"}"#))
        #expect(original.rateLimit == ByteRate(amount: "20", unit: .mib))
        var draft = original
        draft.isLocal = true
        draft.remoteStore = "c"
        let update = draft.changes(from: original)
        #expect(update.deletions == ["remote", "rate-in"])
        #expect(update.values == ["remote-store": "c"])
    }

    @Test func pushJobsUseTheOutgoingRateAndTheirDirection() {
        var draft = SyncJobDraft(direction: .push, store: "main", owner: "root@pam")
        draft.remote = "cloud"
        draft.remoteStore = "copy"
        draft.rateLimit = ByteRate(amount: "1.5", unit: .gib)
        draft.resyncCorrupt = true
        draft.activeEncryptionKey = "key-2026"
        draft.associatedKeys = ["key-2025"]
        let parameters = draft.creationParameters
        #expect(parameters["sync-direction"] == "push")
        #expect(parameters["rate-out"] == "1.5 GiB")
        #expect(parameters["rate-in"] == nil)
        // Re-syncing corrupt snapshots applies to pulls only.
        #expect(parameters["resync-corrupt"] == nil)
        #expect(parameters["active-encryption-key"] == "key-2026")
        #expect(parameters.values("associated-key") == ["key-2025"])
    }

    @Test func newJobsGetIDsLikeTheWebInterface() throws {
        let sync = SyncJobDraft(direction: .pull, store: "main")
        guard case .string(let syncID) = try #require(sync.creationParameters["id"]) else { Issue.record("no ID"); return }
        #expect(syncID.hasPrefix("s-") && syncID.count == 15)
        // Pull jobs leave the direction out, which servers before 3.3 do not know.
        #expect(sync.creationParameters["sync-direction"] == nil)
        guard case .string(let verifyID) = try #require(VerifyJobDraft(store: "main").creationParameters["id"]) else { Issue.record("no ID"); return }
        #expect(verifyID.hasPrefix("v-") && verifyID.count == 15)
        var named = PruneJobDraft(store: "main")
        named.id = "nightly"
        #expect(named.creationParameters["id"] == "nightly")
    }

    @Test func syncJobProblems() {
        var draft = SyncJobDraft(direction: .pull, store: "main")
        draft.id = "x"
        #expect(Set(draft.problems(isNew: true).keys) == ["id", "remote", "remote-store"])
        draft.id = ""
        draft.isLocal = true
        draft.remoteStore = "main"
        #expect(draft.problems(isNew: true)["remote-store"] != nil)
        draft.remoteNamespace = "homelab"
        draft.groupFilters = [GroupFilter(kind: .group, value: " ")]
        #expect(Set(draft.problems(isNew: true).keys) == ["group-filter"])
    }

    @Test(arguments: [
        ("type:vm", GroupFilter(kind: .type, value: "vm")),
        ("group:ct/200", GroupFilter(kind: .group, value: "ct/200")),
        ("exclude:regex:^vm/1.*", GroupFilter(kind: .regex, value: "^vm/1.*", excludes: true)),
        ("regex:a:b", GroupFilter(kind: .regex, value: "a:b")),
    ])
    func groupFilters(text: String, filter: GroupFilter) throws {
        #expect(GroupFilter(parsing: text) == filter)
        #expect(filter.stringValue == text)
    }

    @Test func unknownGroupFiltersAreSkipped() {
        #expect(GroupFilter(parsing: "owner:root@pam") == nil)
        #expect(GroupFilter(parsing: "vm") == nil)
    }

    @Test(arguments: [
        ("20 MiB", ByteRate(amount: "20", unit: .mib)),
        ("1.5GiB", ByteRate(amount: "1.5", unit: .gib)),
        ("512 kib", ByteRate(amount: "512", unit: .kib)),
        ("2097152", ByteRate(amount: "2", unit: .mib)),
    ])
    func rates(text: String, rate: ByteRate) {
        #expect(ByteRate(parsing: text) == rate)
    }

    @Test func emptyOrZeroRatesMeanNoLimit() {
        #expect(ByteRate(parsing: nil).stringValue == nil)
        #expect(ByteRate(amount: "0").stringValue == nil)
        #expect(ByteRate(amount: "abc").stringValue == nil)
    }

    @Test func verifyJobsStoreOnlyTurningSkippingOff() throws {
        let job = try #require(try fixture("admin-verify", as: [VerifyJob].self).first)
        let original = VerifyJobDraft(job)
        #expect(original.skipVerified && original.reverifyAfterDays == 30)
        var draft = original
        draft.skipVerified = false
        let update = draft.changes(from: original)
        #expect(update.values == ["ignore-verified": "0"])
        // Re-verifying old snapshots only applies while verified ones are skipped.
        #expect(update.deletions == ["outdated-after"])
        draft.skipVerified = true
        draft.reverifyAfterDays = nil
        #expect(draft.changes(from: original).deletions == ["outdated-after"])
        #expect(VerifyJobDraft(store: "main").creationParameters["ignore-verified"] == nil)
    }

    @Test func pruneJobs() throws {
        let job = try #require(try fixture("admin-prune", as: [PruneJob].self).first)
        let original = PruneJobDraft(job)
        var draft = original
        draft.isEnabled = false
        draft.retention.daily = nil
        let update = draft.changes(from: original)
        #expect(update.values == ["disable": "1"])
        #expect(update.deletions == ["keep-daily"])
        var empty = PruneJobDraft(store: "main")
        empty.schedule = ""
        #expect(Set(empty.problems(isNew: true).keys) == ["schedule", "keep-last"])
        empty.schedule = "daily"
        empty.retention.last = 5
        #expect(empty.problems(isNew: true).isEmpty)
        #expect(empty.creationParameters["keep-last"] == "5")
        #expect(empty.creationParameters["disable"] == nil)
    }

    @Test func remotesSplitHostAndPort() throws {
        var draft = RemoteDraft()
        draft.name = "offsite"
        draft.address = "pbs.example.net:8008"
        draft.authID = "sync@pbs!job"
        draft.password = "secret"
        #expect(draft.problems(isNew: true).isEmpty)
        let parameters = draft.creationParameters
        #expect(parameters["host"] == "pbs.example.net")
        #expect(parameters["port"] == "8008")
        #expect(parameters["password"] == "secret")
        #expect(parameters["use-node-proxy"] == nil)

        draft.address = "[fd00::5]"
        #expect(draft.serialized()["host"] == "fd00::5")
        #expect(draft.serialized()["port"] == .some(nil))
    }

    @Test func editedRemotesSendThePasswordOnlyWhenTyped() throws {
        let remote = try JSONDecoder().decode(BackupRemote.self, from: Data(#"{"name":"cloud","host":"pbs.example.net","port":8008,"auth-id":"sync@pbs","fingerprint":"ab"}"#.utf8))
        let original = RemoteDraft(remote)
        #expect(original.address == "pbs.example.net:8008")
        var draft = original
        #expect(draft.update(from: original, digest: nil).isEmpty)
        draft.address = "pbs.example.net"
        draft.fingerprint = ""
        var update = draft.update(from: original, digest: nil)
        #expect(update.deletions == ["port", "fingerprint"])
        #expect(update.values["password"] == nil)
        draft.password = "new"
        update = draft.update(from: original, digest: nil)
        #expect(update.values["password"] == "new")
        // The name cannot change and a stored password is not needed again.
        draft.authID = "sync"
        #expect(Set(draft.problems(isNew: false).keys) == ["auth-id"])
    }

    @Test func jobRequests() {
        var update = BackupServerConfigUpdate(digest: "d")
        update.set("comment", "x")
        #expect(PBS.updateSyncJob("s-1", update).path == "/config/sync/s-1")
        #expect(PBS.updateSyncJob("s-1", update).method == .put)
        #expect(PBS.createVerifyJob(["id": "v"]).path == "/config/verify")
        #expect(PBS.updatePruneJob("p", update).parameters["digest"] == "d")
        #expect(PBS.updateRemote("cloud", update).path == "/config/remote/cloud")
        #expect(PBS.encryptionKeys(includeArchived: true).parameters == ["include-archived": true])
    }
}
