import CommonCrypto
import Foundation
import Observation
import Security
import Synchronization

/// The optional PIN lock in front of the whole app, with Face ID as a shortcut once a PIN exists.
///
/// It locks the interface only. Secrets are already protected by the Keychain; the PIN itself is stored as a salted
/// PBKDF2 hash. Biometric checks happen in the app, which reports a success through `unlockWithBiometrics()`.
@MainActor
@Observable
public final class AppLock {
    public enum PINLength: Int, CaseIterable, Codable, Sendable {
        case four = 4
        case six = 6
    }

    /// How long the app may stay in the background before the PIN is asked again.
    public enum AutoLockDelay: Int, CaseIterable, Codable, Sendable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900
    }

    public enum CheckResult: Equatable, Sendable {
        case correct
        /// Wrong PIN; `attemptsLeft` more tries before a wait.
        case wrong(attemptsLeft: Int)
        /// Too many wrong PINs: no tries until the date, whatever is typed.
        case lockedOut(until: Date)
    }

    /// Wrong PINs allowed before the first wait.
    public static let freeAttempts = 5

    public private(set) var isEnabled: Bool
    public private(set) var isLocked: Bool
    /// Increases with every lock, so the lock screen can offer Face ID once per lock.
    public private(set) var lockGeneration = 0
    public private(set) var lockedOutUntil: Date?

    public var pinLength: PINLength { record?.pinLength ?? .six }
    public var biometricsEnabled: Bool { record?.biometricsEnabled ?? false }
    /// The biometric enrollment Face ID was turned on with; another enrollment must not unlock without the PIN.
    public var biometricDomainState: Data? { record?.biometricDomainState }

    public var autoLockDelay: AutoLockDelay {
        get { record?.autoLockDelay ?? .immediately }
        set { update { $0.autoLockDelay = newValue } }
    }

    @ObservationIgnored private let store: any AppLockStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var backgroundedAt: Date?
    private var record: AppLockRecord?

    public init(store: any AppLockStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        let saved = store.load()
        record = saved
        isEnabled = saved != nil
        isLocked = saved != nil
        lockedOutUntil = saved?.lockedOutUntil
    }

    // MARK: Settings

    /// Turns the lock on with a new PIN. The app stays unlocked.
    public func enable(pin: String) {
        guard let length = PINLength(rawValue: pin.count), pin.allSatisfy(\.isASCIIDigit) else { return }
        let salt = Self.randomSalt()
        record = AppLockRecord(
            pinHash: Self.hash(pin, salt: salt, rounds: AppLockRecord.defaultRounds),
            salt: salt,
            rounds: AppLockRecord.defaultRounds,
            pinLength: length,
            autoLockDelay: record?.autoLockDelay ?? .immediately,
            biometricsEnabled: record?.biometricsEnabled ?? false,
            biometricDomainState: record?.biometricDomainState
        )
        store.save(record)
        isEnabled = true
        isLocked = false
        lockedOutUntil = nil
    }

    /// Keeps the other settings, including Face ID.
    public func changePIN(to pin: String) {
        guard isEnabled else { return }
        enable(pin: pin)
    }

    /// Turns the lock off and forgets the PIN and Face ID choice.
    public func disable() {
        record = nil
        store.save(nil)
        isEnabled = false
        isLocked = false
        lockedOutUntil = nil
    }

    public func setBiometrics(enabled: Bool, domainState: Data?) {
        update {
            $0.biometricsEnabled = enabled
            $0.biometricDomainState = enabled ? domainState : nil
        }
    }

    // MARK: Checking

    /// Checks a PIN, counting wrong ones towards a wait. Used by the lock screen and by settings changes.
    public func check(_ pin: String) -> CheckResult {
        guard var current = record else { return .correct }
        if let until = current.lockedOutUntil, until > now() {
            return .lockedOut(until: until)
        }
        if Self.constantTimeEqual(Self.hash(pin, salt: current.salt, rounds: current.rounds), current.pinHash) {
            current.failedAttempts = 0
            current.lockedOutUntil = nil
            save(current)
            return .correct
        }
        current.failedAttempts += 1
        let result: CheckResult
        if let wait = Self.lockoutDuration(afterFailures: current.failedAttempts) {
            let until = now().addingTimeInterval(wait)
            current.lockedOutUntil = until
            result = .lockedOut(until: until)
        } else {
            current.lockedOutUntil = nil
            result = .wrong(attemptsLeft: Self.freeAttempts - current.failedAttempts)
        }
        save(current)
        return result
    }

    /// Unlocks with a PIN; the result says why it did not.
    @discardableResult
    public func unlock(pin: String) -> CheckResult {
        let result = check(pin)
        if result == .correct {
            isLocked = false
        }
        return result
    }

    /// Called after the system confirmed the user's face or fingerprint.
    public func unlockWithBiometrics() {
        guard biometricsEnabled else { return }
        update {
            $0.failedAttempts = 0
            $0.lockedOutUntil = nil
        }
        isLocked = false
    }

    /// Wait after the given number of wrong PINs in a row, or nil while tries are left.
    static func lockoutDuration(afterFailures failures: Int) -> TimeInterval? {
        switch failures - freeAttempts {
        case ..<0: nil
        case 0: 30
        case 1: 60
        case 2: 5 * 60
        default: 15 * 60
        }
    }

    // MARK: App lifecycle

    public func lock() {
        guard isEnabled else { return }
        if !isLocked {
            lockGeneration += 1
        }
        isLocked = true
    }

    public func didEnterBackground() {
        guard isEnabled else { return }
        if autoLockDelay == .immediately {
            lock()
        } else {
            backgroundedAt = now()
        }
    }

    public func willEnterForeground() {
        guard isEnabled, let backgroundedAt else { return }
        self.backgroundedAt = nil
        if now().timeIntervalSince(backgroundedAt) >= TimeInterval(autoLockDelay.rawValue) {
            lock()
        }
    }

    // MARK: Storage

    private func update(_ change: (inout AppLockRecord) -> Void) {
        guard var current = record else { return }
        change(&current)
        save(current)
    }

    private func save(_ updated: AppLockRecord) {
        record = updated
        lockedOutUntil = updated.lockedOutUntil
        store.save(updated)
    }

    // MARK: Hashing

    static func hash(_ pin: String, salt: Data, rounds: Int) -> Data {
        let password = Array(pin.utf8).map { Int8(bitPattern: $0) }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password, password.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(rounds),
                &derived, derived.count
            )
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return Data(derived)
    }

    private static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No random bytes: \(status)")
        return Data(bytes)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Everything the lock keeps between launches. Nil means the lock is off.
