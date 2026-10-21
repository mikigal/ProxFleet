import Foundation
import ProxmoxCore

/// One entry of `GET /access/users?full=1`.
public struct AccessUser: Decodable, Sendable, Equatable, Identifiable {
    /// `name@realm`.
    public var userid: String
    public var isEnabled: Bool
    /// nil when the account does not expire.
    public var expires: Date?
    public var firstName: String?
    public var lastName: String?
    public var email: String?
    public var comment: String?
    public var groups: [String]
    public var tokens: [APIToken]
    /// `pam`, `pve`, `ldap`, `ad`, `openid`…
    public var realmType: String?
    /// The user has Yubico OTP keys or a second factor locked after failed attempts.
    public var hasLegacyKeys: Bool

    public var id: String { userid }
    public var name: String { String(userid.prefix { $0 != "@" }) }
    public var realm: String { userid.split(separator: "@").last.map(String.init) ?? "" }
    public var displayName: String? {
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return full.isEmpty ? nil : full
    }

    public func isExpired(at date: Date = Date()) -> Bool { expires.map { $0 <= date } ?? false }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func text(_ key: String) -> String? {
            container.lossyString(AnyCodingKey(key))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        userid = text("userid") ?? ""
        isEnabled = container.lossyBool(AnyCodingKey("enable")) ?? true
        let expire = container.lossyInt(AnyCodingKey("expire")) ?? 0
        expires = expire > 0 ? Date(timeIntervalSince1970: TimeInterval(expire)) : nil
        firstName = text("firstname")
        lastName = text("lastname")
        email = text("email")
        comment = text("comment")
        // A comma-separated string in the list, an array for a single user.
        if let list = try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("groups")) {
            groups = list
        } else {
            groups = (text("groups") ?? "").split(separator: ",").map(String.init)
        }
        tokens = (try? container.decodeIfPresent([APIToken].self, forKey: AnyCodingKey("tokens"))) ?? []
        realmType = text("realm-type")
        hasLegacyKeys = text("keys") != nil
    }
}

/// An API token of a user.
public struct APIToken: Decodable, Sendable, Equatable, Identifiable {
    public var tokenid: String
    public var comment: String?
    public var expires: Date?
    /// Privilege separation: the token has its own permissions instead of the user's.
    public var isSeparated: Bool

    public var id: String { tokenid }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        tokenid = container.lossyString(AnyCodingKey("tokenid")) ?? ""
        comment = container.lossyString(AnyCodingKey("comment"))?.nilIfEmpty
        let expire = container.lossyInt(AnyCodingKey("expire")) ?? 0
        expires = expire > 0 ? Date(timeIntervalSince1970: TimeInterval(expire)) : nil
        isSeparated = container.lossyBool(AnyCodingKey("privsep")) ?? true
    }
}

/// `POST /access/users/{userid}/token/{tokenid}`: the secret is only ever shown here.
public struct CreatedToken: Decodable, Sendable, Equatable {
    /// `user@realm!tokenid`.
    public var fullID: String
    public var secret: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        fullID = container.lossyString(AnyCodingKey("full-tokenid")) ?? ""
        secret = container.lossyString(AnyCodingKey("value")) ?? ""
    }
}

/// One entry of `GET /access/groups`.
public struct AccessGroup: Decodable, Sendable, Equatable, Identifiable {
    public var groupid: String
    public var comment: String?
    public var members: [String]

    public var id: String { groupid }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        groupid = container.lossyString(AnyCodingKey("groupid")) ?? ""
        comment = container.lossyString(AnyCodingKey("comment"))?.nilIfEmpty
        members = (container.lossyString(AnyCodingKey("users")) ?? "").split(separator: ",").map(String.init)
    }
}

/// One entry of `GET /access/roles`.
public struct AccessRole: Decodable, Sendable, Equatable, Identifiable {
    public var roleid: String
    public var privileges: [String]
    /// Built-in roles cannot be changed.
    public var isBuiltIn: Bool

    public var id: String { roleid }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        roleid = container.lossyString(AnyCodingKey("roleid")) ?? ""
        privileges = (container.lossyString(AnyCodingKey("privs")) ?? "").split(separator: ",").map(String.init).sorted()
        isBuiltIn = container.lossyBool(AnyCodingKey("special")) ?? false
    }

    /// Every privilege the roles mention, grouped by their prefix (`VM`, `Sys`…), for the role editor.
    public static func privilegesByArea(_ roles: [AccessRole]) -> [(area: String, privileges: [String])] {
        let all = Set(roles.flatMap(\.privileges))
        let grouped = Dictionary(grouping: all) { String($0.prefix { $0 != "." }) }
        return grouped.keys.sorted().map { (area: $0, privileges: grouped[$0]!.sorted()) }
    }
}

