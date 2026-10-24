import Foundation
import ProxmoxCore

/// `GET .../migrate`: what stands in the way of moving a guest to another node of the cluster.
/// VMs and containers answer with different key spellings and containers report HA rules only.
public struct MigrationPreconditions: Decodable, Sendable, Equatable {
    /// A disk on storage that the other nodes cannot reach, so it is copied, or a local ISO, which blocks migration.
    public struct LocalDisk: Decodable, Sendable, Equatable {
        public var volumeID: String
        public var size: Int64?
        public var isCDROM: Bool
        public var isCloudInit: Bool

        public init(volumeID: String, size: Int64? = nil, isCDROM: Bool = false, isCloudInit: Bool = false) {
            self.volumeID = volumeID
            self.size = size
            self.isCDROM = isCDROM
            self.isCloudInit = isCloudInit
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            volumeID = container.lossyString(AnyCodingKey("volid")) ?? ""
            size = container.lossyInt(AnyCodingKey("size")).map(Int64.init)
            isCDROM = container.lossyBool(AnyCodingKey("cdrom")) ?? false
            isCloudInit = container.lossyBool(AnyCodingKey("is_cloudinit")) ?? false
        }
    }

    /// An HA resource that keeps the guest off a node because of an affinity rule.
    public struct BlockingHAResource: Decodable, Sendable, Equatable {
        public var sid: String
        /// `node-affinity` or `resource-affinity`.
        public var cause: String

        public init(sid: String, cause: String) {
            self.sid = sid
            self.cause = cause
        }
    }

    /// Why a node cannot take the guest.
    public struct NodeRestriction: Decodable, Sendable, Equatable {
        /// Storages of the guest's disks that the node lacks; only for offline VM migration.
        public var unavailableStorages: [String]
        /// Mapped devices without a mapping on the node.
        public var unavailableResources: [String]
        public var blockingHAResources: [BlockingHAResource]

        public init(unavailableStorages: [String] = [], unavailableResources: [String] = [], blockingHAResources: [BlockingHAResource] = []) {
            self.unavailableStorages = unavailableStorages
            self.unavailableResources = unavailableResources
            self.blockingHAResources = blockingHAResources
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            unavailableStorages = (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("unavailable_storages"))) ?? []
            unavailableResources = (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("unavailable-resources"))) ?? []
            blockingHAResources = (try? container.decodeIfPresent([BlockingHAResource].self, forKey: AnyCodingKey("blocking-ha-resources"))) ?? []
        }
    }

    public var isRunning: Bool
    /// Nodes that have every storage of the guest; nil when the server does not say.
    public var allowedNodes: [String]?
    public var restrictions: [String: NodeRestriction]
    public var localDisks: [LocalDisk]
    /// Host devices (PCI, USB, serial) that only exist on this node.
    public var localResources: [String]
    /// Mapped devices by name, with whether they support live migration.
    public var mappedResources: [String: Bool]
    /// The source node can carry the VM's conntrack entries along.
    public var supportsConntrackState: Bool
    /// HA resources that move along because of a positive affinity rule.
    public var dependentHAResources: [String]

    public init(
        isRunning: Bool, allowedNodes: [String]? = nil, restrictions: [String: NodeRestriction] = [:], localDisks: [LocalDisk] = [],
        localResources: [String] = [], mappedResources: [String: Bool] = [:], supportsConntrackState: Bool = false, dependentHAResources: [String] = []
    ) {
        self.isRunning = isRunning
        self.allowedNodes = allowedNodes
        self.restrictions = restrictions
        self.localDisks = localDisks
        self.localResources = localResources
        self.mappedResources = mappedResources
        self.supportsConntrackState = supportsConntrackState
        self.dependentHAResources = dependentHAResources
    }

    private struct MappedResource: Decodable {
        var liveMigration: Bool

        init(from decoder: any Decoder) throws {
            liveMigration = (try decoder.container(keyedBy: AnyCodingKey.self)).lossyBool(AnyCodingKey("live-migration")) ?? false
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func strings(_ keys: String...) -> [String]? {
            keys.lazy.compactMap { try? container.decodeIfPresent([String].self, forKey: AnyCodingKey($0)) }.first
        }
        isRunning = container.lossyBool(AnyCodingKey("running")) ?? false
        allowedNodes = strings("allowed_nodes", "allowed-nodes")
        restrictions = ["not_allowed_nodes", "not-allowed-nodes"].lazy
            .compactMap { try? container.decodeIfPresent([String: NodeRestriction].self, forKey: AnyCodingKey($0)) }.first ?? [:]
        localDisks = (try? container.decodeIfPresent([LocalDisk].self, forKey: AnyCodingKey("local_disks"))) ?? []
        localResources = strings("local_resources") ?? []
        mappedResources = ((try? container.decodeIfPresent([String: MappedResource].self, forKey: AnyCodingKey("mapped-resource-info"))) ?? [:])
            .mapValues(\.liveMigration)
        supportsConntrackState = container.lossyBool(AnyCodingKey("has-dbus-vmstate")) ?? false
        dependentHAResources = strings("dependent-ha-resources") ?? []
    }
}

