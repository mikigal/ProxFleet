import Foundation
import Observation
import PBSKit
import ProxmoxCore
import PVEKit

/// Everything the node screen shows: status, history, services, updates, journal and tasks.
///
/// Also serves a backup server, a single node the API calls `localhost`: most of its node API is the same, and the
/// differences (privileges on `/system`, disks, network lists, options) are handled here.
@MainActor
@Observable
public final class NodeDetail {
    public let node: String
    public let connection: ServerConnection

    public private(set) var status: NodeStatus?
    public private(set) var history: [RRDPoint] = []
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?
    public private(set) var hasLoaded = false
    /// nil until their screen loads them.
    public private(set) var services: [NodeService]?
    public private(set) var updates: [PackageVersion]?
    public private(set) var versions: [PackageVersion]?
    public private(set) var journal: [String]?
    public private(set) var tasks: [ClusterTask]?
    public private(set) var dns: NodeDNS?
    public private(set) var hosts: NodeHosts?
    public private(set) var time: NodeTime?
    public private(set) var network: NetworkConfiguration?
    public private(set) var disks: [NodeDisk]?
    public private(set) var volumeGroups: [LVMVolumeGroup]?
    public private(set) var thinPools: [LVMThinPool]?
    public private(set) var zfsPools: [ZFSPool]?
    public private(set) var directories: [DirectoryMount]?
    public private(set) var repositories: AptRepositories?
    public private(set) var subscription: NodeSubscription?
    public private(set) var certificates: [NodeCertificate]?
    public private(set) var options: NodeOptions?
    /// A backup server's options and the directories mounted for its datastores.
    public private(set) var backupServerOptions: BackupServerNodeOptions?
    private var backupServerOptionsDigest: String?
    public private(set) var backupServerDirectories: [BackupServerDirectory]?

    public var timeframe: RRDTimeframe = .hour {
        didSet {
            guard timeframe != oldValue else { return }
            Task { await loadHistory() }
        }
    }

    public init(node: String, connection: ServerConnection) {
        self.node = node
        self.connection = connection
    }

    public var summary: NodeSummary? {
        connection.snapshot?.nodes.first { $0.name == node }
    }

    public var isOnline: Bool { summary?.isOnline ?? (status != nil) }

    /// The node is listed as online, but its status cannot be read right now, e.g. while it reboots.
    public var isNotResponding: Bool { isOnline && loadError != nil }

    public var isBackupServer: Bool { connection.isBackupServer }

    /// Where the node's privileges are checked: `/nodes/{node}`, or `/system` on a backup server.
    public var privilegePath: String { isBackupServer ? "/system" : "/nodes/\(node)" }

    /// The privilege's name on this product: the backup server calls `Sys.PowerMgmt` `Sys.PowerManagement`.
    public func privilegeName(_ privilege: String) -> String {
        isBackupServer && privilege == "Sys.PowerMgmt" ? "Sys.PowerManagement" : privilege
    }

    /// Whether the user holds a privilege on `privilegePath`. Unknown privileges count as granted.
    public func can(_ privilege: String) -> Bool {
        privileges?.contains(privilegeName(privilege)) ?? true
    }

    // MARK: - Loading

    public func load() async {
        async let status: Void = loadStatus()
        async let history: Void = loadHistory()
        async let privileges = try? connection.session.privileges(on: privilegePath)
        _ = await (status, history)
        if let privileges = await privileges { self.privileges = privileges }
        hasLoaded = true
    }

