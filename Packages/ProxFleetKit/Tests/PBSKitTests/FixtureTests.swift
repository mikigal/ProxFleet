import Foundation
@testable import PBSKit
import ProxmoxCore
import PVEKit
import Testing

private struct Envelope<T: Decodable>: Decodable {
    var data: T
}

private func url(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/pbs-4.2"))
}

/// The `data` of a response recorded on Proxmox Backup Server 4.2.
func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    try JSONDecoder().decode(Envelope<T>.self, from: Data(contentsOf: url(name))).data
}

/// A whole recorded response, for types that read more of it than `data`.
func envelopeFixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: url(name)))
}

struct ServerFixtureTests {
    @Test func versionAndFeatures() throws {
        let version = try fixture("version", as: PBSVersion.self)
        #expect(version.version == "4.2")
        #expect(version.number == PVEVersionNumber(4, 2, 0))
        #expect(version.displayVersion == "4.2.0")
        #expect(version.isSupported)
        #expect(PBSFeature.allCases.allSatisfy(version.supports))
    }

    @Test func nodeStatusReadsTheRootDisk() throws {
        let status = try fixture("node-status", as: NodeStatus.self)
        #expect(status.cpuCount == 2)
        #expect(status.cpuModel?.contains("Xeon") == true)
        #expect(status.memoryTotal > 0)
        #expect(status.rootTotal > 0 && status.rootUsed > 0)
        #expect(status.loadAverage.count == 3)
        #expect(status.kernel == "7.0.0-3-pve")
        #expect(status.bootMode == "efi")
        #expect(status.secureBoot)
        #expect(status.uptime > 0)
    }

    @Test func nodeHistory() throws {
        let points = try fixture("node-rrd-hour", as: [RRDPoint].self)
        #expect(!points.isEmpty)
        let latest = try #require(points.last { $0.hasData })
        #expect(latest.memoryTotal ?? 0 > 0)
        #expect(latest.storageTotal ?? 0 > 0)
        #expect(latest.networkIn != nil)
    }

    @Test func tasksReadWorkerTypesAndMatchTheirUPIDs() throws {
        let tasks = try fixture("node-tasks", as: [ClusterTask].self)
        #expect(tasks.count > 10)
        for task in tasks {
            let upid = try #require(UPID(task.upid))
            #expect(upid.type == task.type)
            // The server unescapes the worker ID itself; the UPID parser must come to the same result.
            #expect(upid.objectID == (task.objectID ?? ""))
        }
        let backup = try #require(tasks.first { $0.type == "backup" && $0.objectID == "store1:ct/200" })
        #expect(backup.succeeded)
        let failed = try #require(tasks.first { $0.objectID?.hasSuffix("pf-broken") == true })
        #expect(!failed.succeeded)
        #expect(failed.status?.contains("no such datastore") == true)
    }

    @Test func taskTitlesLikeTheWebInterface() {
        #expect(TaskDescription.title(type: "backup", objectID: "store1:ct/200") == "store1 ct/200 – Backup")
        #expect(TaskDescription.title(type: "reader", objectID: "store1:host/nested-host/6ADCBC72") == "store1 host/nested-host – Read Objects")
        #expect(TaskDescription.title(type: "syncjob", objectID: "self:store1:store2::pf-sync-pull") == "pf-sync-pull – Sync Job")
        #expect(TaskDescription.title(type: "verificationjob", objectID: "store1:pf-verify") == "pf-verify – Verify Job")
        #expect(TaskDescription.title(type: "garbage_collection", objectID: "store1") == "store1 – Garbage Collection")
        // Verification tasks name the namespace, a lone "/" standing for the root.
        #expect(TaskDescription.title(type: "verify_snapshot", objectID: "store1:/host/pbs-claude/6ADCBC70") == "store1 host/pbs-claude – Verify Snapshot")
        #expect(TaskDescription.title(type: "verify_snapshot", objectID: "store1:ns/pve/ns/nested/host/nested-host/6ADCBC72") == "store1:pve/nested host/nested-host – Verify Snapshot")
        #expect(TaskDescription.title(type: "verify_group", objectID: "store1:ns/pve/ct/200") == "store1:pve ct/200 – Verify Group")
        #expect(TaskDescription.title(type: "verify", objectID: "store1:ns/pve") == "store1:pve – Verification")
        #expect(TaskDescription.title(type: "logrotate", objectID: nil) == "Log Rotation")
        // Proxmox VE titles stay as they were.
        #expect(TaskDescription.title(type: "qmstart", objectID: "100") == "VM 100 – Start")
    }

