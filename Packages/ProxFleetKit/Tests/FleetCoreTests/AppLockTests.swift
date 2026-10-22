@testable import FleetCore
import Foundation
import Testing

@MainActor
struct AppLockTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    @Test func isOffUntilAPINIsSet() {
        let lock = AppLock(store: InMemoryAppLockStore())
        #expect(!lock.isEnabled)
        #expect(!lock.isLocked)
        lock.didEnterBackground()
        lock.willEnterForeground()
        #expect(!lock.isLocked)
        #expect(lock.check("0000") == .correct)
    }

    @Test func enablingKeepsTheAppOpenAndLocksOnNextLaunch() {
        let store = InMemoryAppLockStore()
        let lock = AppLock(store: store)
        lock.enable(pin: "1234")
        #expect(lock.isEnabled)
        #expect(!lock.isLocked)
        #expect(lock.pinLength == .four)

        let relaunched = AppLock(store: store)
        #expect(relaunched.isEnabled)
        #expect(relaunched.isLocked)
        #expect(relaunched.pinLength == .four)
        #expect(relaunched.unlock(pin: "1235") == .wrong(attemptsLeft: 4))
        #expect(relaunched.isLocked)
        #expect(relaunched.unlock(pin: "1234") == .correct)
        #expect(!relaunched.isLocked)
    }

    @Test func rejectsPINsOfOtherLengthsOrWithLetters() {
        let lock = AppLock(store: InMemoryAppLockStore())
        lock.enable(pin: "12345")
        lock.enable(pin: "12a4")
        #expect(!lock.isEnabled)
        lock.enable(pin: "123456")
        #expect(lock.pinLength == .six)
    }

    @Test func storesOnlyASaltedHash() throws {
        let store = InMemoryAppLockStore()
        AppLock(store: store).enable(pin: "123456")
        let first = try #require(store.load())
        AppLock(store: store).enable(pin: "123456")
        let second = try #require(store.load())
        #expect(first.pinHash.count == 32)
        #expect(first.pinHash != Data("123456".utf8))
        #expect(first.salt != second.salt)
        #expect(first.pinHash != second.pinHash)
    }

    @Test func waitsLongerAfterRepeatedWrongPINs() {
        let clock = Clock()
        let store = InMemoryAppLockStore()
        let lock = AppLock(store: store, now: { clock.now })
        lock.enable(pin: "1111")
        lock.lock()

        for left in (1...4).reversed() {
            #expect(lock.unlock(pin: "0000") == .wrong(attemptsLeft: left))
        }
        let until = clock.now.addingTimeInterval(30)
        #expect(lock.unlock(pin: "0000") == .lockedOut(until: until))
        // Even the right PIN waits, and a relaunch does not clear the wait.
        #expect(lock.unlock(pin: "1111") == .lockedOut(until: until))
        #expect(AppLock(store: store, now: { clock.now }).lockedOutUntil == until)

        clock.now = until
        #expect(lock.unlock(pin: "0000") == .lockedOut(until: clock.now.addingTimeInterval(60)))
        clock.now = clock.now.addingTimeInterval(60)
        #expect(lock.unlock(pin: "1111") == .correct)
        #expect(lock.lockedOutUntil == nil)

        lock.lock()
        #expect(lock.unlock(pin: "0000") == .wrong(attemptsLeft: 4))
    }

    @Test func lockoutDurationsGrow() {
        #expect(AppLock.lockoutDuration(afterFailures: 4) == nil)
        #expect(AppLock.lockoutDuration(afterFailures: 5) == 30)
        #expect(AppLock.lockoutDuration(afterFailures: 6) == 60)
        #expect(AppLock.lockoutDuration(afterFailures: 7) == 300)
        #expect(AppLock.lockoutDuration(afterFailures: 20) == 900)
    }

    @Test func locksAfterTheChosenTimeInTheBackground() {
        let clock = Clock()
        let lock = AppLock(store: InMemoryAppLockStore(), now: { clock.now })
        lock.enable(pin: "1111")

        lock.didEnterBackground()
        #expect(lock.isLocked)
        #expect(lock.lockGeneration == 1)
        lock.unlock(pin: "1111")

        lock.autoLockDelay = .oneMinute
        lock.didEnterBackground()
        clock.now = clock.now.addingTimeInterval(59)
        lock.willEnterForeground()
        #expect(!lock.isLocked)

        lock.didEnterBackground()
        clock.now = clock.now.addingTimeInterval(60)
        lock.willEnterForeground()
        #expect(lock.isLocked)
        #expect(lock.lockGeneration == 2)
    }

    @Test func biometricsUnlockOnlyWhenTurnedOn() {
        let lock = AppLock(store: InMemoryAppLockStore())
        lock.enable(pin: "1111")
        lock.lock()
        lock.unlockWithBiometrics()
        #expect(lock.isLocked)

        lock.setBiometrics(enabled: true, domainState: Data([1, 2]))
        #expect(lock.biometricDomainState == Data([1, 2]))
        lock.unlockWithBiometrics()
        #expect(!lock.isLocked)
    }

    @Test func changingThePINKeepsOtherSettings() {
        let store = InMemoryAppLockStore()
        let lock = AppLock(store: store)
        lock.enable(pin: "1111")
        lock.autoLockDelay = .fiveMinutes
        lock.setBiometrics(enabled: true, domainState: nil)
        lock.changePIN(to: "222222")

        let relaunched = AppLock(store: store)
        #expect(relaunched.pinLength == .six)
        #expect(relaunched.autoLockDelay == .fiveMinutes)
        #expect(relaunched.biometricsEnabled)
        #expect(relaunched.unlock(pin: "1111") == .wrong(attemptsLeft: 4))
        #expect(relaunched.unlock(pin: "222222") == .correct)
    }

    @Test func disablingForgetsEverything() {
        let store = InMemoryAppLockStore()
        let lock = AppLock(store: store)
        lock.enable(pin: "1111")
        lock.setBiometrics(enabled: true, domainState: nil)
        lock.lock()
        lock.disable()
        #expect(!lock.isEnabled)
        #expect(!lock.isLocked)
        #expect(store.load() == nil)
        #expect(!AppLock(store: store).biometricsEnabled)
    }
}
