import Foundation
import ProxmoxCore

/// Proxmox Backup Server endpoints. A backup server is a single node, which the API calls `localhost`.
public enum PBS {
    /// Node name the API accepts for the server itself.
    public static let node = "localhost"

    static func escapePath(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? segment
    }
}

/// A configuration object together with the digest of its file, which Proxmox Backup Server sends next to `data`
/// instead of inside it. Updates send the digest back so the server refuses changes made by someone else meanwhile.
public struct Digested<Value: Decodable & Sendable>: EnvelopeDecodable, Sendable {
    public var value: Value
    public var digest: String?

    public init(value: Value, digest: String? = nil) {
        self.value = value
        self.digest = digest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        value = try container.decode(Value.self, forKey: AnyCodingKey("data"))
        digest = container.lossyString(AnyCodingKey("digest"))
    }
}

extension Digested: Equatable where Value: Equatable {}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// A list of strings that may also come as one comma-separated string, as list settings do in older releases.
    func stringList(_ key: String) -> [String] {
        if let list = try? decodeIfPresent([String].self, forKey: AnyCodingKey(key)) { return list }
        guard let text = lossyString(AnyCodingKey(key)) else { return [] }
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func date(_ key: String) -> Date? {
        lossyDouble(AnyCodingKey(key)).map { Date(timeIntervalSince1970: $0) }
    }

    func int64(_ key: String) -> Int64? {
        lossyDouble(AnyCodingKey(key)).map { Int64($0) }
    }
}