    @Test func taskStatusesAndLogs() throws {
        #expect(try fixture("task-status-verify-ok", as: TaskStatus.self).succeeded)
        #expect(try fixture("task-status-sync-warnings", as: TaskStatus.self).succeeded)
        let failed = try fixture("task-status-sync-failed", as: TaskStatus.self)
        #expect(!failed.succeeded)
        #expect(failed.exitStatus?.contains("no such datastore 'missing'") == true)
        let log = try fixture("task-log-gc-ok", as: [TaskLogLine].self)
        #expect(log.contains { $0.text.contains("TASK OK") })
    }
}

struct DatastoreFixtureTests {
    @Test func summaries() throws {
        let stores = try fixture("admin-datastore", as: [DatastoreSummary].self)
        #expect(stores.map(\.store).sorted() == ["store1", "store2"])
        let store1 = try #require(stores.first { $0.store == "store1" })
        #expect(store1.comment == "Main test datastore")
        #expect(store1.mountStatus == .nonRemovable)
        #expect(!store1.isS3)
        #expect(store1.maintenance == nil)
    }

    @Test func usageWithHistory() throws {
        let usage = try fixture("status-datastore-usage", as: [DatastoreUsage].self)
        let store1 = try #require(usage.first { $0.store == "store1" })
        #expect(store1.total > store1.used)
        #expect(store1.available > 0)
        #expect(store1.usedFraction > 0 && store1.usedFraction < 1)
        #expect(!store1.history.isEmpty)
        #expect(store1.historyInterval == 1800)
        #expect(store1.historyStart != nil)
        #expect(store1.garbageCollection?.store == nil || store1.garbageCollection?.store == "store1")
    }

    @Test func statusWithCountsAndGarbageCollection() throws {
        let status = try fixture("datastore-status", as: DatastoreStatus.self)
        #expect(status.counts[.ct]?.groups == 1)
        #expect(status.counts[.ct]?.snapshots == 2)
        #expect(status.counts[.vm]?.snapshots == 2)
        #expect(status.counts[.host]?.groups == 2)
        #expect(status.otherCounts == nil)
        let gc = try #require(status.garbageCollection)
        #expect(gc.indexFileCount > 0)
        #expect(gc.deduplicationFactor ?? 0 > 1)
    }

    @Test func garbageCollectionJobs() throws {
        let single = try fixture("datastore-gc", as: GarbageCollectionStatus.self)
        #expect(single.store == "store1")
        #expect(single.schedule == "daily")
        #expect(single.lastRunState == "OK")
        #expect(single.nextRun != nil)
        #expect(single.duration == 2)
        let jobs = try fixture("admin-gc", as: [GarbageCollectionStatus].self)
        let neverRun = try #require(jobs.first { $0.store == "store2" })
        #expect(neverRun.upid == nil)
        #expect(neverRun.lastRunState == nil)
        #expect(neverRun.deduplicationFactor == nil)
    }

    @Test func history() throws {
        let points = try fixture("datastore-rrd-hour", as: [DatastoreRRDPoint].self)
        let latest = try #require(points.last { $0.hasData })
        #expect(latest.total ?? 0 > 0)
        #expect(latest.available ?? 0 > 0)
        #expect(latest.readOperations != nil)
    }

