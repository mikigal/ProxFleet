import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// The cluster's HA: its status, the guests it manages and the rules that place them.
@MainActor
@Observable
public final class HAManager {
    public let connection: ServerConnection

    public private(set) var status: [HAStatusEntry]?
    public private(set) var resources: [HAResource]?
    public private(set) var rules: [HARule]?
    public private(set) var loadError: String?

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    /// HA needs a cluster; three votes keep it quorate when a node fails.
    public var isAvailable: Bool { (connection.snapshot?.nodes.count ?? 0) > 1 }
    public var hasFewVotes: Bool { (connection.snapshot?.nodes.count ?? 0) < 3 }

    public var quorum: HAStatusEntry? { status?.first { $0.kind == .quorum } }
    public var master: HAStatusEntry? { status?.first { $0.kind == .master } }
    public var fencing: HAStatusEntry? { status?.first { $0.kind == .fencing } }
    public var localResourceManagers: [HAStatusEntry] { (status ?? []).filter { $0.kind == .lrm }.sorted { $0.node < $1.node } }
    public var isDisarmed: Bool { fencing?.armedState == "disarmed" }

    /// The resource's entry in the status: where it runs and its current state.
    public func serviceStatus(of sid: String) -> HAStatusEntry? {
        status?.first { $0.kind == .service && $0.sid == sid }
    }

    public func resource(forGuest vmid: Int) -> HAResource? {
        resources?.first { $0.vmid == vmid }
    }

    public func load() async {
        let session = connection.session
        async let status = session.send(PVE.haStatus())
        async let resources = session.send(PVE.haResources())
        let hasRules = connection.supports(.haRules)
        async let rules = hasRules ? try? session.send(PVE.haRules()) : nil
        do {
            self.status = try await status
            self.resources = try await resources.sorted { ($0.vmid ?? 0, $0.sid) < ($1.vmid ?? 0, $1.sid) }
            self.rules = await rules ?? []
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Reloads every few seconds while visible, as the web interface does, since HA acts in the background.
    public func keepRefreshing() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { break }
            await load()
        }
    }

    // MARK: - Resources

    public func add(_ draft: HAResourceDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createHAResource(draft))
    }

    public func update(_ sid: String, _ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        try await perform(PVE.updateHAResource(sid, update))
    }

    public func remove(_ sid: String, purgeFromRules: Bool) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteHAResource(sid, purge: purgeFromRules))
    }

    /// Asks HA to move a resource. Rules that block it come back as an error, as Proxmox does not refuse the request.
    /// Returns the resources that move along.
    @discardableResult
    public func move(_ sid: String, to node: String, relocate: Bool) async throws(ConfigUpdateError) -> [String] {
        let result: HAMoveResult
        do {
            result = try await connection.session.send(PVE.moveHAResource(sid, to: node, relocate: relocate))
        } catch {
            throw ConfigUpdateError(error)
        }
        if !result.blockingResources.isEmpty {
            let reasons = result.blockingResources.map { blocking in
                blocking.cause == "node-affinity"
                    ? String(localized: "\(blocking.sid) is not allowed on \(node) by a node affinity rule")
                    : String(localized: "\(blocking.sid) must stay apart from it by a resource affinity rule")
            }
            let list = reasons.joined(separator: "; ")
            throw .failed(String(localized: "HA cannot move \(sid) to \(node): \(list)."))
        }
        await load()
        return result.movedAlong
    }

    // MARK: - Rules

    public func add(_ draft: HARuleDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createHARule(draft, id: HARuleDraft.newID()))
    }

    public func update(_ rule: HARule, _ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        try await perform(PVE.updateHARule(rule.id, kind: rule.kind, update))
    }

    public func remove(_ rule: HARule) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteHARule(rule.id))
    }

    // MARK: - Arming

    public func disarm(resourceMode: String) async throws(ConfigUpdateError) {
        try await perform(PVE.disarmHA(resourceMode: resourceMode))
    }

    public func arm() async throws(ConfigUpdateError) {
        try await perform(PVE.armHA())
    }

    private func perform(_ request: APIRequest<Nothing>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
        await load()
        // The guest list shows each guest's HA state.
        await connection.refresh()
    }
}