/// `GET /nodes/{node}/capabilities/qemu/migration`.
public struct QEMUMigrationCapabilities: Decodable, Sendable, Equatable {
    /// The node can receive a VM's conntrack entries.
    public var supportsConntrackState: Bool

    public init(supportsConntrackState: Bool) {
        self.supportsConntrackState = supportsConntrackState
    }

    public init(from decoder: any Decoder) throws {
        supportsConntrackState = (try decoder.container(keyedBy: AnyCodingKey.self)).lossyBool(AnyCodingKey("has-dbus-vmstate")) ?? false
    }
}

/// A line under the web interface's Migrate dialog: why the migration cannot start, or what to expect.
public struct MigrationNote: Sendable, Equatable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        case error, warning, info

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var severity: Severity
    public var text: String

    public var id: String { text }

    public init(_ severity: Severity, _ text: String) {
        self.severity = severity
        self.text = text
    }
}

/// How a guest moves: running VMs live, running containers by restarting on the target, stopped guests offline.
public enum MigrationMode: Sendable, Equatable {
    case online, restart, offline
}

/// Settings of the web interface's Migrate dialog for one guest.
public struct MigrationDraft: Sendable, Equatable {
    public let guest: GuestReference
    public var target: String
    /// Running VMs with local disks: the storage on the target for all of them, empty to keep each on a storage of
    /// the same name.
    public var targetStorage = ""
    /// Stopped VMs with host devices: migrate anyway. Only root@pam may.
    public var force = false
    /// Running VMs, when both nodes support it: carry the conntrack entries, so connections survive.
    public var withConntrackState = true
    /// nil until loaded for the chosen target.
    public var preconditions: MigrationPreconditions?
    public var targetSupportsConntrackState = false
    /// False before PVE 9, which cannot migrate the conntrack state at all.
    public var offersConntrackState = true

    public init(guest: GuestReference, target: String = "") {
        self.guest = guest
        self.target = target
    }

    private var isVM: Bool { guest.kind == .virtualMachine }

    public var mode: MigrationMode {
        guard preconditions?.isRunning == true else { return .offline }
        return isVM ? .online : .restart
    }

    /// Disks that are copied to the target, which takes a while.
    public var copiedDisks: [MigrationPreconditions.LocalDisk] {
        isVM ? (preconditions?.localDisks ?? []).filter { !$0.isCDROM } : []
    }

    /// Host devices without a mapping, which only exist on this node.
    public var blockingLocalResources: [String] {
        guard let preconditions else { return [] }
        return preconditions.localResources.filter { preconditions.mappedResources[$0] == nil }
    }

    public var showsTargetStorage: Bool { mode == .online && !copiedDisks.isEmpty }
    public var showsForce: Bool { isVM && mode == .offline && !blockingLocalResources.isEmpty }
    public var showsConntrackState: Bool { offersConntrackState && mode == .online && isVM && bothSupportConntrackState }

    private var bothSupportConntrackState: Bool { (preconditions?.supportsConntrackState ?? false) && targetSupportsConntrackState }

