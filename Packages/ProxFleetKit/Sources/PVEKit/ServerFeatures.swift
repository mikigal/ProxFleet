import Foundation

/// A Proxmox VE version such as 8.4.0, compared part by part.
public struct PVEVersionNumber: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads `8.4`, `9.2.21` or a beta build like `9.0.0~11`.
    public init?(parsing text: String) {
        let parts = text.split { !$0.isNumber }.prefix(3).compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        self.init(parts[0], parts[1], parts.count > 2 ? parts[2] : 0)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// What the app offers only on Proxmox VE releases that have it. Older servers do not show these at all, as their
/// web interface does not either, instead of failing when the user tries them.
public enum PVEFeature: CaseIterable, Sendable {
    // MARK: Datacenter
    /// The notification system with targets and matchers.
    case notifications
    case webhookNotifications
    case datacenterBulkActions
    /// Parallel jobs for node bulk start, shutdown and hibernate, and `max-workers` instead of `maxworkers`.
    case bulkActionParallelJobs
    case metricServerOpenTelemetry
    /// The datacenter's and the nodes' location.
    case locations
    /// Datacenter options for replication traffic, which used the migration settings before.
    case replicationOptions
    case directoryMappings
    case openIDAudiences
    /// OpenID group claims and turning off userinfo queries.
    case openIDGroups
    /// Node bulk hibernate (`suspendall`).
    case bulkHibernate
    /// Wake on LAN from a chosen interface and broadcast address.
    case wakeOnLANOptions
    case nodeBallooningTarget

    // MARK: High availability
    /// Node and resource affinity rules, which replaced HA groups.
    case haRules
    case haRulePurge
    case haFailback
    case haArming
    /// Dynamic load scheduling and automatic rebalancing.
    case haLoadBalancing

    // MARK: SDN
    case sdnDHCP
    case sdnVNetFirewall
    case sdnFabrics
    case sdnRevert
    /// Node views of bridges, VRFs and fabrics, and SDN entries of `/cluster/resources` with type `network`.
    case sdnNodeStatus
    case sdnRouteFilters
    /// More than one EVPN controller, controllers limited to some nodes, and their BGP session settings.
    case sdnEVPNControllerOptions

    // MARK: Storage and backups
    case esxiImport
    case volumeChainSnapshots
    case backupFleecing
    /// Change detection modes for container backups to Proxmox Backup Server.
    case backupChangeDetection
    case cephManualRepository

    // MARK: Guests
    case conntrackMigration
    /// `ha-managed` when creating or restoring a guest.
    case haManagedCreation
    /// OCI images, and the entrypoint, environment and host-managed network of application containers.
    case applicationContainers
    /// Host devices passed through into containers (`dev0` and up).
    case containerDevices
    case vmKSMControl
    case intelTDX
    /// Recording the enrolled Microsoft UEFI certificates (`ms-cert`) of EFI disks.
    case efiMicrosoftCertificates
    /// The guest agent's `freeze-fs`, called `freeze-fs-on-backup` before.
    case agentFreezeFS
    case vmArchitecture
    case virtiofs

    /// The release that brought it, from the Proxmox VE release notes.
    public var introduced: PVEVersionNumber {
        switch self {
        case .notifications, .sdnDHCP, .bulkHibernate, .containerDevices: PVEVersionNumber(8, 1)
        case .esxiImport, .backupFleecing, .wakeOnLANOptions: PVEVersionNumber(8, 2)
        case .webhookNotifications, .backupChangeDetection, .sdnVNetFirewall: PVEVersionNumber(8, 3)
        case .directoryMappings, .virtiofs, .nodeBallooningTarget, .openIDGroups: PVEVersionNumber(8, 4)
        case .haRules, .haFailback, .sdnFabrics, .sdnRevert, .metricServerOpenTelemetry, .replicationOptions,
             .volumeChainSnapshots, .conntrackMigration:
            PVEVersionNumber(9, 0)
        case .datacenterBulkActions, .haRulePurge, .sdnNodeStatus, .cephManualRepository, .haManagedCreation,
             .applicationContainers, .vmKSMControl, .intelTDX:
            PVEVersionNumber(9, 1)
        case .bulkActionParallelJobs, .locations, .openIDAudiences, .haArming, .haLoadBalancing, .sdnRouteFilters,
             .sdnEVPNControllerOptions, .efiMicrosoftCertificates, .agentFreezeFS, .vmArchitecture:
            PVEVersionNumber(9, 2)
        }
    }
}

extension PVEVersion {
    public var number: PVEVersionNumber? { PVEVersionNumber(parsing: version) }

    /// Whether this release has the feature. A version the app cannot read counts as new enough.
    public func supports(_ feature: PVEFeature) -> Bool {
        guard let number else { return true }
        return number >= feature.introduced
    }
}
