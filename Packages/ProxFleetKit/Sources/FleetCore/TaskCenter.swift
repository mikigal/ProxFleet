import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// Follows long-running Proxmox tasks (UPIDs) started from the app until they finish.
@MainActor
@Observable
public final class TaskCenter {
    public struct TrackedTask: Identifiable, Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case running
            case succeeded
            case failed(String)
        }

        public var upid: UPID
        public var title: String
        public var state: State
        public var finishedAt: Date?
        /// False when the screen that started the task shows its outcome itself.
        var reportsFailure = true

        public var id: String { upid.rawValue }
        public var isRunning: Bool { state == .running }
    }

    /// Newest first.
    public private(set) var tasks: [TrackedTask] = []
    /// The latest failure the UI has not shown yet.
    public private(set) var unreportedFailure: TrackedTask?

    @ObservationIgnored private let fetchStatus: @MainActor (UPID) async throws -> TaskStatus
    @ObservationIgnored private let onFinish: @MainActor (TrackedTask) async -> Void
    @ObservationIgnored private var pollers: [String: Task<Void, Never>] = [:]

    init(fetchStatus: @escaping @MainActor (UPID) async throws -> TaskStatus, onFinish: @escaping @MainActor (TrackedTask) async -> Void) {
        self.fetchStatus = fetchStatus
        self.onFinish = onFinish
    }

    public var runningTasks: [TrackedTask] { tasks.filter(\.isRunning) }

    /// The running task of a guest, if any.
    public func runningTask(forGuest vmid: Int) -> TrackedTask? {
        tasks.first { $0.isRunning && $0.upid.objectID == String(vmid) }
    }

    @discardableResult
    func track(_ rawUPID: String, title: String? = nil, reportsFailure: Bool = true) throws -> TrackedTask {
        guard let upid = UPID(rawUPID) else { throw ProxmoxError.invalidResponse("invalid task ID \(rawUPID)") }
        var task = TrackedTask(upid: upid, title: title ?? TaskDescription.title(type: upid.type, objectID: upid.objectID), state: .running)
        task.reportsFailure = reportsFailure
        tasks.insert(task, at: 0)
        if tasks.count > 50 { tasks.removeLast(tasks.count - 50) }
        pollers[task.id] = Task { [weak self] in await self?.poll(upid) }
        return task
    }

    /// Waits until a tracked task finished and returns its final state.
    public func result(of id: String) async -> TrackedTask.State {
        await pollers[id]?.value
        return tasks.first { $0.id == id }?.state ?? .failed("Unknown task.")
    }

    /// Hands the outcome of a task back to the task center, e.g. when the screen following it closes early.
    public func reportFailure(of id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].reportsFailure = true
        if case .failed = tasks[index].state { unreportedFailure = tasks[index] }
    }

    /// The user stopped the task on purpose, so its failure is not reported.
    func markStopped(_ id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].reportsFailure = false
        if unreportedFailure?.id == id { unreportedFailure = nil }
    }

    public func acknowledgeFailure() {
        unreportedFailure = nil
    }

    public func clearFinished() {
        tasks.removeAll { !$0.isRunning }
    }

    private func poll(_ upid: UPID) async {
        let started = Date()
        var failures = 0
        while !Task.isCancelled {
            // Quick at first, since most power actions finish within seconds.
            let elapsed = Date().timeIntervalSince(started)
            try? await Task.sleep(for: elapsed < 10 ? .milliseconds(500) : elapsed < 60 ? .seconds(1) : .seconds(3))
            do {
                let status = try await fetchStatus(upid)
                failures = 0
                guard !status.isRunning else { continue }
                finish(upid, state: status.succeeded ? .succeeded : .failed(status.exitStatus ?? "The task failed."))
                break
            } catch is CancellationError {
                break
            } catch {
                failures += 1
                if failures >= 10 {
                    finish(upid, state: .failed("Lost track of the task: \(error.localizedDescription)"))
                    break
                }
            }
        }
        pollers[upid.rawValue] = nil
        if let task = tasks.first(where: { $0.id == upid.rawValue }) {
            await onFinish(task)
        }
    }

    private func finish(_ upid: UPID, state: TrackedTask.State) {
        guard let index = tasks.firstIndex(where: { $0.id == upid.rawValue }) else { return }
        tasks[index].state = state
        tasks[index].finishedAt = Date()
        if case .failed = state, tasks[index].reportsFailure { unreportedFailure = tasks[index] }
    }
}