    /// The same notes as the web interface, errors first.
    public var notes: [MigrationNote] {
        guard let preconditions, !target.isEmpty else { return [] }
        var notes: [MigrationNote] = []
        let restriction = preconditions.restrictions[target] ?? .init()
        let kind = isVM ? String(localized: "VM") : String(localized: "container")

        if isVM {
            if mode == .offline, let allowed = preconditions.allowedNodes, !allowed.contains(target), !restriction.unavailableStorages.isEmpty {
                notes.append(.init(.error, String(localized: "Storage (\(restriction.unavailableStorages.joined(separator: ", "))) not available on the target. Start the VM to migrate its storage live, or choose another node.")))
            }
            if !restriction.unavailableResources.isEmpty {
                notes.append(.init(.error, String(localized: "Mapped devices (\(restriction.unavailableResources.joined(separator: ", "))) not available on the target.")))
            }
            let blocking = blockingLocalResources
            if !blocking.isEmpty {
                if force, mode == .offline {
                    notes.append(.init(.warning, String(localized: "Migrating with host devices: \(blocking.joined(separator: ", ")). This might fail if they are not available on the target.")))
                } else {
                    notes.append(.init(.error, String(localized: "Cannot migrate a VM with host devices: \(blocking.joined(separator: ", ")).")))
                }
            }
            if mode == .online {
                let mapped = preconditions.mappedResources.sorted { $0.key < $1.key }
                let notLive = mapped.filter { !$0.value }.map(\.key)
                if !notLive.isEmpty {
                    notes.append(.init(.error, String(localized: "Cannot migrate a running VM with mapped devices: \(notLive.joined(separator: ", ")).")))
                } else if !mapped.isEmpty {
                    notes.append(.init(.warning, String(localized: "Live-migrating a running VM with mapped devices (experimental): \(mapped.map(\.key).joined(separator: ", ")).")))
                }
            }
            for disk in preconditions.localDisks where disk.isCDROM && !disk.isCloudInit && !disk.volumeID.contains("vm-\(guest.vmid)-cloudinit") {
                notes.append(.init(.error, String(localized: "Cannot migrate a VM with a local CD/DVD (\(disk.volumeID)). Eject it first.")))
            }
            for disk in copiedDisks {
                let size = disk.size.map { " (\($0.formatted(.byteCount(style: .memory))))" } ?? ""
                notes.append(.init(.warning, String(localized: "Migration with local disk might take long: \(disk.volumeID)\(size)")))
            }
            if mode == .online, offersConntrackState {
                if !preconditions.supportsConntrackState {
                    notes.append(.init(.info, String(localized: "Cannot migrate the conntrack state, the source node lacks support.")))
                } else if !targetSupportsConntrackState {
                    notes.append(.init(.warning, String(localized: "Cannot migrate the conntrack state, the target node lacks support. Active network connections might get dropped.")))
                } else if !withConntrackState {
                    notes.append(.init(.warning, String(localized: "Conntrack state migration disabled. Active network connections might get dropped.")))
                }
            }
        }
        for blocking in restriction.blockingHAResources {
            let reason = switch blocking.cause {
            case "resource-affinity": String(localized: "HA resource \(blocking.sid) has a negative affinity to the \(kind) on the target node")
            case "node-affinity": String(localized: "HA resource \(blocking.sid) is not allowed on the target node")
            default: String(localized: "HA resource \(blocking.sid) blocks the target node")
            }
            notes.append(.init(.error, String(localized: "Cannot migrate: \(reason).")))
        }
        for sid in preconditions.dependentHAResources {
            notes.append(.init(.warning, String(localized: "HA resource \(sid) has a positive affinity to the \(kind) and migrates to the target node too.")))
        }
        return notes.enumerated().sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }.map(\.element)
    }

    public var canMigrate: Bool {
        preconditions != nil && !target.isEmpty && target != guest.node && !notes.contains { $0.severity == .error }
    }

    public var parameters: APIParameters {
        var parameters: APIParameters = ["target": .string(target)]
        switch mode {
        case .online: parameters["online"] = true
        case .restart: parameters["restart"] = true
        case .offline: break
        }
        if !copiedDisks.isEmpty {
            parameters["with-local-disks"] = true
            // Like the web interface: a storage change on offline migration can fail half way, so it is not offered.
            if mode == .online, !targetStorage.isEmpty { parameters["targetstorage"] = .string(targetStorage) }
        }
        if force, showsForce { parameters["force"] = true }
        if showsConntrackState, withConntrackState { parameters["with-conntrack-state"] = true }
        return parameters
    }
}

extension PVE {
    /// Preconditions for migrating a guest to the target node.
    public static func migrationPreconditions(_ guest: GuestReference, target: String?) -> APIRequest<MigrationPreconditions> {
        APIRequest(.get, guest.path + "/migrate", parameters: target.map { ["target": .string($0)] } ?? [:])
    }

    public static func qemuMigrationCapabilities(node: String) -> APIRequest<QEMUMigrationCapabilities> {
        APIRequest(.get, "/nodes/\(node)/capabilities/qemu/migration")
    }

    /// Moves a guest to another node. Returns the task ID; the task runs on the source node.
    public static func migrate(_ draft: MigrationDraft) -> APIRequest<String> {
        APIRequest(.post, draft.guest.path + "/migrate", parameters: draft.parameters)
    }
}
