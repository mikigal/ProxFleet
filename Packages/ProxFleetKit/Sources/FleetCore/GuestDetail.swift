import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// Everything the detail screen of one VM or container shows, and its power actions.
@MainActor
@Observable
public final class GuestDetail {
    public let reference: GuestReference
    public let connection: ServerConnection

    public private(set) var status: GuestStatus?
    public private(set) var config: GuestConfig?
    /// Changes that wait for the next restart.
    public private(set) var pendingChanges: [PendingConfigItem] = []
    public private(set) var history: [RRDPoint] = []
    /// nil while unknown, empty when the guest reports no addresses.
    public private(set) var interfaces: [GuestNetworkInterface]?
    public private(set) var privileges: Set<String>?
    public private(set) var recentTasks: [ClusterTask] = []
    /// nil until the snapshot screen loads them; includes `current`.
    public private(set) var snapshots: [GuestSnapshot]?
    public private(set) var loadError: String?
    public private(set) var actionError: String?
    public private(set) var hasLoaded = false

    public var timeframe: RRDTimeframe = .hour {
        didSet {
            guard timeframe != oldValue else { return }
            Task { await loadHistory() }
        }
    }

    public init(reference: GuestReference, connection: ServerConnection) {
        self.reference = reference
        self.connection = connection
    }

    // MARK: - Derived state

    public var summary: GuestSummary? {
        connection.snapshot?.guests.first { $0.vmid == reference.vmid }
    }

    public var name: String {
        status?.name ?? config?.name ?? summary?.name ?? "\(reference.vmid)"
    }

    public var powerState: PowerState {
        status?.powerState ?? summary?.state ?? .unknown
    }

    public var isTemplate: Bool {
        config?["template"] == "1" || summary?.isTemplate == true
    }

    /// Hidden when the user lacks `VM.PowerMgmt`, like in the web interface.
    public var availableActions: [PowerAction] {
        guard privileges?.contains("VM.PowerMgmt") ?? true else { return [] }
        return PowerAction.available(for: reference.kind, state: powerState, isTemplate: isTemplate)
    }

    public var runningTask: TaskCenter.TrackedTask? {
        connection.tasks.runningTask(forGuest: reference.vmid)
    }

    // MARK: - Loading

