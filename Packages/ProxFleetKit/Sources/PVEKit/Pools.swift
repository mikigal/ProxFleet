import Foundation
import ProxmoxCore

/// A resource pool with its members, from `GET /pools?poolid=`.
public struct PoolDetail: Decodable, Sendable, Equatable {
    /// A guest or a storage in the pool. Storage members are listed once per node that has the storage.
    public struct Member: Decodable, Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable {
            case qemu, lxc, storage
        }

        /// `qemu/100`, `lxc/200` or `storage/{node}/{storage}`.
        public var id: String
        public var kind: Kind
        public var vmid: Int?
        public var name: String?
        public var storage: String?
        public var node: String?
        public var status: String?
        public var isTemplate: Bool

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            id = container.lossyString(AnyCodingKey("id")) ?? ""
            kind = container.lossyString(AnyCodingKey("type")).flatMap(Kind.init) ?? .qemu
            vmid = container.lossyInt(AnyCodingKey("vmid"))
            name = container.lossyString(AnyCodingKey("name"))
            storage = container.lossyString(AnyCodingKey("storage"))
            node = container.lossyString(AnyCodingKey("node"))
            status = container.lossyString(AnyCodingKey("status"))
            isTemplate = container.lossyBool(AnyCodingKey("template")) ?? false
        }
    }

    public var id: String
    public var comment: String?
    public var members: [Member]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = container.lossyString(AnyCodingKey("poolid")) ?? ""
        comment = container.lossyString(AnyCodingKey("comment")).flatMap { $0.isEmpty ? nil : $0 }
        members = (try? container.decode([Member].self, forKey: AnyCodingKey("members"))) ?? []
    }

    /// Guests sorted by ID.
    public var guests: [Member] {
        members.filter { $0.kind != .storage }.sorted { ($0.vmid ?? 0) < ($1.vmid ?? 0) }
    }

    /// Storage IDs, once each even when several nodes have the storage.
    public var storages: [String] {
        Array(Set(members.compactMap { $0.kind == .storage ? $0.storage : nil })).sorted()
    }
}

extension ResourcePool {
    /// Pools may be nested as `parent/child`, up to three levels, below an existing parent. Names start with a letter
    /// and use letters, digits, `-` and `_`.
    public static func problem(forName name: String) -> String? {
        let levels = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty else { return String(localized: "Enter a name.") }
        guard levels.count <= 3 else { return String(localized: "Pools can be nested at most three levels deep.") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let valid = name.first?.isLetter == true && levels.allSatisfy { level in
            !level.isEmpty && level.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        }
        return valid ? nil : String(localized: "Start with a letter and use letters, digits, - and _, with / between levels.")
    }
}

extension PVE {
    public static func pool(_ id: String) -> APIRequest<[PoolDetail]> {
        APIRequest(.get, "/pools", parameters: ["poolid": .string(id)])
    }

    public static func createPool(_ id: String, comment: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["poolid": .string(id)]
        if let comment, !comment.isEmpty { parameters["comment"] = .string(comment) }
        return APIRequest(.post, "/pools", parameters: parameters)
    }

    public static func updatePoolComment(_ id: String, comment: String) -> APIRequest<Nothing> {
        APIRequest(.put, "/pools", parameters: ["poolid": .string(id), "comment": .string(comment)])
    }

    /// Adds guests and storages. `allowMove` takes guests out of the pool they are in; without it the server refuses them.
    public static func addPoolMembers(_ id: String, guests: [Int], storages: [String], allowMove: Bool) -> APIRequest<Nothing> {
        var parameters = memberParameters(id, guests: guests, storages: storages)
        if allowMove { parameters["allow-move"] = true }
        return APIRequest(.put, "/pools", parameters: parameters)
    }

    public static func removePoolMembers(_ id: String, guests: [Int], storages: [String]) -> APIRequest<Nothing> {
        var parameters = memberParameters(id, guests: guests, storages: storages)
        parameters["delete"] = true
        return APIRequest(.put, "/pools", parameters: parameters)
    }

    /// Only empty pools can be deleted.
    public static func deletePool(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/pools", parameters: ["poolid": .string(id)])
    }

    private static func memberParameters(_ id: String, guests: [Int], storages: [String]) -> APIParameters {
        var parameters: APIParameters = ["poolid": .string(id)]
        if !guests.isEmpty { parameters["vms"] = .string(guests.sorted().map(String.init).joined(separator: ",")) }
        if !storages.isEmpty { parameters["storage"] = .string(storages.sorted().joined(separator: ",")) }
        return parameters
    }
}