public struct AppLockRecord: Codable, Equatable, Sendable {
    static let defaultRounds = 100_000

    var pinHash: Data
    var salt: Data
    var rounds: Int
    var pinLength: AppLock.PINLength
    var autoLockDelay: AppLock.AutoLockDelay
    var biometricsEnabled: Bool
    var biometricDomainState: Data?
    var failedAttempts = 0
    var lockedOutUntil: Date?
}

public protocol AppLockStore: Sendable {
    func load() -> AppLockRecord?
    func save(_ record: AppLockRecord?)
}

/// Keeps the record in the Keychain, on this device only.
///
/// Keychain items outlive the app, so a marker in `UserDefaults` (which is deleted with the app) tells a record from
/// an earlier installation apart; such a record is dropped instead of locking a fresh install with a forgotten PIN.
public struct KeychainAppLockStore: AppLockStore {
    private static let account = "appLock"
    private static let markerKey = "appLock.configured"
    private let service: String

    public init(service: String = "ProxFleet") {
        self.service = service
    }

    public func load() -> AppLockRecord? {
        guard UserDefaults.standard.bool(forKey: Self.markerKey) else {
            SecItemDelete(baseQuery() as CFDictionary)
            return nil
        }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AppLockRecord.self, from: data)
    }

    public func save(_ record: AppLockRecord?) {
        let query = baseQuery()
        SecItemDelete(query as CFDictionary)
        guard let record, let data = try? JSONEncoder().encode(record) else {
            UserDefaults.standard.removeObject(forKey: Self.markerKey)
            return
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
        UserDefaults.standard.set(true, forKey: Self.markerKey)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

public final class InMemoryAppLockStore: AppLockStore {
    private let record: Mutex<AppLockRecord?>

    public init(_ record: AppLockRecord? = nil) {
        self.record = Mutex(record)
    }

    public func load() -> AppLockRecord? { record.withLock { $0 } }
    public func save(_ record: AppLockRecord?) { self.record.withLock { $0 = record } }
}