/// One entry of `GET /access/acl`: a role granted on a path.
public struct ACLEntry: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public enum Subject: String, Sendable, CaseIterable, Identifiable {
        case user, group, token

        public var id: String { rawValue }
    }

    public var path: String
    public var subject: Subject
    /// A user ID, group name or full token ID.
    public var subjectID: String
    public var role: String
    /// Applies to the paths below as well.
    public var propagates: Bool

    public var id: String { "\(path)|\(subject.rawValue)|\(subjectID)|\(role)" }

    public init(path: String, subject: Subject, subjectID: String, role: String, propagates: Bool = true) {
        self.path = path
        self.subject = subject
        self.subjectID = subjectID
        self.role = role
        self.propagates = propagates
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        path = container.lossyString(AnyCodingKey("path")) ?? "/"
        subject = Subject(rawValue: container.lossyString(AnyCodingKey("type")) ?? "user") ?? .user
        subjectID = container.lossyString(AnyCodingKey("ugid")) ?? ""
        role = container.lossyString(AnyCodingKey("roleid")) ?? ""
        propagates = container.lossyBool(AnyCodingKey("propagate")) ?? true
    }

    /// Parameters of `PUT /access/acl`, which adds the entry, or removes it with `delete`.
    func parameters(delete: Bool) -> APIParameters {
        var parameters: APIParameters = ["path": .string(path), "roles": .string(role)]
        switch subject {
        case .user: parameters["users"] = .string(subjectID)
        case .group: parameters["groups"] = .string(subjectID)
        case .token: parameters["tokens"] = .string(subjectID)
        }
        if delete {
            parameters["delete"] = true
        } else {
            parameters["propagate"] = .bool(propagates)
        }
        return parameters
    }

    /// Paths a permission can be set on, for the picker: the main ones plus every guest, node, storage and pool.
    public static func suggestedPaths(snapshot: ClusterSnapshot?, pools: [String]) -> [String] {
        var paths = ["/", "/vms", "/nodes", "/storage", "/pool", "/access", "/access/groups", "/sdn", "/mapping"]
        paths += (snapshot?.guests ?? []).map { "/vms/\($0.vmid)" }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        paths += (snapshot?.nodes ?? []).map { "/nodes/\($0.name)" }
        paths += Set((snapshot?.storages ?? []).map(\.name)).sorted().map { "/storage/\($0)" }
        paths += pools.sorted().map { "/pool/\($0)" }
        return paths
    }
}

/// The form for a user. `PUT /access/users/{userid}` has no `delete`: cleared fields are sent empty.
public struct UserDraft: Equatable, Sendable {
    public var name = ""
    public var realm = "pve"
    /// Only for new users of the `pve` realm; other realms check passwords elsewhere.
    public var password = ""
    public var passwordConfirmation = ""
    public var firstName = ""
    public var lastName = ""
    public var email = ""
    public var comment = ""
    public var groups: Set<String> = []
    public var isEnabled = true
    public var expires: Date?

    public init() {}

    public init(_ user: AccessUser) {
        name = user.name
        realm = user.realm
        firstName = user.firstName ?? ""
        lastName = user.lastName ?? ""
        email = user.email ?? ""
        comment = user.comment ?? ""
        groups = Set(user.groups)
        isEnabled = user.isEnabled
        expires = user.expires
    }

    public var userid: String { "\(name.trimmingCharacters(in: .whitespaces))@\(realm)" }

