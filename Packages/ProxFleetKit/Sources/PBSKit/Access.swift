import Foundation
import ProxmoxCore

/// One entry of `GET /access/acl`: a role a user or API token has on a path such as `/datastore/store1`.
public struct BackupServerACLEntry: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public var path: String
    /// A user ID (`backup@pbs`) or API token ID (`backup@pbs!sync`).
    public var authID: String
    public var role: String
    /// Whether the role also applies below the path.
    public var propagates: Bool

    public var id: String { "\(path)|\(authID)|\(role)" }
    public var isToken: Bool { authID.contains("!") }

    public init(path: String, authID: String, role: String, propagates: Bool = true) {
        self.path = path
        self.authID = authID
        self.role = role
        self.propagates = propagates
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        path = container.lossyString(AnyCodingKey("path")) ?? "/"
        authID = container.lossyString(AnyCodingKey("ugid")) ?? ""
        role = container.lossyString(AnyCodingKey("roleid")) ?? ""
        propagates = container.lossyBool(AnyCodingKey("propagate")) ?? true
    }
}

/// A built-in role of the backup server, from `GET /access/roles`. Roles cannot be created or changed.
public struct BackupServerRole: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var privileges: [String]
    public var comment: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = container.lossyString(AnyCodingKey("roleid")) ?? ""
        privileges = container.stringList("privs")
        comment = container.lossyString(AnyCodingKey("comment"))
    }
}

/// A user of the backup server with their API tokens, from `GET /access/users`.
public struct BackupServerUser: Decodable, Sendable, Equatable, Identifiable {
    public struct Token: Decodable, Sendable, Equatable, Identifiable {
        /// The full token ID, e.g. `root@pam!sync`.
        public var id: String
        public var comment: String?
        public var isEnabled: Bool
        public var expires: Date?

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            id = container.lossyString(AnyCodingKey("tokenid")) ?? ""
            comment = container.lossyString(AnyCodingKey("comment")).flatMap { $0.isEmpty ? nil : $0 }
            isEnabled = container.lossyBool(AnyCodingKey("enable")) ?? true
            expires = container.date("expire").flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        }
    }

    public var id: String
    public var comment: String?
    public var email: String?
    public var firstName: String?
    public var lastName: String?
    public var isEnabled: Bool
    /// Nil when the account does not expire.
    public var expires: Date?
    public var tokens: [Token]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func text(_ key: String) -> String? { container.lossyString(AnyCodingKey(key)).flatMap { $0.isEmpty ? nil : $0 } }
        id = text("userid") ?? ""
        comment = text("comment")
        email = text("email")
        firstName = text("firstname")
        lastName = text("lastname")
        isEnabled = container.lossyBool(AnyCodingKey("enable")) ?? true
        expires = container.date("expire").flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        tokens = (try? container.decodeIfPresent([Token].self, forKey: AnyCodingKey("tokens"))) ?? []
    }

    /// The user and their tokens, the identities a permission can be given to.
    public var authIDs: [String] { [id] + tokens.map(\.id) }
}

extension PBS {
    /// Permissions on a path; with `exact`, only those set on the path itself, not inherited ones.
    public static func acl(path: String? = nil, exact: Bool = false) -> APIRequest<Digested<[BackupServerACLEntry]>> {
        var parameters = APIParameters()
        if let path { parameters["path"] = .string(path) }
        if exact { parameters["exact"] = true }
        return APIRequest(.get, "/access/acl", parameters: parameters)
    }

    /// Gives a user or token a role on a path, or with `remove` takes it away again.
    public static func setACL(_ entry: BackupServerACLEntry, remove: Bool = false, digest: String? = nil) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["path": .string(entry.path), "role": .string(entry.role), "auth-id": .string(entry.authID)]
        if !remove { parameters["propagate"] = .bool(entry.propagates) }
        if remove { parameters["delete"] = true }
        if let digest { parameters["digest"] = .string(digest) }
        return APIRequest(.put, "/access/acl", parameters: parameters)
    }

    public static func roles() -> APIRequest<[BackupServerRole]> {
        APIRequest(.get, "/access/roles")
    }

    public static func users(includeTokens: Bool = true) -> APIRequest<Digested<[BackupServerUser]>> {
        APIRequest(.get, "/access/users", parameters: includeTokens ? ["include_tokens": true] : APIParameters())
    }

    /// Privileges of the signed-in user on a path. Proxmox Backup Server answers with booleans.
    public static func permissions(path: String) -> APIRequest<[String: [String: Bool]]> {
        APIRequest(.get, "/access/permissions", parameters: ["path": .string(path)])
    }
}

extension ProxmoxSession {
    /// Privileges the signed-in user has on a backup server path, e.g. `/datastore/store1`.
    public func backupServerPrivileges(on path: String) async throws -> Set<String> {
        let result = try await send(PBS.permissions(path: path))
        return Set((result[path] ?? [:]).filter(\.value).keys)
    }
}
