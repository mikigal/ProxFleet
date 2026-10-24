import CryptoKit
import Foundation
import PBSKit
import ProxmoxConsole
import ProxmoxCore
import ProxmoxURLSession
import PVEKit
import Synchronization
import Testing

/// Settings from the env file named by `PROXFLEET_PBS_TEST_SERVER_ENV`, a Proxmox Backup Server prepared with
/// `scripts/seed-backup-server.py`. Without it, every test in this file is skipped.
private struct LiveBackupServer {
    var values: [String: String]

    static let current: LiveBackupServer? = {
        guard let path = ProcessInfo.processInfo.environment["PROXFLEET_PBS_TEST_SERVER_ENV"],
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return LiveBackupServer(values: values)
    }()

    var address: ServerAddress { ServerAddress(parsing: values["ADDRESS"] ?? "", defaultPort: 8007)! }

    subscript(key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
}

@Suite(.enabled(if: LiveBackupServer.current != nil, "Set PROXFLEET_PBS_TEST_SERVER_ENV to run against a real backup server"), .serialized, .timeLimit(.minutes(5)))
struct LiveBackupServerTests {
    fileprivate let server = LiveBackupServer.current!

    /// Accepts the certificate the way a user would, and returns a session using it.
    private func trustedSession(product: ProxmoxProduct = .backupServer) async throws -> ProxmoxSession {
        let transport = URLSessionTransport()
        let probe = ProxmoxSession(address: server.address, product: product, transport: transport)
        do {
            _ = try await probe.sendUnauthenticated(ProxmoxAccess.realms())
        } catch ProxmoxError.untrustedCertificate(let certificate) {
            if let expected = server["FINGERPRINT"] {
                #expect(certificate.sha256Fingerprint == expected.uppercased())
            }
            transport.pin(certificate.sha256Fingerprint)
        }
        return ProxmoxSession(address: server.address, product: product, transport: transport)
    }

    fileprivate func signedIn(user: String? = nil, realm: String? = nil, password: String? = nil) async throws -> ProxmoxSession {
        let session = try await trustedSession()
        let outcome = try await session.login(username: try #require(user ?? server["USER"]), password: try #require(password ?? server["PASSWORD"]), realm: realm ?? server["REALM"])
        guard case .authenticated = outcome else { throw ProxmoxError.invalidResponse("expected a full ticket") }
        return session
    }

    /// Waits for a task to stop and returns its final status.
    private func wait(for upid: String, in session: ProxmoxSession) async throws -> TaskStatus {
        for _ in 0..<240 {
            let status = try await session.send(PBS.taskStatus(upid: upid))
            if !status.isRunning { return status }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ProxmoxError.invalidResponse("task \(upid) did not finish")
    }

    private static func totp(secret: String, at date: Date = Date()) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var key = Data()
        for character in secret.uppercased() {
            guard let index = alphabet.firstIndex(of: character) else { continue }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                key.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let hash = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        let offset = Int(hash[hash.count - 1] & 0x0F)
        let code = (UInt32(hash[offset] & 0x7F) << 24 | UInt32(hash[offset + 1]) << 16 | UInt32(hash[offset + 2]) << 8 | UInt32(hash[offset + 3])) % 1_000_000
        return String(format: "%06d", code)
    }

    // MARK: - Connecting

    @Test func certificateIsPinnedAndTheProductRecognized() async throws {
        let unpinned = ProxmoxSession(address: server.address, product: .backupServer, transport: URLSessionTransport())
        await #expect(throws: ProxmoxError.self) {
            _ = try await unpinned.detectProduct()
        }
        let session = try await trustedSession(product: .virtualEnvironment)
        #expect(try await session.detectProduct() == .backupServer)
        let realms = try await session.sendUnauthenticated(ProxmoxAccess.realms())
        #expect(Set(realms.map(\.realm)).isSuperset(of: ["pam", "pbs"]))
    }

    @Test func passwordLoginRenewalAndVersion() async throws {
        let session = try await signedIn()
        let renewed = try await session.renewTicket()
        #expect(renewed.ticket.hasPrefix("PBS:"))
        let version = try await session.send(PBS.version())
        #expect(version.isSupported)
        #expect(version.number != nil)
        let node = try #require(try await session.send(PBS.nodes()).first)
        #expect(!node.name.isEmpty)
    }

    @Test func wrongPasswordIsUnauthorized() async throws {
        let session = try await trustedSession()
        do {
            _ = try await session.login(username: try #require(server["USER"]), password: "not-the-password", realm: server["REALM"])
            Issue.record("expected the password to be refused")
        } catch ProxmoxError.unauthorized {
        }
    }

    @Test func secondFactorLogin() async throws {
        let session = try await trustedSession()
        let outcome = try await session.login(username: try #require(server["TFA_USER"]), password: try #require(server["TFA_PASSWORD"]), realm: server["TFA_REALM"])
        guard case .needsSecondFactor(let challenge) = outcome else {
            Issue.record("expected a second factor challenge")
            return
        }
        #expect(challenge.totp)
        let ticket = try await session.completeLogin(challenge, method: .totp, code: Self.totp(secret: try #require(server["TFA_TOTP_SECRET"])))
        #expect(ticket.username == "tfa@pbs")
        #expect(try await !session.send(PBS.datastores()).isEmpty)
    }

    @Test func limitedUserSeesOnlyItsDatastore() async throws {
        let session = try await signedIn(user: server["LIMITED_USER"], realm: server["LIMITED_REALM"], password: server["LIMITED_PASSWORD"])
        #expect(try await session.send(PBS.datastores()).map(\.store) == ["store1"])
    }

    @Test func errorsCarryMessagesAndFieldErrors() async throws {
        let session = try await signedIn()
        await #expect(throws: ProxmoxError.api(status: 400, message: "no such datastore 'missing'", fieldErrors: [:])) {
            _ = try await session.send(PBS.datastoreStatus("missing"))
        }
        do {
            _ = try await session.send(APIRequest<Nothing>(.get, "/nodes/localhost/disks/smart", parameters: ["disk": "not a disk"]))
            Issue.record("expected an error")
        } catch ProxmoxError.api(_, _, let fieldErrors) {
            #expect(fieldErrors["disk"] != nil)
        }
    }

    // MARK: - Reading

    @Test func serverAndDatastoresDecode() async throws {
        let session = try await signedIn()
        let status = try await session.send(PBS.nodeStatus())
        #expect(status.cpuCount > 0 && status.rootTotal > 0)
        #expect(try await session.send(PBS.nodeRRD(timeframe: .hour)).contains(where: \.hasData))
        let stores = try await session.send(PBS.datastores())
        #expect(stores.contains { $0.store == "store1" })
        let usage = try await session.send(PBS.datastoreUsage())
        #expect(usage.first { $0.store == "store1" }?.total ?? 0 > 0)
        let datastore = try await session.send(PBS.datastoreStatus("store1"))
        #expect(datastore.counts[.ct]?.snapshots ?? 0 > 0)
        _ = try await session.send(PBS.garbageCollectionStatus("store1"))
        #expect(try await session.send(PBS.garbageCollectionJobs()).count == stores.count)
        _ = try await session.send(PBS.datastoreRRD("store1", timeframe: .day))
        let configs = try await session.send(PBS.datastoreConfigs())
        #expect(configs.digest != nil)
        #expect(try await session.send(PBS.datastoreConfig("store1")).value.path == "/datastore/store1")
    }

    @Test func contentDecodes() async throws {
        let session = try await signedIn()
        let namespaces = try await session.send(PBS.namespaces("store1"))
        #expect(namespaces.contains(BackupNamespace("pve/nested")))
        let pve = BackupNamespace("pve")
        let groups = try await session.send(PBS.groups("store1", namespace: pve)).map { $0.in(pve) }
        let container = try #require(groups.first { $0.reference.type == .ct })
        let snapshots = try await session.send(PBS.snapshots("store1", group: container.reference)).map { $0.in(pve) }
        #expect(snapshots.count == container.snapshotCount)
        let snapshot = try #require(snapshots.first)
        #expect(try await !session.send(PBS.snapshotFiles("store1", snapshot.reference)).isEmpty)
        let archives = try await session.send(PBS.catalog("store1", snapshot.reference, filePath: "/"))
        let archive = try #require(archives.first)
        #expect(try await session.send(PBS.catalog("store1", snapshot.reference, filePath: archive.filePath)).contains { $0.name == "etc" })
        _ = try await session.send(PBS.groupNotes("store1", container.reference))
    }

    @Test func jobsAndRemotesDecode() async throws {
        let session = try await signedIn()
        let sync = try await session.send(PBS.syncJobs()).value
        #expect(Set(sync.map(\.direction)) == [.pull, .push])
        #expect(try await !session.send(PBS.verifyJobs()).value.isEmpty)
        #expect(try await !session.send(PBS.pruneJobs()).value.isEmpty)
        let remote = try #require(try await session.send(PBS.remotes()).value.first)
        #expect(try await session.send(PBS.remoteDatastores(remote.name)).contains { $0.store == "store1" })
        _ = try await session.send(PBS.trafficControlStatus())
        let tasks = try await session.send(PBS.tasks(BackupServerTaskFilter(limit: 100)))
        #expect(tasks.allSatisfy { UPID($0.upid)?.objectID == ($0.objectID ?? "") })
    }

    // MARK: - Tasks and downloads

    @Test func verifyingASnapshotIsFollowedThroughItsEscapedTaskID() async throws {
        let session = try await signedIn()
        let snapshot = try #require(try await session.send(PBS.snapshots("store1")).first { $0.reference.group.type == .host })
        let upid = try await session.send(PBS.verify("store1", snapshot: snapshot.reference, skipVerified: false))
        let parsed = try #require(UPID(upid))
        #expect(parsed.type == "verify_snapshot")
        // `store1:/host/<id>/<time>`: verification tasks name the namespace, a lone "/" for the root.
        #expect(parsed.objectID.hasPrefix("store1:/host/"))
        #expect(TaskDescription.title(type: parsed.type, objectID: parsed.objectID).hasPrefix("store1 host/"))
        #expect(try await wait(for: upid, in: session).succeeded)
        let log = try await session.send(PBS.taskLog(upid: upid))
        #expect(log.contains { $0.text.contains("TASK OK") })
    }

    @Test func filesAndDirectoriesDownloadFromABackup() async throws {
        let session = try await signedIn()
        let snapshot = try #require(try await session.send(PBS.snapshots("store1")).first { $0.reference.group.backupID == "pbs-claude" })
        let archive = try #require(try await session.send(PBS.catalog("store1", snapshot.reference, filePath: "/")).first)
        let entries = try await session.send(PBS.catalog("store1", snapshot.reference, filePath: archive.filePath))
        let hostname = try #require(entries.first { $0.name == "hostname" })
        let progress = ProgressRecorder()

        let file = try await session.download(PBS.downloadArchiveEntry("store1", snapshot.reference, filePath: hostname.filePath)) { received, _ in
            progress.record(received)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let name = try await session.send(PBS.nodes()).first?.name
        #expect(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == name)
        #expect(progress.latest > 0)

        let directory = try #require(entries.first { $0.name == "apt" })
        let zip = try await session.download(PBS.downloadArchiveEntry("store1", snapshot.reference, filePath: directory.filePath))
        defer { try? FileManager.default.removeItem(at: zip) }
        #expect(try Data(contentsOf: zip).prefix(2) == Data("PK".utf8))

        let index = try await session.download(PBS.downloadSnapshotFile("store1", snapshot.reference, fileName: "index.json.blob"))
        defer { try? FileManager.default.removeItem(at: index) }
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: index)) is [String: Any])

        let missing = Data("\(archive.decodedPath ?? "")/does-not-exist".utf8).base64EncodedString()
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.download(PBS.downloadArchiveEntry("store1", snapshot.reference, filePath: missing))
        }
    }
}

// MARK: - Datastores

extension LiveBackupServerTests {
    /// Removes a datastore with its data if an earlier, aborted run left it behind.
    fileprivate func removeLeftover(_ name: String, in session: ProxmoxSession) async throws {
        guard try await session.send(PBS.datastoreConfigs()).value.contains(where: { $0.name == name }) else { return }
        let upid = try await session.send(PBS.deleteDatastore(name, destroyData: true, keepJobs: false, digest: nil))
        _ = try await waitForTask(upid, in: session)
    }

