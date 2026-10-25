import Foundation
import ProxmoxCore

/// An encryption key the server keeps for sync jobs, from `GET /config/encryption-keys` (4.2 and newer).
/// The key itself is never returned.
public struct EncryptionKeyEntry: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var fingerprint: String?
    public var hint: String?
    public var created: Date?
    /// When the key was archived: it still decrypts, but no longer encrypts new snapshots.
    public var archivedAt: Date?

    public var isArchived: Bool { archivedAt != nil }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = container.lossyString(AnyCodingKey("id")) ?? ""
        fingerprint = container.lossyString(AnyCodingKey("fingerprint"))
        hint = container.lossyString(AnyCodingKey("hint")).flatMap { $0.isEmpty ? nil : $0 }
        created = container.date("created")
        archivedAt = container.date("archived-at")
    }
}

extension PBS {
    public static func encryptionKeys(includeArchived: Bool = false) -> APIRequest<Digested<[EncryptionKeyEntry]>> {
        APIRequest(.get, "/config/encryption-keys", parameters: includeArchived ? ["include-archived": true] : APIParameters())
    }
}
