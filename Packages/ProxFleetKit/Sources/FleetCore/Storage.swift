import Foundation
import ProxmoxCore
import Security
import Synchronization

/// Persists the list of saved servers. Contains no secrets.
public protocol ServerProfileStore: Sendable {
    func load() -> [ServerProfile]
    func save(_ profiles: [ServerProfile])
}

/// Stores server profiles as a JSON file.
public struct FileServerProfileStore: ServerProfileStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `Application Support/servers.json`.
    public static func standard() -> FileServerProfileStore {
        let directory = URL.applicationSupportDirectory
        return FileServerProfileStore(fileURL: directory.appending(path: "servers.json"))
    }

    public func load() -> [ServerProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ServerProfile].self, from: data)) ?? []
    }

    public func save(_ profiles: [ServerProfile]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            assertionFailure("Saving servers failed: \(error)")
        }
    }
}

public final class InMemoryServerProfileStore: ServerProfileStore {
    private let profiles: Mutex<[ServerProfile]>

    public init(_ profiles: [ServerProfile] = []) {
        self.profiles = Mutex(profiles)
    }

    public func load() -> [ServerProfile] { profiles.withLock { $0 } }
    public func save(_ profiles: [ServerProfile]) { self.profiles.withLock { $0 = profiles } }
}

/// Secrets for a saved server: the password (only when the user asked to remember it) and the last ticket.
public protocol CredentialStore: Sendable {
    func password(for server: UUID) -> String?
    func setPassword(_ password: String?, for server: UUID)
    func ticket(for server: UUID) -> AuthTicket?
    func setTicket(_ ticket: AuthTicket?, for server: UUID)
}

extension CredentialStore {
    public func removeAll(for server: UUID) {
        setPassword(nil, for: server)
        setTicket(nil, for: server)
    }
}

/// Keychain items readable only while the device is unlocked and never synced or restored to another device.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "ProxFleet") {
        self.service = service
    }

    public func password(for server: UUID) -> String? {
        read(account: "password.\(server.uuidString)").flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setPassword(_ password: String?, for server: UUID) {
        write(password.map { Data($0.utf8) }, account: "password.\(server.uuidString)")
    }

    public func ticket(for server: UUID) -> AuthTicket? {
        read(account: "ticket.\(server.uuidString)").flatMap { try? JSONDecoder().decode(AuthTicket.self, from: $0) }
    }

    public func setTicket(_ ticket: AuthTicket?, for server: UUID) {
        write(ticket.flatMap { try? JSONEncoder().encode($0) }, account: "ticket.\(server.uuidString)")
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func write(_ data: Data?, account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

public final class InMemoryCredentialStore: CredentialStore {
    private let passwords = Mutex<[UUID: String]>([:])
    private let tickets = Mutex<[UUID: AuthTicket]>([:])

    public init() {}

    public func password(for server: UUID) -> String? { passwords.withLock { $0[server] } }
    public func setPassword(_ password: String?, for server: UUID) { passwords.withLock { $0[server] = password } }
    public func ticket(for server: UUID) -> AuthTicket? { tickets.withLock { $0[server] } }
    public func setTicket(_ ticket: AuthTicket?, for server: UUID) { tickets.withLock { $0[server] = ticket } }
}