    @Test func configurationsWithDigest() throws {
        let list = try envelopeFixture("config-datastore", as: Digested<[DatastoreConfig]>.self)
        #expect(list.digest?.count == 64)
        let store1 = try #require(list.value.first { $0.name == "store1" })
        #expect(store1.path == "/datastore/store1")
        #expect(store1.gcSchedule == "daily")
        #expect(store1.retention.keepsEverything)
        #expect(!store1.isRemovable)
        let single = try envelopeFixture("config-datastore-store1", as: Digested<DatastoreConfig>.self)
        #expect(single.value.values["comment"] == "Main test datastore")
        #expect(single.digest != nil)
    }

    @Test func activeOperations() throws {
        let operations = try fixture("datastore-active-operations", as: DatastoreOperations.self)
        #expect(operations.read == 0 && operations.write == 0)
    }
}

struct ContentFixtureTests {
    @Test func namespaces() throws {
        let namespaces = try fixture("datastore-namespaces", as: [BackupNamespace].self)
        #expect(namespaces.map(\.path) == ["", "pve", "pve/nested"])
        let nested = namespaces[2]
        #expect(nested.name == "nested")
        #expect(nested.depth == 2)
        #expect(nested.parent == BackupNamespace("pve"))
        #expect(namespaces[0].isRoot)
        #expect(BackupNamespace("pve").contains(nested))
        #expect(!BackupNamespace("pv").contains(nested))
        #expect(BackupNamespace.root.child("pve") == BackupNamespace("pve"))
    }

    @Test func groups() throws {
        let groups = try fixture("datastore-groups-ns-pve", as: [BackupGroup].self).map { $0.in(BackupNamespace("pve")) }
        let container = try #require(groups.first { $0.reference.type == .ct })
        #expect(container.reference.backupID == "200")
        #expect(container.reference.path == "ct/200")
        #expect(container.reference.namespace.path == "pve")
        #expect(container.snapshotCount == 2)
        #expect(container.owner == "pvebackup@pbs")
        #expect(container.comment == "Alpine test container")
        #expect(container.lastBackup != nil)
        let vm = try #require(groups.first { $0.reference.type == .vm })
        #expect(vm.comment == nil)
        #expect(vm.files.contains("drive-scsi0.img.fidx"))
    }

    @Test func snapshots() throws {
        let snapshots = try fixture("datastore-snapshots-ns-pve", as: [BackupSnapshot].self)
        #expect(snapshots.count == 4)
        let containers = snapshots.filter { $0.reference.group.type == .ct }.sorted { $0.reference.time < $1.reference.time }
        #expect(containers.first?.isProtected == true)
        #expect(containers.last?.isProtected == false)
        let snapshot = try #require(containers.first)
        #expect(snapshot.verification?.succeeded == true)
        #expect(snapshot.comment == "alpine-dns seed")
        #expect(snapshot.cryptMode == nil)
        #expect(snapshot.browsableArchives.map(\.name) == ["root.pxar.didx"])
        let vm = try #require(snapshots.first { $0.reference.group.type == .vm })
        #expect(vm.files.first { $0.name == "drive-scsi0.img.fidx" }?.kind == .diskImage)
        #expect(vm.files.first { $0.name == "client.log.blob" }?.size == nil)
        #expect(vm.size ?? 0 > 4_000_000_000)
    }

    @Test func snapshotFiles() throws {
        let files = try fixture("snapshot-files-ct", as: [SnapshotFile].self)
        #expect(files.map(\.kind).contains(.catalog))
        #expect(files.first { $0.name == "root.pxar.didx" }?.displayName == "root.pxar")
        #expect(files.first { $0.name == "pct.conf.blob" }?.cryptMode == CryptMode.none)
        let host = try fixture("snapshot-files-host", as: [SnapshotFile].self)
        #expect(host.contains { $0.name == "etc.pxar.didx" && $0.kind == .fileArchive })
    }