    /// Keeps the status current while the screen is visible.
    public func keepRefreshing() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { break }
            tick += 1
            await loadStatus()
            if tick % 20 == 0 { await loadHistory() }
        }
    }

    private func loadStatus() async {
        do {
            status = try await connection.session.send(PVE.nodeStatus(node))
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadHistory() async {
        let request = isBackupServer ? PBS.nodeRRD(timeframe: timeframe) : PVE.nodeRRD(node, timeframe: timeframe)
        if let points = try? await connection.session.send(request) {
            history = points.filter(\.hasData)
        }
    }

    /// Loads a list for one of the screens. Returns an error message to show, or nil on success or cancellation.
    @discardableResult
    private func fetch<Value: Decodable & Sendable>(_ request: APIRequest<Value>, store: (Value) -> Void) async -> String? {
        do {
            store(try await connection.session.send(request))
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    public func loadServices() async -> String? {
        await fetch(PVE.services(node: node)) { services = $0 }
    }

    @discardableResult
    public func loadUpdates() async -> String? {
        let error = await fetch(PVE.packageUpdates(node: node)) { updates = $0 }
        // The installed versions are extra information; failing to load them is not worth a message.
        _ = await fetch(PVE.packageVersions(node: node)) { versions = $0 }
        return error
    }

    @discardableResult
    public func loadJournal(lastEntries: Int = 500) async -> String? {
        await fetch(PVE.journal(node: node, lastEntries: lastEntries)) { journal = NodeJournal.lines($0) }
    }

    @discardableResult
    public func loadTasks() async -> String? {
        await fetch(PVE.nodeTasks(node: node)) { tasks = $0 }
    }

    @discardableResult
    public func loadSystemSettings() async -> String? {
        let dns = await fetch(PVE.nodeDNS(node)) { self.dns = $0 }
        // A backup server does not edit /etc/hosts.
        let hosts = isBackupServer ? nil : await fetch(PVE.nodeHosts(node)) { self.hosts = $0 }
        let time = await fetch(PVE.nodeTime(node)) { self.time = $0 }
        return dns ?? hosts ?? time
    }

    @discardableResult
    public func loadOptions() async -> String? {
        if isBackupServer {
            return await fetch(PBS.nodeOptions()) {
                backupServerOptions = $0.value
                backupServerOptionsDigest = $0.digest
            }
        }
        return await fetch(PVE.nodeOptions(node)) { options = $0 }
    }

    @discardableResult
    public func loadNetwork() async -> String? {
        await fetch(PVE.network(node: node)) { network = $0 }
    }

    /// Loads the disks and what is built on them: LVM, thin pools, ZFS pools and directories.
    @discardableResult
    public func loadDisks() async -> String? {
        if isBackupServer {
            // No LVM screens on a backup server: its directories and ZFS pools hold datastores.
            let disks = await fetch(PBS.nodeDisks()) { self.disks = $0.flatMap(\.nodeDisks) }
            volumeGroups = []
            thinPools = []
            await fetch(PBS.zfsPools()) { zfsPools = $0 }
            await fetch(PBS.directories()) { found in
                backupServerDirectories = found
                directories = found.map(\.mount)
            }
            return disks
        }
        let disks = await fetch(PVE.disks(node: node)) { self.disks = $0 }
        await fetch(PVE.volumeGroups(node: node)) { volumeGroups = $0.groups }
        await fetch(PVE.thinPools(node: node)) { thinPools = $0 }
        await fetch(PVE.zfsPools(node: node)) { zfsPools = $0 }
        await fetch(PVE.directoryMounts(node: node)) { directories = $0 }
        return disks
    }

    @discardableResult
    public func loadRepositories() async -> String? {
        let error = await fetch(PVE.aptRepositories(node: node)) { repositories = $0 }
        await fetch(PVE.subscription(node: node)) { subscription = $0 }
        return error
    }

    @discardableResult
    public func loadCertificates() async -> String? {
        await fetch(PVE.certificates(node: node)) { certificates = $0 }
    }

    public func smart(of disk: String) async throws -> SMARTReport {
        try await connection.session.send(PVE.smart(node: node, disk: diskArgument(disk)))
    }

    /// The backup server takes disks by name (`sdb`), Proxmox VE by path.
    private func diskArgument(_ disk: String) -> String {
        isBackupServer ? PBS.diskName(disk) : disk
    }

    public func zfsStatus(of pool: String) async throws -> ZFSPoolStatus {
        try await connection.session.send(PVE.zfsPoolStatus(node: node, name: pool))
    }

    // MARK: - Actions

    /// Starts, stops or restarts a service, waits for its task and reloads the list.
    public func perform(_ action: ServiceAction, on service: NodeService) async throws(ConfigUpdateError) {
        try await runTask(PVE.serviceAction(node: node, service: service.name, action))
        await loadServices()
    }

    /// Refreshes the package index (`apt update`) as a task, then loads the updates.
    public func refreshPackageIndex() async throws(ConfigUpdateError) {
        try await runTask(PVE.refreshPackageIndex(node: node))
        await loadUpdates()
    }

    /// Reboots or shuts down the node. The connection to it ends shortly after.
    public func power(_ command: NodePowerCommand) async throws(ConfigUpdateError) {
        try await runTask(PVE.nodePower(node, command))
    }

    /// Starts a bulk action on the node's guests. The task center follows it and reports a failure.
    @discardableResult
    public func run(_ draft: NodeBulkActionDraft) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        do {
            return try connection.tasks.track(try await connection.session.send(PVE.bulkAction(node: node, draft, legacyWorkers: !connection.supports(.bulkActionParallelJobs))))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    // MARK: - System settings

    public func saveDNS(_ dns: NodeDNS) async throws(ConfigUpdateError) {
        try await perform(PVE.updateNodeDNS(node, dns))
        await fetch(PVE.nodeDNS(node)) { self.dns = $0 }
    }

    /// Replaces `/etc/hosts`, unless it changed since `hosts` was loaded. After a conflict the latest version is
    /// loaded, so saving again overwrites it, as in the web interface.
    public func saveHosts(_ text: String) async throws(ConfigUpdateError) {
        do {
            try await perform(PVE.updateNodeHosts(node, text: text, digest: hosts?.digest))
        } catch .conflict {
            await fetch(PVE.nodeHosts(node)) { hosts = $0 }
            throw .conflict
        }
        await fetch(PVE.nodeHosts(node)) { hosts = $0 }
    }

    public func setTimeZone(_ timeZone: String) async throws(ConfigUpdateError) {
        try await perform(PVE.setNodeTimeZone(node, timeZone))
        await fetch(PVE.nodeTime(node)) { time = $0 }
    }

    /// Changes notes or options, unless they changed since `options` was loaded. Needs `Sys.Modify` on `/`.
    public func saveOptions(_ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        var update = update
        update.digest = options?.digest
        do {
            try await perform(PVE.updateNodeOptions(node, update))
        } catch .conflict {
            await loadOptions()
            throw .conflict
        }
        await loadOptions()
    }

    /// Asks the node the app is connected to to wake this one with a magic packet. Returns the MAC address used.
    @discardableResult
    public func wakeOnLAN() async throws(ConfigUpdateError) -> String {
        do {
            return try await connection.session.send(PVE.wakeOnLAN(node))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    // MARK: - Network

    /// Adds an interface to the pending configuration. Nothing changes on the node until `applyNetwork`.
    public func createInterface(_ draft: NetworkInterfaceDraft) async throws(ConfigUpdateError) {
        try await perform(isBackupServer ? PBS.createInterface(draft) : PVE.createInterface(node: node, draft))
        await loadNetwork()
    }

    public func updateInterface(_ name: String, type: String, _ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        try await perform(isBackupServer ? PBS.updateInterface(name, update) : PVE.updateInterface(node: node, name: name, type: type, update))
        await loadNetwork()
    }

    public func deleteInterface(_ name: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteInterface(node: node, name: name))
        await loadNetwork()
    }

    /// Activates the pending network configuration and waits for its task.
    public func applyNetwork() async throws(ConfigUpdateError) {
        try await runTask(PVE.applyNetwork(node: node))
        await loadNetwork()
    }

    public func revertNetwork() async throws(ConfigUpdateError) {
        try await perform(PVE.revertNetwork(node: node))
        await loadNetwork()
    }

    // MARK: - Disks

    public func initializeGPT(_ disk: String) async throws(ConfigUpdateError) {
        try await runTask(PVE.initializeGPT(node: node, disk: diskArgument(disk)))
        await loadDisks()
    }

    public func wipe(_ disk: String) async throws(ConfigUpdateError) {
        try await runTask(PVE.wipeDisk(node: node, disk: diskArgument(disk)))
        await loadDisks()
    }

    /// Creates an LVM volume group, thin pool, ZFS pool or directory and waits for its task.
    /// On a backup server `addStorage` adds a datastore, and `removableDatastore` makes a directory's one removable.
    public func createDiskStorage(_ draft: DiskStorageDraft, removableDatastore: Bool = false) async throws(ConfigUpdateError) {
        if isBackupServer {
            try await runTask(PBS.createDiskStorage(draft, removable: removableDatastore))
            await connection.refresh()
        } else {
            try await runTask(PVE.createDiskStorage(node: node, draft))
        }
        await loadDisks()
    }

    /// On a backup server only directories can be removed: the mount goes, the data and any datastore stay.
    public func deleteDiskStorage(_ kind: DiskStorageKind, name: String, volumeGroup: String? = nil, cleanupConfig: Bool, wipeDisks: Bool) async throws(ConfigUpdateError) {
        if isBackupServer {
            try await runTask(PBS.deleteDirectory(name))
        } else {
            try await runTask(PVE.deleteDiskStorage(node: node, kind: kind, name: name, volumeGroup: volumeGroup, cleanupConfig: cleanupConfig, wipeDisks: wipeDisks))
        }
        await loadDisks()
    }

    // MARK: - Repositories and certificates

    public func setRepository(_ repository: AptRepositories.Repository, enabled: Bool) async throws(ConfigUpdateError) {
        try await perform(PVE.setRepository(node: node, repository, enabled: enabled, digest: repositories?.digest))
        await loadRepositories()
    }

    public func addStandardRepository(_ handle: String) async throws(ConfigUpdateError) {
        try await perform(PVE.addStandardRepository(node: node, handle: handle, digest: repositories?.digest))
        await loadRepositories()
    }

    /// Uploads a custom certificate. pveproxy restarts with it, so its fingerprint is trusted first: the
    /// server reported it over the connection that is already trusted.
    public func uploadCertificate(_ draft: CustomCertificateDraft) async throws(ConfigUpdateError) {
        let certificate: NodeCertificate?
        do {
            certificate = isBackupServer
                ? try await connection.session.send(PBS.uploadCertificate(draft)).first { $0.fileName == "proxy.pem" }
                : try await connection.session.send(PVE.uploadCertificate(node: node, draft))
        } catch {
            throw ConfigUpdateError(error)
        }
        if let fingerprint = certificate?.fingerprint { connection.trustFingerprint(fingerprint) }
        await reloadCertificatesAfterRestart()
    }

    /// Removes the custom certificate; pveproxy goes back to `pve-ssl.pem`, whose fingerprint is trusted first.
    ///
    /// A backup server makes a new self-signed certificate instead, whose fingerprint is not known beforehand: the
    /// app asks to trust it on the next connection.
    public func deleteCustomCertificate() async throws(ConfigUpdateError) {
        if isBackupServer {
            try await perform(PBS.deleteCustomCertificate())
            await reloadCertificatesAfterRestart()
            return
        }
        if let fingerprint = certificates?.first(where: { $0.fileName == "pve-ssl.pem" })?.fingerprint {
            connection.trustFingerprint(fingerprint)
        }
        try await perform(PVE.deleteCustomCertificate(node: node))
        await reloadCertificatesAfterRestart()
    }

    /// Saves a backup server's options, refused when they changed since they were loaded.
    public func saveBackupServerOptions(_ update: BackupServerConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        var update = update
        if update.digest == nil { update.digest = backupServerOptionsDigest }
        do {
            try await perform(PBS.updateNodeOptions(update))
        } catch .conflict {
            await loadOptions()
            throw .conflict
        }
        await loadOptions()
    }

    /// pveproxy needs a moment to restart; requests fail until then.
    private func reloadCertificatesAfterRestart() async {
        for attempt in 0..<10 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            if await loadCertificates() == nil { return }
        }
    }

    private func perform<Value>(_ request: APIRequest<Value>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    private func runTask(_ request: APIRequest<String?>) async throws(ConfigUpdateError) {
        do {
            guard let upid = try await connection.session.send(request) else { return }
            let task = try connection.tasks.track(upid, reportsFailure: false)
            if case .failed(let message) = await connection.tasks.result(of: task.id) {
                throw ProxmoxError.api(status: 500, message: message, fieldErrors: [:])
            }
        } catch {
            throw ConfigUpdateError(error)
        }
    }
}
