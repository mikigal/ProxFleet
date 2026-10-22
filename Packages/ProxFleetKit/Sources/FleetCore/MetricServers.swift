import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// External metric servers (`/cluster/metrics/server`).
@MainActor
@Observable
public final class MetricServerSettings {
    public let connection: ServerConnection

    public private(set) var servers: [MetricServer]?
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    /// Changing metric servers needs `Sys.Modify` on `/`.
    public var canModify: Bool { privileges?.contains("Sys.Modify") ?? true }

    public func load() async {
        async let privileges = try? connection.session.privileges(on: "/")
        do {
            servers = try await connection.session.send(PVE.metricServers()).sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { self.privileges = privileges }
    }

    /// The list leaves settings out, so editors load the whole entry.
    public func server(_ id: String) async throws(ConfigUpdateError) -> MetricServer {
        do {
            return try await connection.session.send(PVE.metricServer(id))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func create(_ draft: MetricServerDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createMetricServer(draft))
    }

    public func update(_ draft: MetricServerDraft, _ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PVE.updateMetricServer(draft, update))
    }

    public func delete(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteMetricServer(id))
    }

    private func perform(_ request: APIRequest<Nothing>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
        await load()
    }
}
