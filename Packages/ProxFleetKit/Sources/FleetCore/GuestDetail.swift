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
    public private(set) var history: [RRDPoint] = []
    /// nil while unknown, empty when the guest reports no addresses.
    public private(set) var interfaces: [GuestNetworkInterface]?
    public private(set) var privileges: Set<String>?
    public private(set) var recentTasks: [ClusterTask] = []
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
        if let config = try? await connection.session.send(PVE.guestConfig(reference)) {
            self.config = config
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
