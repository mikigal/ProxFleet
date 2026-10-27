import Foundation
import Observation
import Synchronization

/// Decides when to ask for an App Store rating.
///
/// Only use of real servers counts, never the demo: the request comes after a successful task, once the app was used
/// on a few days, and at most once per app version and every few months. iOS itself shows the request no more than
/// three times a year, and never in TestFlight builds.
@MainActor
@Observable
public final class ReviewPrompt {
    /// Days with a sign-in to a real server before the first request.
    public static let activeDaysNeeded = 3
    /// Successful tasks on real servers since the last request.
    public static let succeededTasksNeeded = 5
    /// The shortest time between two requests.
    public static let minimumInterval: TimeInterval = 90 * 24 * 60 * 60

    /// A good moment to ask. The app asks, or waits for a better moment, and reports back.
    public private(set) var isDue = false

    @ObservationIgnored private let store: any ReviewPromptStore
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var record: ReviewPromptRecord

    public init(store: any ReviewPromptStore, appVersion: String = ReviewPrompt.bundleVersion, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.store = store
        self.appVersion = appVersion
        self.now = now
        self.calendar = calendar
        record = store.load()
    }

    public nonisolated static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// A real server was signed in to.
    func recordUse() {
        let today = calendar.startOfDay(for: now())
        guard record.lastActiveDay != today else { return }
        record.lastActiveDay = today
        record.activeDays += 1
        store.save(record)
    }

    /// A task on a real server succeeded, which is a good moment to ask.
    func recordSucceededTask() {
        record.succeededTasks += 1
        store.save(record)
        if shouldAsk { isDue = true }
    }

    /// The app showed the request.
    public func didRequest() {
        isDue = false
        record.succeededTasks = 0
        record.lastRequestedVersion = appVersion
        record.lastRequestedAt = now()
        store.save(record)
    }

    /// Not a good moment after all, e.g. the app is locked; the next successful task asks again.
    public func postpone() {
        isDue = false
    }

    private var shouldAsk: Bool {
        guard record.activeDays >= Self.activeDaysNeeded,
              record.succeededTasks >= Self.succeededTasksNeeded,
              record.lastRequestedVersion != appVersion else { return false }
        guard let last = record.lastRequestedAt else { return true }
        return now().timeIntervalSince(last) >= Self.minimumInterval
    }
}

public struct ReviewPromptRecord: Codable, Equatable, Sendable {
    public var activeDays = 0
    public var lastActiveDay: Date?
    public var succeededTasks = 0
    public var lastRequestedVersion: String?
    public var lastRequestedAt: Date?

    public init() {}
}

public protocol ReviewPromptStore: Sendable {
    func load() -> ReviewPromptRecord
    func save(_ record: ReviewPromptRecord)
}

/// Keeps the counts in `UserDefaults`, so they go away with the app.
public struct UserDefaultsReviewPromptStore: ReviewPromptStore {
    private static let key = "reviewPrompt"

    public init() {}

    public func load() -> ReviewPromptRecord {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(ReviewPromptRecord.self, from: data) else { return ReviewPromptRecord() }
        return record
    }

    public func save(_ record: ReviewPromptRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

public final class InMemoryReviewPromptStore: ReviewPromptStore {
    private let record: Mutex<ReviewPromptRecord>

    public init(_ record: ReviewPromptRecord = ReviewPromptRecord()) {
        self.record = Mutex(record)
    }

    public func load() -> ReviewPromptRecord { record.withLock { $0 } }
    public func save(_ record: ReviewPromptRecord) { self.record.withLock { $0 = record } }
}
