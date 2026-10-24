import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// Ceph as one node sees it: whether it is set up, the cluster's health, services, OSDs, pools and file systems.
@MainActor
@Observable
public final class CephManager {
    public let connection: ServerConnection
    /// The node the requests go to; Ceph's state is the same from every node.
    public let node: String

    public private(set) var setupState: CephSetupState?
    public private(set) var status: CephStatus?
    public private(set) var services: [CephService.Kind: [CephService]] = [:]
    public private(set) var osdTree: CephOSDTree?
    public private(set) var pools: [CephPool]?
    public private(set) var fileSystems: [CephFileSystem]?
    public private(set) var flags: [CephFlag]?
    public private(set) var rules: [String] = []
    public private(set) var loadError: String?

    public init(connection: ServerConnection, node: String) {
        self.connection = connection
        self.node = node
    }

    public func load() async {
        let session = connection.session
        do {
            status = try await session.send(PVE.cephStatus(node: node))
            setupState = .ready
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            let message = error.localizedDescription
            if let state = CephSetupState.from(errorMessage: message) {
                setupState = state
                status = nil
                loadError = nil
            } else {
                loadError = message
            }
            return
        }
        async let monitors = try? session.send(PVE.cephServices(.monitor, node: node))
        async let managers = try? session.send(PVE.cephServices(.manager, node: node))
        async let metadataServers = try? session.send(PVE.cephServices(.metadataServer, node: node))
        async let osdTree = try? session.send(PVE.cephOSDs(node: node))
        async let pools = try? session.send(PVE.cephPoolList(node: node))
        async let fileSystems = try? session.send(PVE.cephFileSystems(node: node))
        async let flags = try? session.send(PVE.cephFlags())
        async let rules = try? session.send(PVE.cephRules(node: node))
        services = [
            .monitor: (await monitors ?? []).sorted { $0.name < $1.name },
            .manager: (await managers ?? []).sorted { $0.name < $1.name },
            .metadataServer: (await metadataServers ?? []).sorted { $0.name < $1.name },
        ]
        if let tree = await osdTree { self.osdTree = tree }
        if let list = await pools { self.pools = list.sorted { $0.name < $1.name } }
        if let list = await fileSystems { self.fileSystems = list }
        if let list = await flags { self.flags = list }
        if let list = await rules { self.rules = list.compactMap { $0["name"] }.sorted() }
    }