    fileprivate func waitForTask(_ upid: String, in session: ProxmoxSession) async throws -> TaskStatus {
        for _ in 0..<240 {
            let status = try await session.send(PBS.taskStatus(upid: upid))
            if !status.isRunning { return status }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ProxmoxError.invalidResponse("task \(upid) did not finish")
    }

    @Test func datastoreLifecycle() async throws {
        let session = try await signedIn()
        let name = "pflive-ds"
        try await removeLeftover(name, in: session)

        // Created like the app's form does: the prune settings become a prune job of the datastore.
        var draft = DatastoreDraft()
        draft.name = name
        draft.path = "/datastore/\(name)"
        draft.comment = "ProxFleet live test"
        draft.retention = RetentionPolicy(last: 2)
        #expect(draft.problems(isNew: true).isEmpty)
        let created = try await session.send(PBS.createDatastore(draft.creationParameters(usesNotificationSystem: true)))
        #expect(try await waitForTask(created, in: session).succeeded)
        let pruneJob = try #require(try await session.send(PBS.pruneJobs(store: name)).value.first)
        #expect(pruneJob.retention == RetentionPolicy(last: 2))
        #expect(pruneJob.id.hasPrefix("default-\(name)-"))

        // Every kind of option the editors change, sent as changes with the digest.
        let loaded = try await session.send(PBS.datastoreConfig(name))
        let original = DatastoreDraft(loaded.value)
        var edited = original
        edited.comment = ""
        edited.gcSchedule = "sat 03:00"
        edited.verifyNew = true
        edited.notificationMode = "legacy-sendmail"
        edited.notifyUser = "root@pam"
        edited.notify = ["gc": .error, "verify": .always]
        edited.tuning["chunk-order"] = "none"
        edited.tuning["gc-cache-capacity"] = "0"
        let update = edited.changes(from: original, digest: loaded.digest)
        #expect(update.deletions == ["comment"])
        _ = try await session.send(PBS.updateDatastore(name, update))
        let saved = try await session.send(PBS.datastoreConfig(name)).value
        #expect(saved.comment == nil)
        #expect(saved.gcSchedule == "sat 03:00")
        #expect(saved.verifyNew)
        #expect(DatastoreDraft(saved).notify == ["gc": .error, "verify": .always])
        #expect(PropertyMap(parsing: saved.values["tuning"]) == edited.tuning)
        // The digest of the first read is stale now.
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.send(PBS.updateDatastore(name, original.changes(from: edited, digest: loaded.digest)))
        }

        // Maintenance with a message the property string has to quote.
        var maintenance = BackupServerConfigUpdate()
        maintenance.set("maintenance-mode", DatastoreMaintenance(kind: .readOnly, message: #"Moving, "soon""#).stringValue)
        _ = try await session.send(PBS.updateDatastore(name, maintenance))
        let summary = try #require(try await session.send(PBS.datastores()).first { $0.store == name })
        #expect(summary.maintenance == DatastoreMaintenance(kind: .readOnly, message: #"Moving, "soon""#))
        maintenance.set("maintenance-mode", nil)
        _ = try await session.send(PBS.updateDatastore(name, maintenance))
        #expect(try await session.send(PBS.datastoreConfig(name)).value.maintenance == nil)

        // Jobs on the empty datastore.
        #expect(try await waitForTask(try await session.send(PBS.startGarbageCollection(name)), in: session).succeeded)
        #expect(try await waitForTask(try await session.send(PBS.verify(name, skipVerified: false)), in: session).succeeded)
        #expect(try await session.send(PBS.garbageCollectionStatus(name)).lastRunState == "OK")

        // Permissions on the datastore and a namespace below it.
        let entry = BackupServerACLEntry(path: "/datastore/\(name)", authID: try #require(server["LIMITED_USER"]) + "@" + (server["LIMITED_REALM"] ?? "pbs"),
                                         role: "DatastoreReader", propagates: false)
        _ = try await session.send(PBS.setACL(entry))
        let acl = try await session.send(PBS.acl(path: entry.path))
        #expect(acl.value.contains(entry))
        _ = try await session.send(PBS.setACL(entry, remove: true, digest: acl.digest))
        #expect(try await !session.send(PBS.acl(path: entry.path)).value.contains(entry))

        let removed = try await session.send(PBS.deleteDatastore(name, destroyData: true, keepJobs: false, digest: nil))
        #expect(try await waitForTask(removed, in: session).succeeded)
        #expect(try await !session.send(PBS.datastores()).contains { $0.store == name })
        #expect(try await session.send(PBS.pruneJobs(store: name)).value.isEmpty)
    }

    /// Prepares the spare disk as the web interface's Directory does with Removable Datastore, then adds a second
    /// datastore on it the way the app's form does, mounts and unmounts, and wipes the disk again.
    @Test func removableDatastoreOnTheSpareDisk() async throws {
        let session = try await signedIn()
        let disks = try await session.send(PBS.disks())
        guard let spare = disks.first(where: { $0.name == (server["SPARE_DISK"] ?? "sdb") }), spare.isUnused else {
            Issue.record("the spare disk is not unused; wipe it first")
            return
        }
        let outcome: Result<Void, any Error>
        do {
            try await checkRemovableDatastore(session, disk: spare.name)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        // Clean up after a failure as well; after success there is nothing left, which is harmless to repeat.
        for name in ["pflive-usb2", "pflive-usb"] { try? await removeLeftover(name, in: session) }
        if try await session.send(PBS.disks()).first(where: { $0.name == spare.name })?.isUnused == false,
           let upid = try? await session.send(APIRequest<String>(.put, "/nodes/localhost/disks/wipedisk", parameters: ["disk": .string(spare.name)])) {
            _ = try? await waitForTask(upid, in: session)
        }
        try outcome.get()
    }

    private func checkRemovableDatastore(_ session: ProxmoxSession, disk: String) async throws {
        let spare = try #require(try await session.send(PBS.disks()).first { $0.name == disk })
        let directory = try await session.send(APIRequest<String>(.post, "/nodes/localhost/disks/directory", parameters: [
            "disk": .string(spare.name), "name": "pflive-usb", "filesystem": "ext4", "add-datastore": true, "removable-datastore": true,
        ]))
        #expect(try await waitForTask(directory, in: session).succeeded)
        let partition = try #require(try await session.send(PBS.disks()).first { $0.name == spare.name }?.datastorePartitions.first)
        let uuid = try #require(partition.uuid)
        #expect(try await session.send(PBS.datastoreConfig("pflive-usb")).value.backingDevice == uuid)

        var draft = DatastoreDraft()
        draft.name = "pflive-usb2"
        draft.kind = .removable
        draft.path = "second"
        draft.backingDevice = uuid
        #expect(draft.problems(isNew: true).isEmpty)
        #expect(try await waitForTask(try await session.send(PBS.createDatastore(draft.creationParameters(usesNotificationSystem: true))), in: session).succeeded)
        #expect(try await session.send(PBS.datastoreConfig("pflive-usb2")).value.isRemovable)

        #expect(try await waitForTask(try await session.send(PBS.unmountDatastore("pflive-usb2")), in: session).succeeded)
        let unmounted = try #require(try await session.send(PBS.datastores()).first { $0.store == "pflive-usb2" })
        #expect(unmounted.mountStatus == .notMounted)
        await #expect(throws: ProxmoxError.api(status: 400, message: "datastore 'pflive-usb2' is not mounted", fieldErrors: [:])) {
            _ = try await session.send(PBS.datastoreStatus("pflive-usb2"))
        }
        #expect(try await waitForTask(try await session.send(PBS.mountDatastore("pflive-usb2")), in: session).succeeded)
        #expect(try await session.send(PBS.datastores()).first { $0.store == "pflive-usb2" }?.mountStatus == .mounted)

        for name in ["pflive-usb2", "pflive-usb"] {
            #expect(try await waitForTask(try await session.send(PBS.deleteDatastore(name, destroyData: true, keepJobs: false, digest: nil)), in: session).succeeded)
        }
        let wipe = try await session.send(APIRequest<String>(.put, "/nodes/localhost/disks/wipedisk", parameters: ["disk": .string(spare.name)]))
        #expect(try await waitForTask(wipe, in: session).succeeded)
        #expect(try await session.send(PBS.disks()).first { $0.name == spare.name }?.isUnused == true)
    }
}

// MARK: - Content

extension LiveBackupServerTests {
    /// Copies the seeded container and VM backups into a throwaway datastore with a local sync job, then works on the
    /// copies: notes, protection, prune, browsing and downloading, owner, moves and deletion.
    @Test func datastoreContent() async throws {
        let session = try await signedIn()
        let store = "pflive-content"
        func cleanUp() async {
            _ = try? await session.send(PBS.deleteSyncJob("pflive-copy"))
            try? await removeLeftover(store, in: session)
        }
        await cleanUp()
        // `defer` cannot wait, so the checks run first and the cleanup always follows, also after a failure.
        let outcome: Result<Void, any Error>
        do {
            try await checkContent(session, store: store)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await cleanUp()
        try outcome.get()
    }

    private func checkContent(_ session: ProxmoxSession, store: String) async throws {
        var draft = DatastoreDraft()
        draft.name = store
        draft.path = "/datastore/\(store)"
        draft.pruneSchedule = ""
        #expect(try await waitForTask(try await session.send(PBS.createDatastore(draft.creationParameters(usesNotificationSystem: true))), in: session).succeeded)
        _ = try await session.send(APIRequest<Nothing>(.post, "/config/sync", parameters: [
            "id": "pflive-copy", "store": .string(store), "remote-store": "store1", "remote-ns": "pve", "max-depth": 0,
        ]))
        #expect(try await waitForTask(try await session.send(PBS.runSyncJob("pflive-copy")), in: session).succeeded)

        let groups = try await session.send(PBS.groups(store))
        let container = try #require(groups.first { $0.reference.type == .ct }).reference
        let vm = try #require(groups.first { $0.reference.type == .vm }).reference
        let snapshots = try await session.send(PBS.snapshots(store, group: container)).sorted { $0.reference.time < $1.reference.time }
        #expect(snapshots.count == 2)
        let (oldest, newest) = (try #require(snapshots.first).reference, try #require(snapshots.last).reference)

        // Notes of the group and of a snapshot; the first line becomes the comment.
        _ = try await session.send(PBS.setGroupNotes(store, container, notes: "Copied container\nfor tests"))
        #expect(try await session.send(PBS.groupNotes(store, container)) == "Copied container\nfor tests")
        _ = try await session.send(PBS.setSnapshotNotes(store, newest, notes: "Newest copy"))
        #expect(try await session.send(PBS.snapshots(store, group: container)).first { $0.reference == newest }?.comment == "Newest copy")

        // A protected snapshot cannot be deleted and survives every prune.
        _ = try await session.send(PBS.setProtected(store, oldest, true))
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PBS.deleteSnapshot(store, oldest)) }
        let preview = try await session.send(PBS.previewPrune(store, container, keep: RetentionPolicy(last: 1)))
        #expect(preview.allSatisfy { $0.keep })
        #expect(preview.first { $0.reference.time == oldest.time }?.isProtected == true)

        // Browsing the container's file archive and downloading from it.
        let archives = try await session.send(PBS.catalog(store, newest, filePath: "/"))
        let root = try #require(archives.first { $0.name == "root.pxar.didx" })
        let top = try await session.send(PBS.catalog(store, newest, filePath: root.filePath))
        let etc = try #require(top.first { $0.name == "etc" })
        let hostname = try #require(try await session.send(PBS.catalog(store, newest, filePath: etc.filePath)).first { $0.name == "hostname" })
        let file = try await session.download(PBS.downloadArchiveEntry(store, newest, filePath: hostname.filePath))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try !String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let zip = try await session.download(PBS.downloadArchiveEntry(store, newest, filePath: etc.filePath))
        defer { try? FileManager.default.removeItem(at: zip) }
        #expect(try Data(contentsOf: zip).prefix(2) == Data("PK".utf8))
        let config = try await session.download(PBS.downloadSnapshotFile(store, newest, fileName: "pct.conf.blob"))
        defer { try? FileManager.default.removeItem(at: config) }
        #expect(try String(contentsOf: config, encoding: .utf8).contains("hostname:"))

        // Verification of a group, a new owner and a move to another namespace.
        #expect(try await waitForTask(try await session.send(PBS.verify(store, group: container, skipVerified: false)), in: session).succeeded)
        let owner = "\(try #require(server["LIMITED_USER"]))@\(server["LIMITED_REALM"] ?? "pbs")"
        _ = try await session.send(PBS.changeOwner(store, vm, to: owner))
        #expect(try await session.send(PBS.groups(store)).first { $0.reference == vm }?.owner == owner)
        _ = try await session.send(PBS.createNamespace(store, name: "moved", parent: .root))
        let version = try await session.send(PBS.version())
        if version.supports(.moveGroupsAndNamespaces) {
            #expect(try await waitForTask(try await session.send(PBS.moveGroup(store, vm, to: BackupNamespace("moved"), merge: true)), in: session).succeeded)
            #expect(try await session.send(PBS.groups(store, namespace: BackupNamespace("moved"))).map(\.reference.path) == [vm.path])
            _ = try await session.send(PBS.createNamespace(store, name: "target", parent: .root))
            #expect(try await waitForTask(try await session.send(PBS.moveNamespace(store, BackupNamespace("moved"), to: BackupNamespace("target/moved"), mergeGroups: true)), in: session).succeeded)
            #expect(try await session.send(PBS.namespaces(store)).map(\.path).sorted() == ["", "target", "target/moved"])
        }

        // Prune of everything as a dry run, then deletion: the protected snapshot keeps its group.
        #expect(try await waitForTask(try await session.send(PBS.pruneNamespace(store, .root, keep: RetentionPolicy(last: 1), dryRun: true)), in: session).succeeded)
        let deleted = try #require(try await session.send(PBS.deleteGroup(store, container)))
        #expect(deleted.protectedSnapshots == 1)
        #expect(deleted.removedSnapshots == 1)
        #expect(try await session.send(PBS.snapshots(store, group: container)).map(\.reference) == [oldest])
        if version.supports(.moveGroupsAndNamespaces) {
            let namespace = try #require(try await session.send(PBS.deleteNamespace(store, BackupNamespace("target"), deleteGroups: true)))
            #expect(namespace.removedSnapshots == 2)
        }
        _ = try await session.send(PBS.setProtected(store, oldest, false))
    }
}

// MARK: - Jobs and remotes

extension LiveBackupServerTests {
    /// A remote pointing back at this server, and one job of each kind working on a throwaway datastore: created from
    /// the app's drafts, read back, run, changed and removed again.
    @Test func jobsAndRemotesLifecycle() async throws {
        let session = try await signedIn()
        let store = "pflive-jobs"
        func cleanUp() async {
            for id in ["pflive-pull", "pflive-push"] { _ = try? await session.send(PBS.deleteSyncJob(id)) }
            _ = try? await session.send(PBS.deleteVerifyJob("pflive-verify"))
            _ = try? await session.send(PBS.deletePruneJob("pflive-prune"))
            _ = try? await session.send(PBS.deleteRemote("pflive-remote"))
            try? await removeLeftover(store, in: session)
        }
        await cleanUp()
        // `defer` cannot wait, so the checks run first and the cleanup always follows, also after a failure.
        let outcome: Result<Void, any Error>
        do {
            try await checkJobs(session, store: store)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await cleanUp()
        try outcome.get()
    }

    private func checkJobs(_ session: ProxmoxSession, store: String) async throws {
        let version = try await session.send(PBS.version())
        var datastore = DatastoreDraft()
        datastore.name = store
        datastore.path = "/datastore/\(store)"
        datastore.pruneSchedule = ""
        #expect(try await waitForTask(try await session.send(PBS.createDatastore(datastore.creationParameters(usesNotificationSystem: true))), in: session).succeeded)

        // A remote back to this server with the seeded token; the seeded remote has the certificate's fingerprint.
        var remote = RemoteDraft()
        remote.name = "pflive-remote"
        remote.address = "127.0.0.1"
        remote.authID = try #require(server["SEED_TOKEN_ID"])
        remote.password = try #require(server["SEED_TOKEN_SECRET"])
        remote.fingerprint = try #require(try await session.send(PBS.remote("self")).value.fingerprint)
        #expect(remote.problems(isNew: true).isEmpty)
        _ = try await session.send(PBS.createRemote(remote.creationParameters))
        #expect(try await session.send(PBS.remoteDatastores("pflive-remote")).contains { $0.store == "store1" })
        #expect(try await session.send(PBS.remoteNamespaces("pflive-remote", store: "store1")).contains(BackupNamespace("pve")))
        let remoteGroups = try await session.send(PBS.remoteGroups("pflive-remote", store: "store1", namespace: BackupNamespace("pve")))
        #expect(remoteGroups.contains { $0.reference.type == .ct })
        let loadedRemote = try await session.send(PBS.remote("pflive-remote"))
        #expect(RemoteDraft(loadedRemote.value).serialized() == remote.serialized())
        var editedRemote = RemoteDraft(loadedRemote.value)
        editedRemote.comment = "ProxFleet live test"
        _ = try await session.send(PBS.updateRemote("pflive-remote", editedRemote.update(from: RemoteDraft(loadedRemote.value), digest: loadedRemote.digest)))
        #expect(try await session.send(PBS.remote("pflive-remote")).value.comment == "ProxFleet live test")

        // A pull with a group filter, a rate limit and the options the server knows; it reads back as sent.
        var pull = SyncJobDraft(direction: .pull, store: store, owner: "root@pam")
        pull.id = "pflive-pull"
        pull.remote = "pflive-remote"
        pull.remoteStore = "store1"
        pull.remoteNamespace = "pve"
        pull.maxDepth = 0
        pull.schedule = ""
        pull.comment = "ProxFleet live test"
        pull.groupFilters = [GroupFilter(kind: .type, value: "ct")]
        pull.rateLimit = ByteRate(amount: "50", unit: .mib)
        pull.transferLast = 1
        if version.supports(.resyncCorrupt) { pull.resyncCorrupt = true }
        if version.supports(.syncWorkerThreads) { pull.workerThreads = 2 }
        #expect(pull.problems(isNew: true).isEmpty)
        _ = try await session.send(PBS.createSyncJob(pull.creationParameters))
        let listed = try await session.send(PBS.syncJobs(direction: version.supports(.pushSync) ? "all" : nil, store: store))
        let created = try #require(listed.value.first { $0.id == "pflive-pull" })
        #expect(SyncJobDraft(created).serialized() == pull.serialized())
        #expect(SyncJobDraft(created).groupFilters == pull.groupFilters)
        #expect(try await waitForTask(try await session.send(PBS.runSyncJob("pflive-pull")), in: session).succeeded)
        let pulled = try await session.send(PBS.groups(store))
        #expect(!pulled.isEmpty && pulled.allSatisfy { $0.reference.type == .ct })
        #expect(try await session.send(PBS.snapshots(store, group: try #require(pulled.first).reference)).count == 1)

        // Clearing the filter and the limit deletes them; a stale digest is refused afterwards.
        var edited = SyncJobDraft(created)
        edited.groupFilters = []
        edited.rateLimit = ByteRate()
        _ = try await session.send(PBS.updateSyncJob("pflive-pull", edited.changes(from: SyncJobDraft(created), digest: listed.digest)))
        let cleared = try await session.send(PBS.syncJobConfig("pflive-pull")).value
        #expect(cleared.groupFilters.isEmpty)
        #expect(cleared.values["rate-in"] == nil)
        var stale = SyncJobDraft(cleared)
        stale.comment = "Stale"
        await #expect(throws: ProxmoxError.self) {
            _ = try await session.send(PBS.updateSyncJob("pflive-pull", stale.changes(from: SyncJobDraft(cleared), digest: listed.digest)))
        }

        // A push back through the remote, into a namespace of the same datastore.
        if version.supports(.pushSync) {
            _ = try await session.send(PBS.createNamespace(store, name: "pushed", parent: .root))
            var push = SyncJobDraft(direction: .push, store: store, owner: "root@pam")
            push.id = "pflive-push"
            push.remote = "pflive-remote"
            push.remoteStore = store
            push.remoteNamespace = "pushed"
            push.maxDepth = 0
            push.schedule = ""
            push.rateLimit = ByteRate(amount: "100", unit: .mib)
            _ = try await session.send(PBS.createSyncJob(push.creationParameters))
            let pushJob = try #require(try await session.send(PBS.syncJobConfig("pflive-push")).value)
            #expect(pushJob.direction == .push)
            #expect(pushJob.values["rate-out"].map { ByteRate(parsing: $0) } == push.rateLimit)
            #expect(try await waitForTask(try await session.send(PBS.runSyncJob("pflive-push")), in: session).succeeded)
            #expect(try await session.send(PBS.groups(store, namespace: BackupNamespace("pushed"))).count == pulled.count)
        }

        // Verification of everything, read back as sent.
        var verify = VerifyJobDraft(store: store)
        verify.id = "pflive-verify"
        verify.schedule = ""
        verify.skipVerified = false
        if version.supports(.verificationThreads) {
            verify.readThreads = 1
            verify.verifyThreads = 2
        }
        _ = try await session.send(PBS.createVerifyJob(verify.creationParameters))
        let verifyJob = try #require(try await session.send(PBS.verifyJobs(store: store)).value.first)
        #expect(VerifyJobDraft(verifyJob).serialized() == verify.serialized())
        #expect(try await waitForTask(try await session.send(PBS.runVerifyJob("pflive-verify")), in: session).succeeded)

        // A disabled prune job with generous rules: running it by hand removes nothing.
        var prune = PruneJobDraft(store: store)
        prune.id = "pflive-prune"
        prune.schedule = "daily"
        prune.isEnabled = false
        prune.retention = RetentionPolicy(last: 100)
        _ = try await session.send(PBS.createPruneJob(prune.creationParameters))
        let pruneList = try await session.send(PBS.pruneJobs(store: store))
        let pruneJob = try #require(pruneList.value.first)
        #expect(pruneJob.isDisabled)
        #expect(PruneJobDraft(pruneJob).serialized() == prune.serialized())
        #expect(try await waitForTask(try await session.send(PBS.runPruneJob("pflive-prune")), in: session).succeeded)
        #expect(try await session.send(PBS.groups(store)).count == pulled.count)
        var enabled = PruneJobDraft(pruneJob)
        enabled.isEnabled = true
        let enabling = enabled.changes(from: PruneJobDraft(pruneJob), digest: pruneList.digest)
        #expect(enabling.deletions == ["disable"])
        _ = try await session.send(PBS.updatePruneJob("pflive-prune", enabling))
        #expect(try await session.send(PBS.pruneJobConfig("pflive-prune")).value.isDisabled == false)

        // Garbage collection of the datastore, then its listing.
        #expect(try await waitForTask(try await session.send(PBS.startGarbageCollection(store)), in: session).succeeded)
        #expect(try await session.send(PBS.garbageCollectionJobs()).first { $0.store == store }?.lastRunState == "OK")

        // A remote in use cannot be removed.
        await #expect(throws: ProxmoxError.self) { _ = try await session.send(PBS.deleteRemote("pflive-remote")) }
        if version.supports(.syncEncryption) {
            _ = try await session.send(PBS.encryptionKeys(includeArchived: true))
        }
    }
}

// MARK: - Administration

extension LiveBackupServerTests {
    /// Runs a command in the server's shell and returns its output, which ends before the exit status.
    fileprivate func runOnServer(_ session: ProxmoxSession, _ command: String, timeout: TimeInterval = 30) async throws -> (output: String, status: Int?) {
        let terminal = try await TerminalConnection.open(.node(PBS.node), session: session)
        defer { terminal.close() }
        try await terminal.resize(columns: 200, rows: 50)
        let marker = "PFDONE\(Int.random(in: 100_000...999_999))"
        // The marker is split in the command line, so only the command's own echo matches it.
        try await terminal.send("{ \(command) ; } 2>&1; echo \"\(marker.prefix(3))\"\"\(marker.dropFirst(3))-$?\"\n")
        var text = ""
        let deadline = Date().addingTimeInterval(timeout)
        for try await chunk in terminal.output {
            text += String(decoding: chunk, as: UTF8.self)
            if text.range(of: "\(marker)-\\d+", options: .regularExpression) != nil || Date() > deadline { break }
        }
        guard let range = text.range(of: "\(marker)-\\d+", options: .regularExpression) else { return (text, nil) }
        return (String(text[..<range.lowerBound]), Int(text[range].split(separator: "-").last ?? ""))
    }

    /// Services, updates, repositories, the journal and report, DNS, time zone, options, the certificate and the shell,
    /// each changed and set back where it changes anything.
    @Test func serverAdministration() async throws {
        let session = try await signedIn()
        let node = PBS.node
        #expect(try await session.privileges(on: "/system").contains("Sys.PowerManagement"))

        // Services: a restart is a task, although the API schema says it returns nothing.
        #expect(try await session.send(PVE.services(node: node)).contains { $0.name == "proxmox-backup-proxy" && $0.isRunning })
        let restart = try #require(try await session.send(PVE.serviceAction(node: node, service: "postfix", .restart)))
        #expect(try await waitForTask(restart, in: session).succeeded)
        var postfixRuns = false
        for _ in 0..<10 where !postfixRuns {
            postfixRuns = try await session.send(PVE.services(node: node)).first { $0.name == "postfix" }?.isRunning == true
            if !postfixRuns { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(postfixRuns)

        // Updates and repositories: one Proxmox repository is switched and switched back.
        let refresh = try #require(try await session.send(PVE.refreshPackageIndex(node: node)))
        #expect(try await waitForTask(refresh, in: session).succeeded)
        _ = try await session.send(PVE.packageUpdates(node: node))
        #expect(try await session.send(PVE.packageVersions(node: node)).contains { $0.package == "proxmox-backup-server" })
        #expect(try await !session.send(PVE.packageChangelog(node: node, package: "proxmox-backup-server")).isEmpty)
        let repositories = try await session.send(PVE.aptRepositories(node: node))
        let proxmox = try #require(repositories.files.flatMap(\.repositories).first { $0.uris.contains { $0.contains("proxmox.com") } })
        _ = try await session.send(PVE.setRepository(node: node, proxmox, enabled: !proxmox.isEnabled, digest: repositories.digest))
        let switched = try await session.send(PVE.aptRepositories(node: node))
        #expect(switched.files.flatMap(\.repositories).first { $0.path == proxmox.path && $0.index == proxmox.index }?.isEnabled == !proxmox.isEnabled)
        _ = try await session.send(PVE.setRepository(node: node, proxmox, enabled: proxmox.isEnabled, digest: switched.digest))

        // Journal and report.
        #expect(try await !NodeJournal.lines(session.send(PVE.journal(node: node, lastEntries: 20))).isEmpty)
        let hostname = try await session.send(PBS.nodes()).first?.name ?? ""
        #expect(try await session.send(PVE.systemReport(node: node)).contains(hostname))

        // DNS saved as it is; the time zone changed and set back.
        let dns = try await session.send(PVE.nodeDNS(node))
        _ = try await session.send(PVE.updateNodeDNS(node, dns))
        #expect(try await session.send(PVE.nodeDNS(node)).servers == dns.servers)
        let timeZone = try await session.send(PVE.nodeTime(node)).timeZone
        let other = timeZone == "Europe/Berlin" ? "Europe/Warsaw" : "Europe/Berlin"
        _ = try await session.send(PVE.setNodeTimeZone(node, other))
        #expect(try await session.send(PVE.nodeTime(node)).timeZone == other)
        _ = try await session.send(PVE.setNodeTimeZone(node, timeZone))

        // Options: the mail sender is set and set back.
        let options = try await session.send(PBS.nodeOptions())
        let original = BackupServerNodeOptionsDraft(options.value)
        var draft = original
        draft.emailFrom = "pflive@example.com"
        draft.taskLogMaxDays = 120
        _ = try await session.send(PBS.updateNodeOptions(draft.changes(from: original, digest: options.digest)))
        let changed = try await session.send(PBS.nodeOptions())
        #expect(BackupServerNodeOptionsDraft(changed.value) == draft)
        _ = try await session.send(PBS.updateNodeOptions(original.changes(from: draft, digest: changed.digest)))
        #expect(try await BackupServerNodeOptionsDraft(session.send(PBS.nodeOptions()).value) == original)

        // The certificate is the one the connection trusts.
        let certificate = try #require(try await session.send(PVE.certificates(node: node)).first { $0.fileName == "proxy.pem" })
        if let expected = server["FINGERPRINT"] {
            #expect(certificate.fingerprint?.uppercased() == expected.uppercased())
        }

        // The shell.
        let shell = try await runOnServer(session, "echo pflive-$((6*7))")
        #expect(shell.output.contains("pflive-42"))
        #expect(shell.status == 0)
    }

    /// A bridge without ports, which touches nothing else: created, changed, applied, removed and applied again.
    @Test func networkBridgeWithoutPorts() async throws {
        let session = try await signedIn()
        let name = "vmbr9"
        func cleanUp() async throws {
            _ = try? await session.send(PVE.revertNetwork(node: PBS.node))
            if try await session.send(PVE.network(node: PBS.node)).interfaces.contains(where: { $0.name == name }) {
                _ = try? await session.send(PVE.deleteInterface(node: PBS.node, name: name))
                if let upid = try? await session.send(PVE.applyNetwork(node: PBS.node)) { _ = try? await waitForTask(upid, in: session) }
            }
        }
        try? await cleanUp()
        let outcome: Result<Void, any Error>
        do {
            let network = try await session.send(PVE.network(node: PBS.node))
            try #require(network.pendingChanges == nil, "the server has pending network changes")
            var bridge = NetworkInterfaceDraft(creating: .bridge, existing: network.interfaces)
            bridge.name = name
            bridge.comments = "ProxFleet live test"
            bridge.vlanAware = true
            _ = try await session.send(PBS.createInterface(bridge))
            let pending = try await session.send(PVE.network(node: PBS.node))
            let created = try #require(pending.interfaces.first { $0.name == name })
            #expect(created.bridgeVLANAware)
            #expect(created.comments == "ProxFleet live test")
            #expect(pending.pendingChanges?.contains(name) == true)
            #expect(NetworkInterfaceDraft(created).changes(from: bridge).isEmpty)

            var edited = NetworkInterfaceDraft(created)
            edited.comments = ""
            edited.vlanAware = false
            _ = try await session.send(PBS.updateInterface(name, edited.changes(from: NetworkInterfaceDraft(created))))
            let changed = try #require(try await session.send(PVE.network(node: PBS.node)).interfaces.first { $0.name == name })
            #expect(changed.comments == nil)
            #expect(!changed.bridgeVLANAware)

            // Applying is a task too, although the API schema says it returns nothing.
            let apply = try #require(try await session.send(PVE.applyNetwork(node: PBS.node)))
            #expect(try await waitForTask(apply, in: session).succeeded)
            let applied = try await session.send(PVE.network(node: PBS.node))
            #expect(applied.pendingChanges == nil)
            // A bridge without ports has no carrier, so the server does not report it as active.
            #expect(applied.interfaces.contains { $0.name == name })
            _ = try await session.send(PVE.deleteInterface(node: PBS.node, name: name))
            let removal = try #require(try await session.send(PVE.applyNetwork(node: PBS.node)))
            #expect(try await waitForTask(removal, in: session).succeeded)
            #expect(try await !session.send(PVE.network(node: PBS.node)).interfaces.contains { $0.name == name })
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        try? await cleanUp()
        try outcome.get()
    }

    /// The spare disk: a GPT, a directory with a datastore, and a ZFS pool, each removed again; the disk is wiped at
    /// the end, as it started.
    @Test(.timeLimit(.minutes(5))) func diskStorageOnTheSpareDisk() async throws {
        let session = try await signedIn()
        func cleanUp() async throws {
            if try await session.send(PBS.datastoreConfigs()).value.contains(where: { $0.name == "pflivedir" }) {
                if let upid = try? await session.send(PBS.deleteDatastore("pflivedir", destroyData: true, keepJobs: false, digest: nil)) {
                    _ = try? await waitForTask(upid, in: session)
                }
            }
            if try await session.send(PBS.directories()).contains(where: { $0.name == "pflivedir" }) {
                _ = try? await session.send(PBS.deleteDirectory("pflivedir"))
            }
            if try await session.send(PBS.zfsPools()).contains(where: { $0.name == "pflivezfs" }) {
                _ = try? await runOnServer(session, "zpool destroy pflivezfs")
            }
            // Destroying a pool leaves its mount point, where the server refuses to create one again.
            _ = try? await runOnServer(session, "rmdir /mnt/datastore/pflivezfs /mnt/datastore/pflivedir 2>/dev/null; true")
            if let upid = try? await session.send(PVE.wipeDisk(node: PBS.node, disk: "sdb")) {
                _ = try? await waitForTask(upid, in: session)
            }
        }
        // An aborted earlier run may have left its mounts, pools and mount points behind; the spare disk must be free then.
        try? await cleanUp()
        let spare = try #require(try await session.send(PBS.nodeDisks()).first { $0.name == "sdb" })
        try #require(spare.isUnused, "the spare disk sdb is in use")
        let outcome: Result<Void, any Error>
        do {
            try await checkDiskStorage(session)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        try? await cleanUp()
        try outcome.get()
        #expect(try await session.send(PBS.nodeDisks()).first { $0.name == "sdb" }?.isUnused == true)
    }

    private func checkDiskStorage(_ session: ProxmoxSession) async throws {
        _ = try await session.send(PVE.smart(node: PBS.node, disk: "sda"))

        let gpt = try #require(try await session.send(PVE.initializeGPT(node: PBS.node, disk: "sdb")))
        #expect(try await waitForTask(gpt, in: session).succeeded)
        #expect(try await session.send(PBS.nodeDisks()).first { $0.name == "sdb" }?.hasGPT == true)
        let wipe = try #require(try await session.send(PVE.wipeDisk(node: PBS.node, disk: "sdb")))
        #expect(try await waitForTask(wipe, in: session).succeeded)

        // A directory with a datastore; the mount stays until the datastore is gone.
        var directory = DiskStorageDraft(kind: .directory)
        directory.name = "pflivedir"
        directory.devices = ["/dev/sdb"]
        #expect(directory.backupServerProblems(existingDatastores: []).isEmpty)
        let created = try #require(try await session.send(PBS.createDiskStorage(directory)))
        #expect(try await waitForTask(created, in: session).succeeded)
        let mount = try #require(try await session.send(PBS.directories()).first { $0.name == "pflivedir" })
        #expect(mount.mount.path == "/mnt/datastore/pflivedir")
        #expect(try await session.send(PBS.datastores()).contains { $0.store == "pflivedir" })
        let flattened = try await session.send(PBS.nodeDisks()).flatMap(\.nodeDisks)
        #expect(flattened.contains { $0.parent == "/dev/sdb" })
        #expect(flattened.first { $0.path == "/dev/sdb" }?.isUnused == false)
        let removed = try await session.send(PBS.deleteDatastore("pflivedir", destroyData: true, keepJobs: false, digest: nil))
        #expect(try await waitForTask(removed, in: session).succeeded)
        _ = try await session.send(PBS.deleteDirectory("pflivedir"))
        #expect(try await !session.send(PBS.directories()).contains { $0.name == "pflivedir" })
        let wipeDirectory = try #require(try await session.send(PVE.wipeDisk(node: PBS.node, disk: "sdb")))
        #expect(try await waitForTask(wipeDirectory, in: session).succeeded)

        // A ZFS pool without a datastore; the API cannot destroy pools, the shell can.
        var pool = DiskStorageDraft(kind: .zfs)
        pool.name = "pflivezfs"
        pool.devices = ["/dev/sdb"]
        pool.addStorage = false
        let createdPool = try #require(try await session.send(PBS.createDiskStorage(pool)))
        #expect(try await waitForTask(createdPool, in: session).succeeded)
        #expect(try await session.send(PBS.zfsPools()).contains { $0.name == "pflivezfs" })
        #expect(try await session.send(PBS.zfsPoolStatus("pflivezfs")).state == "ONLINE")
        #expect(try await runOnServer(session, "zpool destroy pflivezfs && rmdir /mnt/datastore/pflivezfs").status == 0)
    }
}

// MARK: - Configuration

extension LiveBackupServerTests {
    /// A user with a password, a token with a permission and second factors, each changed and removed again.
    @Test func usersTokensAndSecondFactors() async throws {
        let session = try await signedIn()
        let user = "pflive@pbs"
        func cleanUp() async {
            _ = try? await session.send(PBS.deleteUser(user))
        }
        await cleanUp()
        let outcome: Result<Void, any Error>
        do {
            var draft = BackupServerUserDraft()
            draft.userID = user
            draft.password = "pflive-password-1"
            draft.passwordConfirmation = "pflive-password-1"
            draft.firstName = "Live"
            draft.comment = "ProxFleet live test"
            #expect(draft.problems(isNew: true, realms: ["pam", "pbs"]).isEmpty)
            _ = try await session.send(PBS.createUser(draft))
            let users = try await session.send(PBS.users())
            let created = try #require(users.value.first { $0.id == user })
            #expect(BackupServerUserDraft(created).serialized() == draft.serialized())

            var edited = BackupServerUserDraft(created)
            edited.comment = ""
            edited.isEnabled = false
            edited.expires = Date(timeIntervalSince1970: 2_000_000_000)
            _ = try await session.send(PBS.updateUser(user, edited.changes(from: BackupServerUserDraft(created), digest: users.digest)))
            let changed = try #require(try await session.send(PBS.users()).value.first { $0.id == user })
            #expect(BackupServerUserDraft(changed).serialized() == edited.serialized())
            _ = try await session.send(PBS.changePassword(of: user, to: "pflive-password-2", confirmation: nil))

            // A token, its permission, a new secret.
            var token = BackupServerTokenDraft()
            token.name = "sync"
            token.comment = "Live token"
            let secret = try await session.send(PBS.createToken(of: user, token))
            #expect(secret.tokenID == "\(user)!sync")
            #expect(!secret.secret.isEmpty)
            let entry = BackupServerACLEntry(path: "/datastore/store1", authID: secret.tokenID, role: "DatastoreReader", propagates: false)
            _ = try await session.send(PBS.setACL(entry))
            #expect(try await session.send(PBS.acl(path: "/datastore/store1", exact: true)).value.contains(entry))
            _ = try await session.send(PBS.setACL(entry, remove: true))
            if try await session.send(PBS.version()).supports(.regenerateTokenSecret) {
                let regenerated = try await session.send(PBS.regenerateToken(of: user, name: "sync"))
                #expect(!regenerated.secret.isEmpty && regenerated.secret != secret.secret)
            }
            var editedToken = BackupServerTokenDraft(try #require(try await session.send(PBS.users()).value.first { $0.id == user }?.tokens.first))
            let tokenOriginal = editedToken
            editedToken.isEnabled = false
            _ = try await session.send(PBS.updateToken(of: user, name: "sync", editedToken.changes(from: tokenOriginal)))
            #expect(try await session.send(PBS.users()).value.first { $0.id == user }?.tokens.first?.isEnabled == false)
            _ = try await session.send(PBS.deleteToken(of: user, name: "sync"))

            // Second factors through the requests the shared screens use.
            let totp = TOTPSecret.random(issuer: "Proxmox Backup Server", account: user)
            _ = try await session.send(PVE.addTOTP(userid: user, secret: totp, code: Self.totp(secret: totp.secret), description: "Live", password: nil))
            _ = try await session.send(PVE.addRecoveryKeys(userid: user, password: nil))
            let factors = try #require(try await session.send(PVE.twoFactors()).first { $0.userid == user })
            #expect(Set(factors.entries.map(\.type)) == ["totp", "recovery"])
            for factor in factors.entries {
                _ = try await session.send(PVE.deleteTwoFactor(userid: user, id: factor.id, password: nil))
            }
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await cleanUp()
        try outcome.get()
        #expect(try await !session.send(PBS.users()).value.contains { $0.id == user })
    }

    /// An OpenID Connect realm, only its configuration, and the PAM realm's comment changed and set back. (LDAP and
    /// Active Directory realms need a reachable directory: the server connects to it when they are saved.)
    @Test func realmConfiguration() async throws {
        let session = try await signedIn()
        func cleanUp() async {
            _ = try? await session.send(PBS.deleteRealm(.openid, "pflive"))
        }
        await cleanUp()
        let outcome: Result<Void, any Error>
        do {
            var openID = BackupServerRealmDraft(kind: .openid)
            openID.realm = "pflive"
            openID.issuerURL = "https://sso.invalid/realms/main"
            openID.clientID = "proxmox-backup"
            openID.clientKey = "client-secret"
            openID.scopes = "email profile"
            openID.usernameClaim = "email"
            openID.autocreate = true
            openID.comment = "ProxFleet live test"
            _ = try await session.send(PBS.createRealm(openID))
            #expect(try await session.send(ProxmoxAccess.realms()).contains { $0.realm == "pflive" && $0.type == "openid" })
            let stored = try await session.send(PBS.realmConfig(.openid, "pflive"))
            let read = BackupServerRealmDraft(kind: .openid, realm: "pflive", config: stored.value)
            #expect(read.serialized() == openID.serialized())
            // Unlike LDAP bind passwords, the client key is returned; the form still only sends a typed one.
            #expect(stored.value.values["client-key"] == "client-secret")
            var edited = read
            edited.scopes = ""
            edited.autocreate = false
            _ = try await session.send(PBS.updateRealm(.openid, "pflive", edited.update(from: read, digest: stored.digest)))
            #expect(BackupServerRealmDraft(kind: .openid, realm: "pflive", config: try await session.send(PBS.realmConfig(.openid, "pflive")).value).serialized() == edited.serialized())

            let pam = try await session.send(PBS.realmConfig(.pam, "pam"))
            let pamDraft = BackupServerRealmDraft(kind: .pam, realm: "pam", config: pam.value)
            var renamed = pamDraft
            renamed.comment = "ProxFleet live test"
            _ = try await session.send(PBS.updateRealm(.pam, "pam", renamed.update(from: pamDraft, digest: pam.digest)))
            #expect(try await session.send(ProxmoxAccess.realms()).first { $0.realm == "pam" }?.comment == "ProxFleet live test")
            _ = try await session.send(PBS.updateRealm(.pam, "pam", pamDraft.update(from: renamed, digest: nil)))
            #expect(try await session.send(ProxmoxAccess.realms()).first { $0.realm == "pam" }?.comment == pamDraft.comment)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await cleanUp()
        try outcome.get()
    }

    /// A sendmail target and a matcher through the requests the shared notification screens use, rewritten for the
    /// backup server; two cleared settings go as two deletions.
    @Test func notifications() async throws {
        let session = try await signedIn()
        func cleanUp() async {
            _ = try? await session.send(PBS.notificationRequest(PVE.deleteNotificationMatcher("pflive-matcher")))
            _ = try? await session.send(PBS.notificationRequest(PVE.deleteNotificationEndpoint(.sendmail, name: "pflive-mail")))
        }
        await cleanUp()
        let outcome: Result<Void, any Error>
        do {
            var endpoint = NotificationEndpointDraft(type: .sendmail)
            endpoint.name = "pflive-mail"
            endpoint.mailtoUsers = ["root@pam"]
            endpoint.comment = "ProxFleet live test"
            _ = try await session.send(PBS.notificationRequest(PVE.createNotificationEndpoint(endpoint)))
            var matcher = NotificationMatcherDraft()
            matcher.name = "pflive-matcher"
            matcher.comment = "ProxFleet live test"
            matcher.severities = [.error]
            matcher.targets = ["pflive-mail"]
            _ = try await session.send(PBS.notificationRequest(PVE.createNotificationMatcher(matcher)))
            let matchers = try await session.send(PBS.notificationRequest(PVE.notificationMatchers()))
            let created = try #require(matchers.first { $0.name == "pflive-matcher" })
            #expect(created.targets == ["pflive-mail"])
            var edited = NotificationMatcherDraft(created)
            edited.comment = ""
            edited.severities = []
            _ = try await session.send(PBS.notificationRequest(PVE.updateNotificationMatcher(created.name, edited.changes(from: NotificationMatcherDraft(created)), digest: created.config.digest)))
            let changed = try #require(try await session.send(PBS.notificationRequest(PVE.notificationMatchers())).first { $0.name == "pflive-matcher" })
            #expect(changed.comment == nil)
            #expect(NotificationMatcherDraft(changed).severities.isEmpty)
            #expect(try await session.send(PBS.notificationRequest(PVE.notificationTargets())).contains { $0.name == "pflive-mail" })
            #expect(try await !session.send(PBS.notificationRequest(PVE.matcherFieldValues())).isEmpty)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await cleanUp()
        try outcome.get()
    }

    /// Traffic control, a disabled UDP metric server and an S3 endpoint, as configuration only.
    @Test func trafficMetricsAndS3Configuration() async throws {
        let session = try await signedIn()
        let version = try await session.send(PBS.version())
        func cleanUp() async {
            _ = try? await session.send(PBS.deleteTrafficControlRule("pflive-tc"))
            _ = try? await session.send(PBS.deleteMetricServer(.influxDBUDP, "pflive-udp"))
            _ = try? await session.send(PBS.deleteS3Endpoint("pflive-s3"))
        }
        await cleanUp()
        let outcome: Result<Void, any Error>
        do {
            var rule = TrafficControlDraft()
            rule.name = "pflive-tc"
            rule.networks = ["10.255.0.0/16", "fd00:ffff::/32"]
            rule.rateIn = ByteRate(amount: "10", unit: .mib)
            rule.burstIn = ByteRate(amount: "20", unit: .mib)
            rule.timeframes = ["mon..fri 8:00-18:00"]
            if version.supports(.userTrafficControl) { rule.users = ["root@pam"] }
            _ = try await session.send(PBS.createTrafficControlRule(rule))
            let rules = try await session.send(PBS.trafficControlRules())
            let created = try #require(rules.value.first { $0.name == "pflive-tc" })
            #expect(TrafficControlDraft(created) == { var expected = rule; expected.name = created.name; return expected }())
            var edited = TrafficControlDraft(created)
            edited.timeframes = []
            edited.burstIn = ByteRate()
            _ = try await session.send(PBS.updateTrafficControlRule("pflive-tc", edited.changes(from: TrafficControlDraft(created), digest: rules.digest)))
            #expect(TrafficControlDraft(try #require(try await session.send(PBS.trafficControlRules()).value.first { $0.name == "pflive-tc" })) == edited)
            #expect(try await session.send(PBS.trafficControlStatus()).contains { $0.name == "pflive-tc" })

            var udp = BackupServerMetricServerDraft(kind: .influxDBUDP)
            udp.name = "pflive-udp"
            udp.host = "127.0.0.1:8089"
            udp.isEnabled = false
            udp.mtu = 1400
            _ = try await session.send(PBS.createMetricServer(udp))
            let listed = try #require(try await session.send(PBS.metricServers()).value.first { $0.name == "pflive-udp" })
            #expect(listed.kind == .influxDBUDP && !listed.isEnabled)
            let config = try await session.send(PBS.metricServer(.influxDBUDP, "pflive-udp"))
            let read = BackupServerMetricServerDraft(kind: .influxDBUDP, name: "pflive-udp", config: config.value)
            #expect(read.serialized() == udp.serialized())
            var changedUDP = read
            changedUDP.mtu = nil
            _ = try await session.send(PBS.updateMetricServer(.influxDBUDP, "pflive-udp", changedUDP.update(from: read, digest: config.digest)))

            if version.supports(.s3Datastores) {
                var s3 = S3EndpointDraft()
                s3.id = "pflive-s3"
                s3.endpoint = "s3.invalid"
                s3.port = 9000
                s3.region = "us-east-1"
                s3.accessKey = "pflive"
                s3.secretKey = "pflive-secret"
                s3.usesPathStyle = true
                s3.skipsIfNoneMatch = true
                _ = try await session.send(PBS.createS3Endpoint(s3))
                let endpoint = try #require(try await session.send(PBS.s3Endpoints()).value.first { $0.id == "pflive-s3" })
                var expected = s3
                expected.secretKey = ""
                #expect(S3EndpointDraft(endpoint) == expected)
                // Nothing answers at that address.
                await #expect(throws: ProxmoxError.self) { _ = try await session.send(PBS.s3Buckets("pflive-s3")) }
            }
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await cleanUp()
        try outcome.get()
    }
}

// MARK: - S3 on a local test server

extension LiveBackupServerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROXFLEET_PBS_PROBE"] != nil))
    func probeServer() async throws {
        let session = try await signedIn()
        let command = try String(contentsOfFile: ProcessInfo.processInfo.environment["PROXFLEET_PBS_PROBE"]!, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await runOnServer(session, command, timeout: 120)
        print("PROBE-OUTPUT-BEGIN\n\(result.output)\nPROBE-OUTPUT-END status \(result.status ?? -1)")
    }

    /// Sets up an S3 server on the test server for `s3DatastoreOnLocalS3`: moto from Debian's packages, with a
    /// self-signed certificate, on 127.0.0.1:9000, as the service `pflive-s3`. MinIO no longer publishes binaries.
    /// Run once with `PROXFLEET_PBS_SETUP_S3=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROXFLEET_PBS_SETUP_S3"] == "1"))
    func setUpLocalS3() async throws {
        let session = try await signedIn()
        // A subshell, so a failing step ends it and not the terminal's shell.
        let script = """
        ( set -e
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-moto python3-flask python3-flask-cors >/dev/null
        mkdir -p /etc/pflive-s3
        [ -f /etc/pflive-s3/cert.pem ] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=127.0.0.1 \\
          -addext subjectAltName=IP:127.0.0.1 -keyout /etc/pflive-s3/key.pem -out /etc/pflive-s3/cert.pem 2>/dev/null
        printf '[Unit]\\nDescription=S3 server for ProxFleet live tests\\nAfter=network-online.target\\n[Service]\\nExecStart=/usr/bin/python3 -m moto.server -H 127.0.0.1 -p 9000 -c /etc/pflive-s3/cert.pem -k /etc/pflive-s3/key.pem\\nRestart=always\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/pflive-s3.service
        systemctl daemon-reload
        systemctl enable --now pflive-s3 >/dev/null 2>&1
        for i in $(seq 1 30); do curl -sk -o /dev/null https://127.0.0.1:9000/ && break; sleep 1; done
        systemctl is-active pflive-s3 )
        """
        let result = try await runOnServer(session, script, timeout: 280)
        #expect(result.status == 0, "\(result.output)")
    }

    /// An S3 endpoint for the local S3 server, its buckets, and a datastore in a bucket, removed again with its data.
    @Test(.timeLimit(.minutes(5))) func s3DatastoreOnLocalS3() async throws {
        let session = try await signedIn()
        guard try await session.send(PBS.version()).supports(.s3Datastores), let access = server["S3_TEST_ACCESS_KEY"], let secret = server["S3_TEST_SECRET_KEY"] else { return }
        let status = try await runOnServer(session, "systemctl is-active pflive-s3")
        try #require(status.status == 0, "the local S3 server is not set up; run setUpLocalS3 first")
        // The server keeps buckets in memory, so the test makes its own.
        _ = try await runOnServer(session, "curl -sk -X PUT https://127.0.0.1:9000/pflive-bucket -o /dev/null")
        let certificate = try await runOnServer(session, "openssl x509 -in /etc/pflive-s3/cert.pem -noout -fingerprint -sha256")
        // The terminal echoes the command too; the fingerprint is the only such pattern.
        let fingerprint = certificate.output.firstMatch(of: /([0-9A-F]{2}:){31}[0-9A-F]{2}/).map { String($0.output.0) }
        let store = "pflive-s3ds"
        func cleanUp() async {
            try? await removeLeftover(store, in: session)
            _ = try? await session.send(PBS.deleteS3Endpoint("pflive-s3"))
            _ = try? await runOnServer(session, "rm -rf /datastore/\(store)")
        }
        await cleanUp()
        let outcome: Result<Void, any Error>
        do {
            var endpoint = S3EndpointDraft()
            endpoint.id = "pflive-s3"
            endpoint.endpoint = "127.0.0.1"
            endpoint.port = 9000
            endpoint.region = "us-east-1"
            endpoint.usesPathStyle = true
            endpoint.accessKey = access
            endpoint.secretKey = secret
            endpoint.fingerprint = try #require(fingerprint, "no certificate fingerprint").lowercased()
            _ = try await session.send(PBS.createS3Endpoint(endpoint))
            #expect(try await session.send(PBS.s3Buckets("pflive-s3")).names.contains("pflive-bucket"))

            var datastore = DatastoreDraft()
            datastore.kind = .s3
            datastore.name = store
            datastore.path = "/datastore/\(store)"
            datastore.s3Endpoint = "pflive-s3"
            datastore.bucket = "pflive-bucket"
            datastore.pruneSchedule = ""
            #expect(datastore.problems(isNew: true).isEmpty)
            let created = try await session.send(PBS.createDatastore(datastore.creationParameters(usesNotificationSystem: true)))
            let task = try await waitForTask(created, in: session)
            #expect(task.succeeded, "\(task.exitStatus ?? "")")
            let config = try #require(try await session.send(PBS.datastoreConfigs()).value.first { $0.name == store })
            #expect(config.isS3)
            #expect(try await session.send(PBS.datastoreStatus(store)).total > 0)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await cleanUp()
        try outcome.get()
        #expect(try await !session.send(PBS.s3Endpoints()).value.contains { $0.id == "pflive-s3" })
    }
}

/// Collects download progress from the transport's callback.
private final class ProgressRecorder: Sendable {
    private let value = Mutex<Int64>(0)

    func record(_ received: Int64) {
        value.withLock { $0 = max($0, received) }
    }

    var latest: Int64 { value.withLock { $0 } }
}
