import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct ReviewPromptTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(days: Int) { now += Double(days) * 24 * 60 * 60 }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func prompt(_ store: InMemoryReviewPromptStore, version: String = "1.0", clock: Clock) -> ReviewPrompt {
        ReviewPrompt(store: store, appVersion: version, now: { clock.now }, calendar: Self.calendar)
    }

    /// Uses the app on `days` days in a row, ending today.
    private func use(_ prompt: ReviewPrompt, days: Int, clock: Clock) {
        for day in 0..<days {
            if day > 0 { clock.advance(days: 1) }
            prompt.recordUse()
        }
    }

    @Test func waitsForEnoughDaysAndTasks() {
        let clock = Clock()
        let prompt = prompt(InMemoryReviewPromptStore(), clock: clock)
        use(prompt, days: 2, clock: clock)
        for _ in 0..<10 { prompt.recordSucceededTask() }
        #expect(!prompt.isDue)

        clock.advance(days: 1)
        prompt.recordUse()
        #expect(!prompt.isDue)
        prompt.recordSucceededTask()
        #expect(prompt.isDue)
    }

    @Test func countsADayOnce() {
        let clock = Clock()
        let store = InMemoryReviewPromptStore()
        let prompt = prompt(store, clock: clock)
        for _ in 0..<5 { prompt.recordUse() }
        clock.advance(days: 1)
        prompt.recordUse()
        #expect(store.load().activeDays == 2)
    }

    @Test func asksOncePerVersionAndEveryFewMonths() {
        let clock = Clock()
        let store = InMemoryReviewPromptStore()
        let first = prompt(store, clock: clock)
        use(first, days: 3, clock: clock)
        for _ in 0..<ReviewPrompt.succeededTasksNeeded { first.recordSucceededTask() }
        #expect(first.isDue)
        first.didRequest()
        #expect(!first.isDue)

        clock.advance(days: 200)
        for _ in 0..<20 { first.recordSucceededTask() }
        #expect(!first.isDue)

        // An update soon after the last request waits for the interval.
        clock.now = store.load().lastRequestedAt! + 30 * 24 * 60 * 60
        let updated = prompt(store, version: "1.1", clock: clock)
        for _ in 0..<ReviewPrompt.succeededTasksNeeded { updated.recordSucceededTask() }
        #expect(!updated.isDue)
        clock.advance(days: 60)
        updated.recordSucceededTask()
        #expect(updated.isDue)
    }

    @Test func postponingAsksAgainAtTheNextTask() {
        let clock = Clock()
        let prompt = prompt(InMemoryReviewPromptStore(), clock: clock)
        use(prompt, days: 3, clock: clock)
        for _ in 0..<ReviewPrompt.succeededTasksNeeded { prompt.recordSucceededTask() }
        prompt.postpone()
        #expect(!prompt.isDue)
        prompt.recordSucceededTask()
        #expect(prompt.isDue)
    }

    @Test func keepsCountsAcrossLaunches() {
        let clock = Clock()
        let store = InMemoryReviewPromptStore()
        use(prompt(store, clock: clock), days: 3, clock: clock)
        let relaunched = prompt(store, clock: clock)
        for _ in 0..<ReviewPrompt.succeededTasksNeeded { relaunched.recordSucceededTask() }
        #expect(relaunched.isDue)
    }

    // MARK: Servers

    /// Two days of use and one task short of asking, with the last use yesterday.
    private func almostDueStore() -> InMemoryReviewPromptStore {
        var record = ReviewPromptRecord()
        record.activeDays = ReviewPrompt.activeDaysNeeded - 1
        record.lastActiveDay = Calendar.current.startOfDay(for: Date()) - 24 * 60 * 60
        record.succeededTasks = ReviewPrompt.succeededTasksNeeded - 1
        return InMemoryReviewPromptStore(record)
    }

    private func fleet(_ store: InMemoryReviewPromptStore) -> Fleet {
        let transport = DemoTransport(cluster: .homelab)
        var environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        environment.reviewPrompts = store
        return Fleet(environment: environment)
    }

    @Test func signInsAndSucceededTasksOnRealServersCount() async throws {
        let store = almostDueStore()
        let fleet = fleet(store)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "lab", port: 8006)], username: "root", realm: "pam"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        #expect(store.load().activeDays == ReviewPrompt.activeDaysNeeded)

        let failed = try await connection.perform(.stop, on: GuestReference(node: "pve2", vmid: 102, kind: .virtualMachine))
        #expect(await connection.tasks.result(of: failed.id) != .succeeded)
        #expect(!fleet.reviewPrompt.isDue)

        let started = try await connection.perform(.start, on: GuestReference(node: "pve2", vmid: 102, kind: .virtualMachine))
        #expect(await connection.tasks.result(of: started.id) == .succeeded)
        #expect(fleet.reviewPrompt.isDue)
    }

    @Test func theDemoDoesNotCount() async throws {
        let store = almostDueStore()
        let before = store.load()
        let fleet = fleet(store)
        let connection = try #require(fleet.connection(for: fleet.addDemoServer().id))
        await connection.connect()
        try #require(connection.state == .connected)
        let started = try await connection.perform(.start, on: GuestReference(node: "pve2", vmid: 102, kind: .virtualMachine))
        #expect(await connection.tasks.result(of: started.id) == .succeeded)
        #expect(!fleet.reviewPrompt.isDue)
        #expect(store.load() == before)
    }
}
