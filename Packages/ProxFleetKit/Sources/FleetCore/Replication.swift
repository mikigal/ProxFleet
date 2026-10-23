import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// Storage replication jobs of the whole cluster, of one node's guests or of one guest, with their state.
@MainActor
@Observable
public final class ReplicationJobList {
    public enum Scope: Sendable, Equatable {
        case datacenter
        case node(String)
        case guest(GuestReference)
    }

    public let connection: ServerConnection
    public let scope: Scope

    /// Sorted by guest and job number. nil until loaded.
    public private(set) var jobs: [ReplicationJob]?
    public private(set) var loadError: String?

    public init(connection: ServerConnection, scope: Scope) {
        self.connection = connection
        self.scope = scope
    }

    /// Replication needs another node to copy to.
    public var isAvailable: Bool { (connection.snapshot?.nodes.count ?? 0) > 1 }

    /// The guest is reached on the node it runs on now, which changes with migration.
    private var guestNode: String? {
        guard case .guest(let reference) = scope else { return nil }
        return connection.snapshot?.guests.first { $0.vmid == reference.vmid }?.node ?? reference.node
    }

    public func load() async {
        let session = connection.session
        do {
            switch scope {
            case .datacenter:
                // The configuration has every job; each node knows the state of the jobs of its guests.
                let online = connection.snapshot?.nodes.filter(\.isOnline).map(\.name) ?? []
                async let configured = session.send(PVE.replicationJobs())
                let states = await withTaskGroup(of: [ReplicationJob].self) { group in
                    for node in online {
                        group.addTask { (try? await session.send(PVE.replicationStatus(node: node))) ?? [] }
                    }
                    var all: [String: ReplicationJob] = [:]
                    for await jobs in group {
                        for job in jobs { all[job.id] = job }
                    }
                    return all
                }
                jobs = try await configured.map { job in
                    guard var state = states[job.id] else { return job }
                    // The configuration knows about pending removal before the node does.
                    state.removal = job.removal ?? state.removal
                    return state
                }.sorted(by: Self.order)
            case .node(let node):
                jobs = try await session.send(PVE.replicationStatus(node: node)).sorted(by: Self.order)
            case .guest(let reference):
                jobs = try await session.send(PVE.replicationStatus(node: guestNode ?? reference.node, guest: reference.vmid)).sorted(by: Self.order)
            }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Reloads every few seconds while the screen is visible, like the web interface, to follow running jobs.
    public func keepRefreshing() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { break }
            await load()
        }
    }

    private static func order(_ lhs: ReplicationJob, _ rhs: ReplicationJob) -> Bool {
        (lhs.guest, lhs.jobNumber) < (rhs.guest, rhs.jobNumber)
    }

    /// The next runs of a schedule, or the server's reason it cannot parse it.
    public func nextRuns(of schedule: String) async -> Result<[Date], ConfigUpdateError> {
        do {
            return .success(try await connection.session.send(PVE.scheduleRuns(schedule)).map(\.date))
        } catch {
            return .failure(ConfigUpdateError(error))
        }
    }

    /// Creates a job with the guest's next free job number.
    public func create(_ draft: ReplicationJobDraft) async throws(ConfigUpdateError) {
        do {
            let existing = try await connection.session.send(PVE.replicationJobs())
            _ = try await connection.session.send(PVE.createReplicationJob(draft, id: ReplicationJobDraft.nextID(for: draft.guest, existing: existing)))
        } catch {
            throw ConfigUpdateError(error)
        }
        await load()
    }

    public func update(_ id: String, _ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        try await perform(PVE.updateReplicationJob(id, update))
        await load()
    }

    /// Marks the job for removal; it disappears after its next run, which removes its snapshots and copies.
    public func delete(_ job: ReplicationJob, keepData: Bool = false) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteReplicationJob(job.id, keep: keepData))
        // Removal waits for the next run, so it happens now instead of at the next scheduled time.
        if let node = node(of: job) {
            _ = try? await connection.session.send(PVE.runReplicationNow(node: node, id: job.id))
        }
        await load()
    }

    /// Asks the guest's node to run the job within about a minute.
    public func runNow(_ job: ReplicationJob) async throws(ConfigUpdateError) {
        guard let node = node(of: job) else { throw .failed(String(localized: "The guest's node is not known.")) }
        do {
            _ = try await connection.session.send(PVE.runReplicationNow(node: node, id: job.id))
        } catch {
            throw ConfigUpdateError(error)
        }
        await load()
    }

    /// The log of the job's last run.
    public func log(of job: ReplicationJob) async throws -> [TaskLogLine] {
        guard let node = node(of: job) else { return [] }
        return try await connection.session.send(PVE.replicationLog(node: node, id: job.id))
    }

    /// Jobs run on the node the guest is on.
    public func node(of job: ReplicationJob) -> String? {
        connection.snapshot?.guests.first { $0.vmid == job.guest }?.node ?? job.source
    }

    private func perform(_ request: APIRequest<Nothing>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
    }
}
