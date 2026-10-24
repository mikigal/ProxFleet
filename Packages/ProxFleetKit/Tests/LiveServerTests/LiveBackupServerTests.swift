import CryptoKit
import Foundation
import PBSKit
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
        let sync = try await session.send(PBS.syncJobs())
        #expect(Set(sync.map(\.direction)) == [.pull, .push])
        #expect(try await !session.send(PBS.verifyJobs()).isEmpty)
        #expect(try await !session.send(PBS.pruneJobs()).isEmpty)
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
        let pruneJob = try #require(try await session.send(PBS.pruneJobs(store: name)).first)
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
        #expect(try await session.send(PBS.pruneJobs(store: name)).isEmpty)
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
        defer {
            Task {
                for name in ["pflive-usb2", "pflive-usb"] { try? await removeLeftover(name, in: session) }
                if let upid = try? await session.send(APIRequest<String>(.put, "/nodes/localhost/disks/wipedisk", parameters: ["disk": .string(spare.name)])) {
                    _ = try? await waitForTask(upid, in: session)
                }
            }
        }
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

/// Collects download progress from the transport's callback.
private final class ProgressRecorder: Sendable {
    private let value = Mutex<Int64>(0)

    func record(_ received: Int64) {
        value.withLock { $0 = max($0, received) }
    }

    var latest: Int64 { value.withLock { $0 } }
}
