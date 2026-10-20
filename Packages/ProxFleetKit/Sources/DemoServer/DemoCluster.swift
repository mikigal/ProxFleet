import Foundation

/// State of the fake Proxmox VE installation served in demo mode.
public struct DemoCluster: Sendable {
    public struct Node: Sendable {
        public var name: String
        public var ip: String
        public var isOnline: Bool
        public var cores: Int
        public var memoryGiB: Int
    }

    public struct Guest: Sendable {
        public enum Kind: String, Sendable { case qemu, lxc }

        public var vmid: Int
        public var kind: Kind
        public var name: String
        public var node: String
        public var isRunning: Bool
        public var cores: Int
        public var memoryGiB: Double
        public var diskGiB: Int
        public var tags: [String]
        public var isTemplate: Bool
        public var isPaused = false
        /// When the guest was last started in demo mode; nil means "running for a while already".
        public var bootedAt: Date?

        public init(_ vmid: Int, _ kind: Kind, _ name: String, on node: String, running: Bool = true, cores: Int = 2, memoryGiB: Double = 2, diskGiB: Int = 32, tags: [String] = [], template: Bool = false) {
            self.vmid = vmid
            self.kind = kind
            self.name = name
            self.node = node
            self.isRunning = running && !template
            self.cores = cores
            self.memoryGiB = memoryGiB
            self.diskGiB = diskGiB
            self.tags = tags
            self.isTemplate = template
        }
    }

    /// nil for a standalone node.
    public var clusterName: String?
    public var nodes: [Node]
    public var guests: [Guest]
    public var version = "9.0.10"

    /// A three-node home lab cluster with one node offline.
    public static let homelab = DemoCluster(
        clusterName: "homelab",
        nodes: [
            Node(name: "pve1", ip: "10.0.10.11", isOnline: true, cores: 16, memoryGiB: 64),
            Node(name: "pve2", ip: "10.0.10.12", isOnline: true, cores: 12, memoryGiB: 32),
            Node(name: "pve3", ip: "10.0.10.13", isOnline: false, cores: 8, memoryGiB: 32),
        ],
        guests: [
            Guest(100, .qemu, "home-assistant", on: "pve1", cores: 2, memoryGiB: 4, tags: ["smart-home"]),
            Guest(101, .qemu, "truenas", on: "pve1", cores: 4, memoryGiB: 16, diskGiB: 64, tags: ["storage", "prod"]),
            Guest(102, .qemu, "win11-desktop", on: "pve2", running: false, cores: 6, memoryGiB: 12, diskGiB: 128),
            Guest(103, .qemu, "ubuntu-dev", on: "pve2", cores: 4, memoryGiB: 8, diskGiB: 64, tags: ["dev"]),
            Guest(104, .qemu, "docker-host", on: "pve1", cores: 4, memoryGiB: 8, diskGiB: 100, tags: ["prod"]),
            Guest(105, .qemu, "k3s-worker", on: "pve3", running: false, cores: 4, memoryGiB: 8),
            Guest(200, .lxc, "pihole", on: "pve1", cores: 1, memoryGiB: 0.5, diskGiB: 8, tags: ["network", "prod"]),
            Guest(201, .lxc, "nginx-proxy", on: "pve2", cores: 1, memoryGiB: 1, diskGiB: 8, tags: ["network"]),
            Guest(202, .lxc, "jellyfin", on: "pve1", cores: 4, memoryGiB: 4, diskGiB: 16, tags: ["media"]),
            Guest(203, .lxc, "nextcloud", on: "pve2", running: false, cores: 2, memoryGiB: 2, diskGiB: 32),
            Guest(9000, .qemu, "debian-13-template", on: "pve1", cores: 2, memoryGiB: 2, diskGiB: 16, template: true),
        ]
    )

    /// A single node with a few guests.
    public static let standalone = DemoCluster(
        clusterName: nil,
        nodes: [Node(name: "pve", ip: "192.168.1.20", isOnline: true, cores: 8, memoryGiB: 32)],
        guests: [
            Guest(100, .qemu, "opnsense", on: "pve", cores: 2, memoryGiB: 4),
            Guest(101, .qemu, "debian", on: "pve", running: false),
            Guest(200, .lxc, "adguard", on: "pve", cores: 1, memoryGiB: 0.5, diskGiB: 4),
        ]
    )
}