    /// Reloads every few seconds while visible: Ceph recovers and rebalances in the background.
    public func keepRefreshing() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { break }
            await load()
        }
    }

    // MARK: - Setup

    public func releases() async -> [CephRelease] {
        guard let releases = try? await connection.session.send(PVE.cephReleases(node: node)) else {
            // Older servers have no list; their web interface offers a fixed one.
            return CephRelease.fallback(for: connection.version?.number)
        }
        return releases.filter(\.isAvailable)
    }

    /// The networks of the node's interfaces, like `10.0.0.0/24`, for Ceph's public and cluster network.
    public func networks() async -> [String] {
        guard let configuration = try? await connection.session.send(PVE.network(node: node)) else { return [] }
        var seen: Set<String> = []
        return configuration.interfaces.compactMap { $0.cidr.flatMap(Self.network(of:)) }.filter { seen.insert($0).inserted }.sorted()
    }

    /// `10.0.0.5/24` → `10.0.0.0/24`. IPv4 only; nil for anything else.
    static func network(of cidr: String) -> String? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 < 256 }) else { return nil }
        let address = octets.reduce(0) { $0 << 8 | $1 }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        let network = address & mask
        return "\(network >> 24).\(network >> 16 & 255).\(network >> 8 & 255).\(network & 255)/\(prefix)"
    }

    /// Creates the configuration and the first monitor (with a manager) on this node, as the web interface's
    /// setup wizard does.
    public func initialize(network: String, clusterNetwork: String?, size: Int?, minSize: Int?) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(PVE.initializeCeph(node: node, network: network, clusterNetwork: clusterNetwork, size: size, minSize: minSize))
        } catch {
            throw ConfigUpdateError(error)
        }
        try await runTask(PVE.createCephService(.monitor, node: node))
    }

    // MARK: - Services

    public func create(_ kind: CephService.Kind, on host: String, id: String? = nil, hotStandby: Bool = false) async throws(ConfigUpdateError) {
        try await runTask(PVE.createCephService(kind, node: host, id: id, hotStandby: hotStandby))
    }

    public func destroy(_ kind: CephService.Kind, _ service: CephService) async throws(ConfigUpdateError) {
        try await runTask(PVE.destroyCephService(kind, node: service.host, id: service.name))
    }

    /// Starts, stops or restarts a daemon like `mon.pve1` on its host.
    public func perform(_ action: String, service: String, host: String) async throws(ConfigUpdateError) {
        try await runTask(PVE.cephServiceAction(action, node: host, service: service))
    }

    /// Whether stopping or destroying would take placement groups offline; nil when Proxmox cannot tell.
    public func safety(of service: String, id: String, action: String, host: String) async -> CephSafetyCheck? {
        try? await connection.session.send(PVE.cephSafety(node: host, service: service, id: id, action: action))
    }

    // MARK: - OSDs

    public func createOSD(on host: String, _ draft: CephOSDDraft) async throws(ConfigUpdateError) {
        try await runTask(PVE.createCephOSD(node: host, draft))
    }

    public func destroy(_ osd: CephOSD, cleanup: Bool) async throws(ConfigUpdateError) {
        try await runTask(PVE.destroyCephOSD(node: osd.host, id: osd.id, cleanup: cleanup))
    }

    public func set(_ osd: CephOSD, in isIn: Bool) async throws(ConfigUpdateError) {
        try await perform(PVE.setCephOSD(node: osd.host, id: osd.id, in: isIn))
    }

    public func scrub(_ osd: CephOSD, deep: Bool) async throws(ConfigUpdateError) {
        try await perform(PVE.scrubCephOSD(node: osd.host, id: osd.id, deep: deep))
    }

    public func setFlags(_ changes: [String: Bool]) async throws(ConfigUpdateError) {
        guard !changes.isEmpty else { return }
        try await runTask(PVE.setCephFlags(changes))
    }

    /// Disks of a node that can hold an OSD or its DB/WAL: unused, not partitions.
    public func unusedDisks(on host: String) async -> [NodeDisk] {
        ((try? await connection.session.send(PVE.disks(node: host, includePartitions: false))) ?? []).filter { $0.isUnused && $0.parent == nil }
    }

    // MARK: - Pools and file systems

    public func createPool(_ draft: CephPoolDraft) async throws(ConfigUpdateError) {
        try await runTask(PVE.createCephPool(node: node, draft))
        // Storage entries for the pool show in the datacenter.
        if draft.addStorage { await connection.refresh() }
    }

    public func updatePool(_ name: String, _ parameters: APIParameters) async throws(ConfigUpdateError) {
        guard !parameters.items.isEmpty else { return }
        do {
            let upid = try await connection.session.send(PVE.updateCephPool(node: node, name: name, parameters))
            try await waitFor(upid)
        } catch let error as ConfigUpdateError {
            throw error
        } catch {
            throw ConfigUpdateError(error)
        }
        await load()
    }

    public func destroyPool(_ name: String, removeStorages: Bool) async throws(ConfigUpdateError) {
        try await runTask(PVE.destroyCephPool(node: node, name: name, removeStorages: removeStorages))
        if removeStorages { await connection.refresh() }
    }

    public func createFileSystem(name: String, placementGroups: Int, addStorage: Bool) async throws(ConfigUpdateError) {
        try await runTask(PVE.createCephFileSystem(node: node, name: name, placementGroups: placementGroups, addStorage: addStorage))
        if addStorage { await connection.refresh() }
    }

    // MARK: - Configuration and log

    public func configFile() async throws -> String {
        try await connection.session.send(PVE.cephConfigFile(node: node))
    }

    public func configDatabase() async throws -> [CephConfigEntry] {
        try await connection.session.send(PVE.cephConfigDatabase(node: node))
    }

    public func crushMap() async throws -> String {
        try await connection.session.send(PVE.cephCrushMap(node: node))
    }

    public func log() async throws -> [TaskLogLine] {
        try await connection.session.send(PVE.cephLog(node: node))
    }

    // MARK: - Helpers

    private func perform(_ request: APIRequest<Nothing>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
        await load()
    }

    /// Sends a request that starts a task, waits for the task and reloads; a failed task throws its message.
    private func runTask(_ request: APIRequest<String>) async throws(ConfigUpdateError) {
        do {
            try await waitFor(try await connection.session.send(request))
        } catch let error as ConfigUpdateError {
            await load()
            throw error
        } catch {
            await load()
            throw ConfigUpdateError(error)
        }
        await load()
    }

    private func waitFor(_ upid: String?) async throws {
        guard let upid, !upid.isEmpty else { return }
        let task = try connection.tasks.track(upid, reportsFailure: false)
        if case .failed(let message) = await connection.tasks.result(of: task.id) {
            throw ConfigUpdateError.failed(message)
        }
    }
}
