import Foundation

/// State of the fake Proxmox Backup Server served in demo mode: the server the demo cluster's `pbs` storage backs up to.
public struct DemoBackupServer: Sendable {
    public struct Snapshot: Sendable {
        public var daysAgo: Double
        public var notes: String
        public var isProtected = false
        /// nil when not verified yet.
        public var verified: Bool?
        public var sizeGiB: Double
    }

    public struct Group: Sendable {
        public var namespace: String
        /// `vm`, `ct` or `host`.
        public var type: String
        public var id: String
        public var owner: String
        public var notes: String
        public var snapshots: [Snapshot]
    }

    public struct Datastore: Sendable {
        public var name: String
        public var path: String
        public var comment: String
        public var totalGiB: Double
        public var usedGiB: Double
        /// UUID of the file system of a removable datastore.
        public var backingDevice: String?
        public var isMounted = true
        public var gcSchedule: String?
        public var namespaces: [String]
        public var groups: [Group]
    }

    public var name: String
    public var ip: String
    public var version = "4.2"
    public var release = "1"
    public var datastores: [Datastore]

    /// Daily snapshots for the last `days` days, the newest unverified, the others verified, plus weekly ones.
    static func history(days: Int, weeks: Int, notes: String, sizeGiB: Double, failedVerification: Int? = nil) -> [Snapshot] {
        var snapshots = (0..<days).map { day in
            Snapshot(daysAgo: Double(day) + 0.1, notes: notes, verified: day == 0 ? nil : day != failedVerification, sizeGiB: sizeGiB * (1 - Double(day) * 0.01))
        }
        snapshots += (1...max(1, weeks)).prefix(weeks).map { week in
            Snapshot(daysAgo: Double(days + week * 7) + 0.1, notes: notes, verified: true, sizeGiB: sizeGiB * 0.9)
        }
        return snapshots
    }

    /// The home lab's backup server: nightly backups of the demo cluster's guests and a removable offsite disk.
    public static let homelab = DemoBackupServer(
        name: "pbs",
        ip: "10.0.10.6",
        datastores: [
            Datastore(
                name: "main", path: "/mnt/datastore/main", comment: "Nightly backups of the home lab", totalGiB: 3_726, usedGiB: 1_184,
                gcSchedule: "daily", namespaces: ["", "homelab", "laptops"],
                groups: [
                    Group(namespace: "homelab", type: "vm", id: "100", owner: "backup@pbs", notes: "home-assistant",
                          snapshots: history(days: 7, weeks: 3, notes: "home-assistant", sizeGiB: 32)
                            + [Snapshot(daysAgo: 8.2, notes: "Before the 2026.10 update", isProtected: true, verified: true, sizeGiB: 31)]),
                    Group(namespace: "homelab", type: "vm", id: "101", owner: "backup@pbs", notes: "truenas\nBoot disk only, the pool is replicated.",
                          snapshots: history(days: 7, weeks: 3, notes: "truenas", sizeGiB: 64)),
                    Group(namespace: "homelab", type: "vm", id: "103", owner: "backup@pbs", notes: "ubuntu-dev",
                          snapshots: history(days: 5, weeks: 2, notes: "ubuntu-dev", sizeGiB: 64)),
                    Group(namespace: "homelab", type: "vm", id: "104", owner: "backup@pbs", notes: "docker-host",
                          snapshots: history(days: 7, weeks: 3, notes: "docker-host", sizeGiB: 100, failedVerification: 3)),
                    Group(namespace: "homelab", type: "ct", id: "200", owner: "backup@pbs", notes: "pihole",
                          snapshots: history(days: 7, weeks: 3, notes: "pihole", sizeGiB: 1.4)),
                    Group(namespace: "homelab", type: "ct", id: "201", owner: "backup@pbs", notes: "nginx-proxy",
                          snapshots: history(days: 7, weeks: 3, notes: "nginx-proxy", sizeGiB: 0.9)),
                    Group(namespace: "homelab", type: "ct", id: "202", owner: "backup@pbs", notes: "jellyfin",
                          snapshots: history(days: 7, weeks: 3, notes: "jellyfin", sizeGiB: 6)),
                    Group(namespace: "laptops", type: "host", id: "anna-macbook", owner: "anna@pbs", notes: "Home folder",
                          snapshots: history(days: 4, weeks: 4, notes: "", sizeGiB: 180)),
                    Group(namespace: "", type: "host", id: "pbs", owner: "root@pam", notes: "/etc of the backup server",
                          snapshots: history(days: 3, weeks: 0, notes: "", sizeGiB: 0.01)),
                ]
            ),
            Datastore(
                name: "offsite", path: "offsite", comment: "USB disk, swapped every Sunday", totalGiB: 1_863, usedGiB: 902,
                backingDevice: "8f1e2a64-3c5b-4b7e-9d0a-6e2f9b1c7a55", isMounted: false, gcSchedule: nil, namespaces: [""], groups: []
            ),
        ]
    )
}
