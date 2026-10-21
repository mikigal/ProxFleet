import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// The datacenter's scheduled backup jobs and the guests none of them covers.
@MainActor
@Observable
public final class BackupJobList {
    public let connection: ServerConnection

    public private(set) var jobs: [BackupJob]?
    public private(set) var unprotectedGuests: [UnprotectedGuest]?
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    /// Changing backup jobs needs `Sys.Modify` on `/`.
    public var canModify: Bool { privileges?.contains("Sys.Modify") ?? true }

    public func load() async {
        async let privileges = try? connection.session.privileges(on: "/")
        do {
            jobs = try await connection.session.send(PVE.backupJobs())
                .sorted { ($0.nextRun ?? .distantFuture, $0.id) < ($1.nextRun ?? .distantFuture, $1.id) }
            unprotectedGuests = try? await connection.session.send(PVE.guestsWithoutBackupJob()).sorted { $0.vmid < $1.vmid }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { self.privileges = privileges }
    }

    public func create(_ draft: BackupJobDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createBackupJob(draft))
        await load()
    }

    public func update(_ id: String, _ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        try await perform(PVE.updateBackupJob(id, update))
        await load()
    }

    public func delete(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteBackupJob(id))
        await load()
    }

    /// The next runs of a schedule, or the server's reason it cannot parse it.
    public func nextRuns(of schedule: String) async -> Result<[Date], ConfigUpdateError> {
        do {
            return .success(try await connection.session.send(PVE.scheduleRuns(schedule)).map(\.date))
        } catch {
            return .failure(ConfigUpdateError(error))
        }
    }

    /// Starts the job on its nodes now. The backups show in the task list; failures are reported there.
    @discardableResult
    public func runNow(_ job: BackupJob) async throws(ConfigUpdateError) -> [TaskCenter.TrackedTask] {
        guard let snapshot = connection.snapshot else { return [] }
        var started: [TaskCenter.TrackedTask] = []
        do {
            for (_, request) in job.runNowRequests(in: snapshot) {
                if let upid = try await connection.session.send(request) {
                    started.append(try connection.tasks.track(upid, reportsFailure: true))
                }
            }
        } catch {
            throw ConfigUpdateError(error)
        }
        return started
    }

    private func perform(_ request: APIRequest<Nothing>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
    }
}
