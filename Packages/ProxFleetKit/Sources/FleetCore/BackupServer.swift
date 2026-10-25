import Foundation
import PBSKit
import ProxmoxCore
import PVEKit

/// What a Proxmox Backup Server connection keeps current: the server's state and its datastores. The counterpart of
/// `ClusterSnapshot` for Proxmox VE.
public struct BackupServerSnapshot: Sendable, Equatable {
    /// The server's own name, as its tasks carry it.
    public var nodeName: String?
    public var version: PBSVersion?
    /// Nil without `Sys.Audit`, which users who only work with datastores often lack.
    public var status: NodeStatus?
    /// Every datastore the user can see.
    public var datastores: [DatastoreSummary]
    /// Usage of the datastores the user may audit.
    public var usage: [DatastoreUsage]
    public var fetchedAt: Date

    public init(nodeName: String? = nil, version: PBSVersion? = nil, status: NodeStatus? = nil, datastores: [DatastoreSummary] = [],
                usage: [DatastoreUsage] = [], fetchedAt: Date = Date()) {
        self.nodeName = nodeName
        self.version = version
        self.status = status
        self.datastores = datastores
        self.usage = usage
        self.fetchedAt = fetchedAt
    }

    public func usage(of store: String) -> DatastoreUsage? {
        usage.first { $0.store == store }
    }
}

extension ServerConnection {
    public var isBackupServer: Bool { profile.product == .backupServer }

    /// Whether the backup server's release has a feature; true while its version is unknown. Labeled, as both
    /// products have features of the same name.
    public func supports(backupServer feature: PBSFeature) -> Bool {
        backupServer?.version?.supports(feature) ?? true
    }

    /// Loads the backup server's state. Only the list of datastores is required: every signed-in user may read it,
    /// so its failure means the server is unreachable or the session ended.
    func fetchBackupServerSnapshot(previous: BackupServerSnapshot?) async throws -> BackupServerSnapshot {
        let session = session
        async let datastores = session.send(PBS.datastores())
        async let usage = try? session.send(PBS.datastoreUsage())
        async let status = try? session.send(PBS.nodeStatus())
        // The name and release do not change while connected.
        async let nodeName = previous?.nodeName == nil ? try? session.send(PBS.nodes()).first?.name : previous?.nodeName
        async let version = previous?.version == nil ? try? session.send(PBS.version()) : previous?.version
        return BackupServerSnapshot(
            nodeName: await nodeName,
            version: await version,
            status: await status,
            datastores: try await datastores.sorted { $0.store.localizedStandardCompare($1.store) == .orderedAscending },
            usage: await usage ?? [],
            fetchedAt: Date()
        )
    }
}