    private static func text(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces) }

    func serialized() -> [String: String] {
        [
            "firstname": Self.text(firstName), "lastname": Self.text(lastName), "email": Self.text(email), "comment": Self.text(comment),
            "groups": groups.sorted().joined(separator: ","), "enable": isEnabled ? "1" : "0",
            "expire": expires.map { String(Int($0.timeIntervalSince1970)) } ?? "0",
        ]
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["userid": .string(userid)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) where !value.isEmpty && !(key == "expire" && value == "0") {
            parameters[key] = .string(value)
        }
        if realm == "pve", !password.isEmpty { parameters["password"] = .string(password) }
        return parameters
    }

    /// The changed settings, empty strings for cleared ones. Empty when nothing changed.
    public func changes(from original: UserDraft) -> APIParameters {
        var parameters = APIParameters()
        let old = original.serialized()
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) where value != old[key] {
            parameters[key] = .string(value)
        }
        return parameters
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew {
            let name = Self.text(name)
            if name.isEmpty {
                problems["userid"] = String(localized: "Enter a user name.")
            } else if name.contains(where: { $0.isWhitespace || "@:/".contains($0) }) {
                problems["userid"] = String(localized: "A user name cannot contain spaces, @, : or /.")
            }
            if realm == "pve" {
                if password.count < 8 {
                    problems["password"] = String(localized: "Use at least 8 characters.")
                } else if password != passwordConfirmation {
                    problems["password"] = String(localized: "The passwords do not match.")
                }
            }
        }
        let email = Self.text(email)
        if !email.isEmpty, !(email.contains("@") && email.contains(".")) {
            problems["email"] = String(localized: "Enter a valid email address.")
        }
        return problems
    }
}

extension PVE {
    public static func users() -> APIRequest<[AccessUser]> {
        APIRequest(.get, "/access/users", parameters: ["full": true])
    }

    public static func createUser(_ draft: UserDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/access/users", parameters: draft.creationParameters)
    }

    public static func updateUser(_ userid: String, _ changes: APIParameters) -> APIRequest<Nothing> {
        APIRequest(.put, "/access/users/\(escapePath(userid))", parameters: changes)
    }

    public static func deleteUser(_ userid: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/access/users/\(escapePath(userid))")
    }

    /// Changes a password. `confirmation` is the current password of the signed-in user; root@pam does not need it.
    public static func changePassword(userid: String, password: String, confirmation: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["userid": .string(userid), "password": .string(password)]
        if let confirmation, !confirmation.isEmpty { parameters["confirmation-password"] = .string(confirmation) }
        return APIRequest(.put, "/access/password", parameters: parameters)
    }

    public static func createToken(userid: String, tokenid: String, comment: String?, separated: Bool, expires: Date?) -> APIRequest<CreatedToken> {
        var parameters: APIParameters = ["privsep": .bool(separated)]
        if let comment, !comment.isEmpty { parameters["comment"] = .string(comment) }
        if let expires { parameters["expire"] = .int(Int(expires.timeIntervalSince1970)) }
        return APIRequest(.post, "/access/users/\(escapePath(userid))/token/\(escapePath(tokenid))", parameters: parameters)
    }

    public static func deleteToken(userid: String, tokenid: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/access/users/\(escapePath(userid))/token/\(escapePath(tokenid))")
    }

    public static func groups() -> APIRequest<[AccessGroup]> {
        APIRequest(.get, "/access/groups")
    }

    public static func createGroup(_ groupid: String, comment: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["groupid": .string(groupid)]
        if let comment, !comment.isEmpty { parameters["comment"] = .string(comment) }
        return APIRequest(.post, "/access/groups", parameters: parameters)
    }

    public static func updateGroup(_ groupid: String, comment: String) -> APIRequest<Nothing> {
        APIRequest(.put, "/access/groups/\(escapePath(groupid))", parameters: ["comment": .string(comment)])
    }

    public static func deleteGroup(_ groupid: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/access/groups/\(escapePath(groupid))")
    }

    public static func roles() -> APIRequest<[AccessRole]> {
        APIRequest(.get, "/access/roles")
    }

    public static func createRole(_ roleid: String, privileges: Set<String>) -> APIRequest<Nothing> {
        APIRequest(.post, "/access/roles", parameters: ["roleid": .string(roleid), "privs": .string(privileges.sorted().joined(separator: ","))])
    }

    /// Replaces the role's privileges.
    public static func updateRole(_ roleid: String, privileges: Set<String>) -> APIRequest<Nothing> {
        APIRequest(.put, "/access/roles/\(escapePath(roleid))", parameters: ["privs": .string(privileges.sorted().joined(separator: ","))])
    }

    public static func deleteRole(_ roleid: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/access/roles/\(escapePath(roleid))")
    }

    public static func acl() -> APIRequest<[ACLEntry]> {
        APIRequest(.get, "/access/acl")
    }

    public static func addPermission(_ entry: ACLEntry) -> APIRequest<Nothing> {
        APIRequest(.put, "/access/acl", parameters: entry.parameters(delete: false))
    }

    public static func removePermission(_ entry: ACLEntry) -> APIRequest<Nothing> {
        APIRequest(.put, "/access/acl", parameters: entry.parameters(delete: true))
    }
}