    @Test func catalog() throws {
        let root = try fixture("catalog-ct-root", as: [CatalogEntry].self)
        #expect(root.map(\.name) == ["root.pxar.didx"])
        #expect(root[0].isDirectory)
        #expect(root[0].decodedPath == "/root.pxar.didx")
        let archive = try fixture("catalog-ct-archive", as: [CatalogEntry].self)
        let bin = try #require(archive.first { $0.name == "bin" })
        #expect(bin.kind == .directory)
        #expect(bin.decodedPath == "root.pxar.didx/bin")
        let directory = try fixture("catalog-ct-directory", as: [CatalogEntry].self)
        #expect(directory.contains { $0.kind == .symlink && $0.isLeaf })
        let files = try fixture("catalog-host-archive", as: [CatalogEntry].self)
        let file = try #require(files.first { $0.kind == .file && ($0.size ?? 0) > 0 })
        #expect(file.modified != nil)
        #expect(!file.isDirectory)
    }

    @Test func groupNotesKeepEveryLine() throws {
        #expect(try fixture("group-notes", as: String?.self) == "Alpine test container\nSecond line")
    }
}

struct JobFixtureTests {
    @Test func verifyJobs() throws {
        let job = try #require(try fixture("admin-verify", as: [VerifyJob].self).first)
        #expect(job.id == "pf-verify")
        #expect(job.store == "store1")
        #expect(job.namespace.isRoot)
        #expect(job.skipVerified)
        #expect(job.reverifyAfterDays == 30)
        #expect(job.state.lastRunState == "OK")
        #expect(job.state.lastRunSucceeded == true)
        #expect(!job.state.isRunning)
        #expect(job.state.nextRun != nil)
    }

    @Test func pruneJobs() throws {
        let job = try #require(try fixture("admin-prune", as: [PruneJob].self).first)
        #expect(job.retention == RetentionPolicy(last: 3, daily: 7, weekly: 4))
        #expect(job.schedule == "daily")
        #expect(!job.isDisabled)
    }

    @Test func syncJobs() throws {
        let pull = try fixture("admin-sync", as: [SyncJob].self)
        let local = try #require(pull.first { $0.id == "pf-sync-local" })
        #expect(local.isLocal)
        #expect(local.direction == .pull)
        #expect(local.store == "store2" && local.remoteStore == "store1")
        let remote = try #require(pull.first { $0.id == "pf-sync-pull" })
        #expect(remote.remote == "self")
        #expect(remote.remoteNamespace == BackupNamespace("pve"))
        #expect(!remote.removeVanished)
        let push = try #require(try fixture("admin-sync-push", as: [SyncJob].self).first)
        #expect(push.direction == .push)
        #expect(push.groupFilters == ["type:host"])
        #expect(push.state.lastRunState == "WARNINGS: 2")
        #expect(push.state.lastRunSucceeded == true)
    }

    @Test func remotesAndScans() throws {
        let remotes = try envelopeFixture("config-remote", as: Digested<[BackupRemote]>.self)
        let remote = try #require(remotes.value.first)
        #expect(remote.name == "self")
        #expect(remote.authID == "root@pam!seed")
        #expect(remote.address == "127.0.0.1")
        #expect(remote.fingerprint?.hasPrefix("8e:58") == true)
        #expect(try fixture("remote-scan", as: [DatastoreSummary].self).count == 2)
        #expect(try fixture("remote-scan-namespaces", as: [BackupNamespace].self).contains(BackupNamespace("pve/nested")))
        #expect(try fixture("remote-scan-groups", as: [BackupGroup].self).count == 2)
    }

    @Test func trafficControl() throws {
        let rules = try envelopeFixture("config-traffic-control", as: Digested<[TrafficControlRule]>.self).value
        let rule = try #require(rules.first)
        #expect(rule.networks == ["10.0.0.0/8", "192.168.0.0/16"])
        #expect(rule.rateIn == "100 MiB")
        #expect(rule.timeframes == ["mon..fri 8:00-18:00"])
        #expect(rule.users.isEmpty)
        #expect(rule.currentRateIn == nil)
        let status = try #require(try fixture("admin-traffic-control", as: [TrafficControlRule].self).first)
        #expect(status.currentRateIn == 0)
    }
}