    /// Loads everything in parallel. Only a failing status request is treated as an error.
    public func load() async {
        async let status: Void = loadStatus()
        async let config: Void = loadConfig()
        async let history: Void = loadHistory()
        async let extras: Void = loadExtras()
        _ = await (status, config, history, extras)
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
            if tick % 20 == 0 {
                await loadHistory()
                await loadExtras()
            }
        }
    }

    public func refresh() async {
        await load()
        await connection.refresh()
    }

    private func loadStatus() async {
        do {
            status = try await connection.session.send(PVE.guestStatus(reference))
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadConfig() async {
        async let config = try? connection.session.send(PVE.guestConfig(reference))
        async let pending = try? connection.session.send(PVE.pendingConfig(reference))
        if let config = await config { self.config = config }
        if let pending = await pending { pendingChanges = pending.filter(\.hasPendingChange) }
    }

    // MARK: - Editing

    /// Whether the user holds a privilege on this guest. Unknown privileges count as granted.
    public func can(_ privilege: String) -> Bool {
        privileges?.contains(privilege) ?? true
    }

    public func pendingChange(for key: String) -> PendingConfigItem? {
        pendingChanges.first { $0.key == key }
    }

    /// Applies a configuration change based on the loaded configuration, waits for its task and reloads.
    public func apply(_ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        var update = update
        if update.digest == nil { update.digest = config?.digest }
        do {
            let upid = try await connection.session.send(PVE.updateConfig(reference, update))
            try await waitForTask(upid)
        } catch {
            await loadConfig()
            throw ConfigUpdateError(error)
        }
        await loadConfig()
        await loadStatus()
    }

    /// Grows a disk by a number of GiB.
    public func growDisk(_ key: String, byGiB amount: Int) async throws(ConfigUpdateError) {
        try await run(PVE.resizeDisk(reference, disk: key, size: "+\(amount)G"))
    }

    /// Runs a request that starts a task on this guest, such as moving a disk, waits for it and reloads.
    public func run(_ request: APIRequest<String?>) async throws(ConfigUpdateError) {
        do {
            let upid = try await connection.session.send(request)
            try await waitForTask(upid)
        } catch {
            await loadConfig()
            throw ConfigUpdateError(error)
        }
        await loadConfig()
    }

    // MARK: - Snapshots, templates and deletion

    /// Loads the snapshots. Errors keep the previous list and are returned for the snapshot screen to show.
    @discardableResult
    public func loadSnapshots() async -> String? {
        do {
            snapshots = try await connection.session.send(PVE.snapshots(reference))
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Runs a snapshot request (take, roll back, delete), waits for its task and reloads.
    public func runSnapshotAction(_ request: APIRequest<String?>) async throws(ConfigUpdateError) {
        do {
            try await run(request)
        } catch {
            await loadSnapshots()
            throw error
        }
        await loadSnapshots()
        await loadStatus()
    }

    /// Turns the stopped guest into a template. Containers convert in the background without a task ID,
    /// so their configuration is checked until it shows the change.
    public func convertToTemplate() async throws(ConfigUpdateError) {
        try await run(PVE.convertToTemplate(reference))
        for _ in 0..<40 where !isTemplate {
            try? await Task.sleep(for: .milliseconds(500))
            await loadConfig()
        }
        await connection.refresh()
    }

    /// Deletes the stopped guest and waits until it is gone.
    public func destroy(purge: Bool, destroyUnreferencedDisks: Bool) async throws(ConfigUpdateError) {
        do {
            let upid = try await connection.session.send(PVE.destroy(reference, purge: purge, destroyUnreferencedDisks: destroyUnreferencedDisks))
            try await waitForTask(upid)
        } catch {
            throw ConfigUpdateError(error)
        }
        await connection.refresh()
    }

    /// Drops pending changes so the running configuration stays as it is.
    public func revertPendingChanges() async throws(ConfigUpdateError) {
        var update = GuestConfigUpdate()
        update.reverts = Set(pendingChanges.map(\.key))
        guard !update.reverts.isEmpty else { return }
        try await apply(update)
    }

    private func waitForTask(_ upid: String?) async throws {
        guard let upid else { return }
        let task = try connection.tasks.track(upid, reportsFailure: false)
        if case .failed(let message) = await connection.tasks.result(of: task.id) {
            throw ProxmoxError.api(status: 500, message: message, fieldErrors: [:])
        }
    }


    private func loadHistory() async {
        if let points = try? await connection.session.send(PVE.guestRRD(reference, timeframe: timeframe)) {
            history = points.filter(\.hasData)
        }
    }

    private func loadExtras() async {
        let session = connection.session
        async let interfaces = session.guestInterfaces(reference)
        async let privileges = try? session.privileges(on: reference.aclPath)
        async let tasks = try? session.send(PVE.clusterTasks())
        self.interfaces = await interfaces
        if let privileges = await privileges { self.privileges = privileges }
        if let tasks = await tasks {
            recentTasks = tasks.filter { $0.objectID == String(reference.vmid) }
        }
    }

    // MARK: - Actions

    /// Runs a power action and waits for its task, then reloads the status.
    public func perform(_ action: PowerAction) async {
        actionError = nil
        do {
            let task = try await connection.perform(action, on: reference, reportsFailure: false)
            if case .failed(let message) = await connection.tasks.result(of: task.id) {
                actionError = message
            }
        } catch {
            actionError = error.localizedDescription
        }
        await loadStatus()
        await loadExtras()
    }

    public func dismissActionError() {
        actionError = nil
    }
}

/// Why a configuration change failed, in a form the editors can show.
public enum ConfigUpdateError: Error, Equatable, LocalizedError {
    /// Validation errors by parameter name.
    case invalid(message: String?, fields: [String: String])
    /// Someone else changed the configuration in the meantime.
    case conflict
    case failed(String)

    init(_ error: any Error) {
        switch error {
        case ProxmoxError.api(_, let message, let fields) where !fields.isEmpty:
            self = .invalid(message: message, fields: fields)
        case ProxmoxError.api(_, let message?, _) where message.contains("checksum mismatch") || message.contains("by other user"):
            self = .conflict
        default:
            self = .failed(error.localizedDescription)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalid(let message, let fields):
            let details = fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            return [message, details].compactMap { $0 }.joined(separator: "\n")
        case .conflict:
            return String(localized: "The configuration was changed by someone else. The latest version is loaded; review it and try again.")
        case .failed(let message):
            return message
        }
    }
}
