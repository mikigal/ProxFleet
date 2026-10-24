import Foundation
import ProxmoxCore
import PVEKit

/// `GET /version`. Proxmox Backup Server reports `4.2` as the version and the patch level separately as `release`.
public struct PBSVersion: Decodable, Sendable, Equatable {
    public var version: String
    public var release: String?
    public var repositoryID: String?

    public init(version: String, release: String? = nil, repositoryID: String? = nil) {
        self.version = version
        self.release = release
        self.repositoryID = repositoryID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        version = container.lossyString(AnyCodingKey("version")) ?? "unknown"
        release = container.lossyString(AnyCodingKey("release"))
        repositoryID = container.lossyString(AnyCodingKey("repoid"))
    }

    /// For example `4.2.0`.
    public var number: PVEVersionNumber? {
        guard var number = PVEVersionNumber(parsing: version) else { return nil }
        if let release, let patch = Int(release) { number.patch = patch }
        return number
    }

    /// The full version for display, e.g. `4.2.0`.
    public var displayVersion: String { number?.description ?? version }

    /// The oldest release ProxFleet supports: 3.0 is the release for Debian 12, like Proxmox VE 8.
    public static let oldestSupported = PVEVersionNumber(3, 0)

    /// False for releases older than `oldestSupported`. A version the app cannot read counts as supported.
    public var isSupported: Bool { number.map { $0 >= Self.oldestSupported } ?? true }

    /// Whether this release has the feature. A version the app cannot read counts as new enough.
    public func supports(_ feature: PBSFeature) -> Bool {
        guard let number else { return true }
        return number >= feature.introduced
    }
}

/// What the app offers only on Proxmox Backup Server releases that have it, like `PVEFeature` for Proxmox VE.
public enum PBSFeature: CaseIterable, Sendable {
    // MARK: Datastores
    case removableDatastores
    /// `reuse-datastore` when creating one on a path that already holds a datastore.
    case reuseDatastore
    /// Garbage collection's atime check, atime cutoff and chunk cache settings in the datastore tuning options.
    case garbageCollectionTuning
    /// S3-compatible object stores as datastore backend, and their endpoints.
    case s3Datastores
    /// Default verification reader and worker threads in the tuning options, and per-job overrides.
    case verificationThreads
    case s3RateLimits
    /// Moving backup groups and namespaces within a datastore.
    case moveGroupsAndNamespaces
    case garbageCollectionOnUnmount
    /// S3 request counters, their notification thresholds and the counter reset schedule.
    case s3Counters

    // MARK: Sync jobs
    /// Group filters that exclude groups (`exclude:` prefix).
    case excludeGroupFilters
    /// Sync jobs that push to a remote, and the `Remote.Datastore*` privileges.
    case pushSync
    /// Pull sync that fetches corrupt snapshots again.
    case resyncCorrupt
    /// Syncing only encrypted or only verified snapshots.
    case encryptedAndVerifiedOnlySync
    /// Running a sync job when its removable datastore is mounted.
    case syncOnMount
    /// Unmounting a removable datastore once its sync job finished.
    case unmountAfterSync
    /// Encrypting snapshots while pushing and decrypting while pulling, with keys from `/config/encryption-keys`.
    case syncEncryption
    /// Groups synced in parallel (`worker-threads`).
    case syncWorkerThreads
    /// Remotes reached through the node's HTTP proxy.
    case remoteProxy

    // MARK: Server
    /// The notification system with targets and matchers, and `notification-mode` on datastores.
    case notifications
    case activeDirectoryRealms
    case webhookNotifications
    /// `GET /status/metrics`.
    case metricsEndpoint
    /// A new secret for an existing API token.
    case regenerateTokenSecret
    /// Traffic control rules that apply to users instead of networks only.
    case userTrafficControl

    /// The release that brought it, from the Proxmox Backup Server roadmap.
    public var introduced: PVEVersionNumber {
        switch self {
        case .notifications, .activeDirectoryRealms, .excludeGroupFilters: PVEVersionNumber(3, 2)
        case .removableDatastores, .reuseDatastore, .pushSync, .resyncCorrupt, .webhookNotifications, .metricsEndpoint:
            PVEVersionNumber(3, 3)
        case .garbageCollectionTuning, .encryptedAndVerifiedOnlySync, .regenerateTokenSecret: PVEVersionNumber(3, 4)
        case .s3Datastores, .syncOnMount: PVEVersionNumber(4, 0)
        case .verificationThreads, .s3RateLimits, .unmountAfterSync, .userTrafficControl: PVEVersionNumber(4, 1)
        case .moveGroupsAndNamespaces, .garbageCollectionOnUnmount, .s3Counters, .syncEncryption, .syncWorkerThreads,
             .remoteProxy:
            PVEVersionNumber(4, 2)
        }
    }
}

extension PBS {
    public static func version() -> APIRequest<PBSVersion> {
        APIRequest(.get, "/version")
    }
}
