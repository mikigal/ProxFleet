import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// The datacenter's resource pools, and the members of the one being looked at.
@MainActor
@Observable
public final class PoolList {
    public let connection: ServerConnection

    public private(set) var pools: [ResourcePool]?
    public private(set) var details: [String: PoolDetail] = [:]
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    /// Creating, changing and deleting pools needs `Pool.Allocate`; on `/` it covers every pool.
    public var canModify: Bool { privileges?.contains("Pool.Allocate") ?? true }

    public func load() async {
        async let privileges = try? connection.session.privileges(on: "/pool")
        do {
            pools = try await connection.session.send(PVE.pools()).sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { self.privileges = privileges }
    }

    public func loadDetail(_ id: String) async {
        do {
            if let detail = try await connection.session.send(PVE.pool(id)).first {
                details[id] = detail
            }
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func create(_ id: String, comment: String) async throws(ConfigUpdateError) {
        try await perform(PVE.createPool(id, comment: comment.trimmingCharacters(in: .whitespacesAndNewlines)))
        await load()
    }

    public func updateComment(_ id: String, comment: String) async throws(ConfigUpdateError) {
        try await perform(PVE.updatePoolComment(id, comment: comment.trimmingCharacters(in: .whitespacesAndNewlines)))
        await load()
        await loadDetail(id)
    }

    /// Adds guests and storages; guests in another pool move to this one, as in the web interface.
    public func addMembers(to id: String, guests: [Int], storages: [String]) async throws(ConfigUpdateError) {
        guard !guests.isEmpty || !storages.isEmpty else { return }
        try await perform(PVE.addPoolMembers(id, guests: guests, storages: storages, allowMove: true))
        await loadDetail(id)
        await connection.refresh()
    }

    public func removeMembers(from id: String, guests: [Int], storages: [String]) async throws(ConfigUpdateError) {
        try await perform(PVE.removePoolMembers(id, guests: guests, storages: storages))
        await loadDetail(id)
        await connection.refresh()
    }

    /// The server refuses pools that still have members or nested pools.
    public func delete(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deletePool(id))
        details[id] = nil
        await load()
    }

    private func perform(_ request: APIRequest<Nothing>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
    }
}
