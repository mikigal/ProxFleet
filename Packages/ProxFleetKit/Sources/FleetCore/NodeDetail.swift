import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// Everything the node screen shows: status, history, services, updates, journal and tasks.
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

    /// Whether the user holds a privilege on `/nodes/{node}`. Unknown privileges count as granted.
    public func can(_ privilege: String) -> Bool {
        privileges?.contains(privilege) ?? true
    }

    // MARK: - Loading

    public func load() async {
        async let status: Void = loadStatus()
        async let history: Void = loadHistory()
        async let privileges = try? connection.session.privileges(on: "/nodes/\(node)")
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
        if let points = try? await connection.session.send(PVE.nodeRRD(node, timeframe: timeframe)) {
            history = points.filter(\.hasData)
        }
    }

    /// Loads a list for one of the screens. Returns an error message to show, or nil on success or cancellation.
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
