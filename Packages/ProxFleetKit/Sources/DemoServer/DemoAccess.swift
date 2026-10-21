import Foundation
import ProxmoxCore

/// Users, groups, roles and permissions in demo mode.
struct DemoAccess: Sendable {
    struct User: Sendable {
        var id: String
        var values: [String: String]
        var tokens: [(id: String, comment: String, separated: Bool, expire: Int)] = []
    }

    var users: [User]
    var groups: [(id: String, comment: String)]
    var roles: [(id: String, privileges: [String], builtIn: Bool)]
    var acl: [(path: String, type: String, id: String, role: String, propagate: Bool)]

    static let builtInRoles: [(id: String, privileges: [String])] = [
        ("Administrator", ["Datastore.Allocate", "Datastore.AllocateSpace", "Datastore.AllocateTemplate", "Datastore.Audit", "Group.Allocate",
                           "Mapping.Audit", "Mapping.Modify", "Mapping.Use", "Permissions.Modify", "Pool.Allocate", "Pool.Audit", "Realm.Allocate",
                           "Realm.AllocateUser", "SDN.Allocate", "SDN.Audit", "SDN.Use", "Sys.AccessNetwork", "Sys.Audit", "Sys.Console", "Sys.Incoming",
                           "Sys.Modify", "Sys.PowerMgmt", "Sys.Syslog", "User.Modify", "VM.Allocate", "VM.Audit", "VM.Backup", "VM.Clone",
                           "VM.Config.CDROM", "VM.Config.CPU", "VM.Config.Cloudinit", "VM.Config.Disk", "VM.Config.HWType", "VM.Config.Memory",
                           "VM.Config.Network", "VM.Config.Options", "VM.Console", "VM.GuestAgent.Audit", "VM.Migrate", "VM.PowerMgmt",
                           "VM.Replicate", "VM.Snapshot", "VM.Snapshot.Rollback"]),
        ("NoAccess", []),
        ("PVEAuditor", ["Datastore.Audit", "Mapping.Audit", "Pool.Audit", "SDN.Audit", "Sys.Audit", "VM.Audit", "VM.GuestAgent.Audit"]),
        ("PVEDatastoreUser", ["Datastore.AllocateSpace", "Datastore.Audit"]),
        ("PVEUserAdmin", ["Group.Allocate", "Realm.AllocateUser", "User.Modify"]),
        ("PVEVMAdmin", ["VM.Allocate", "VM.Audit", "VM.Backup", "VM.Clone", "VM.Config.CDROM", "VM.Config.CPU", "VM.Config.Disk", "VM.Config.Memory",
                        "VM.Config.Network", "VM.Config.Options", "VM.Console", "VM.Migrate", "VM.PowerMgmt", "VM.Snapshot"]),
        ("PVEVMUser", ["VM.Audit", "VM.Backup", "VM.Config.CDROM", "VM.Console", "VM.PowerMgmt"]),
    ]

    static let sample = DemoAccess(
        users: [
            User(id: "root@pam", values: ["realm-type": "pam", "enable": "1", "email": "admin@example.com"]),
            User(id: "anna@pve", values: ["realm-type": "pve", "enable": "1", "firstname": "Anna", "lastname": "Kowalska",
                                          "email": "anna@example.com", "groups": "admins"],
                 tokens: [(id: "monitoring", comment: "Grafana", separated: true, expire: 0)]),
            User(id: "ci@pve", values: ["realm-type": "pve", "enable": "1", "comment": "Build pipeline", "groups": "developers"]),
            User(id: "auditor@pve", values: ["realm-type": "pve", "enable": "1", "comment": "Read-only"]),
            User(id: "intern@pve", values: ["realm-type": "pve", "enable": "0", "comment": "Summer 2026", "expire": "1788220800"]),
        ],
        groups: [("admins", "Full access"), ("developers", "Lab guests")],
        roles: builtInRoles.map { (id: $0.id, privileges: $0.privileges, builtIn: true) }
            + [(id: "LabOperator", privileges: ["VM.Audit", "VM.Console", "VM.PowerMgmt", "VM.Snapshot"], builtIn: false)],
        acl: [
            (path: "/", type: "group", id: "admins", role: "Administrator", propagate: true),
            (path: "/", type: "user", id: "auditor@pve", role: "PVEAuditor", propagate: true),
            (path: "/pool/lab", type: "group", id: "developers", role: "LabOperator", propagate: true),
            (path: "/vms/103", type: "user", id: "ci@pve", role: "PVEVMAdmin", propagate: false),
            (path: "/", type: "token", id: "anna@pve!monitoring", role: "PVEAuditor", propagate: true),
        ]
    )
}

extension DemoState {
    /// Routes below `/access` other than login, realms and permissions. nil for other paths.
    func handleAccess(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard parts.first == "access", parts.count >= 2, ["users", "groups", "roles", "acl", "password"].contains(parts[1]) else { return nil }
        let canModify = privileges(for: user).contains("User.Modify")
        if method != .get, !canModify, !(parts == ["access", "password"] && parameters["userid"] == user) {
            return failure(403, "Permission check failed (/access, User.Modify)")
        }
        let rest = Array(parts.dropFirst())
        switch (method, rest) {
        case (.get, ["users"]):
            return success(.array(access.users.map { userJSON($0, list: true) }))
        case (.get, let path) where path.count == 2 && path[0] == "users":
            guard let found = access.users.first(where: { $0.id == path[1] }) else { return failure(500, "no such user ('\(path[1])')") }
            return success(userJSON(found, list: false))
        case (.post, ["users"]):
            guard let id = parameters["userid"], id.contains("@") else { return fieldFailure(["userid": "value does not look like a valid user ID"]) }
            guard !access.users.contains(where: { $0.id == id }) else { return failure(500, "create user failed: user '\(id)' already exists") }
            let realm = String(id.split(separator: "@").last ?? "")
            guard ["pam", "pve"].contains(realm) else { return fieldFailure(["userid": "domain '\(realm)' does not exist"]) }
            if let groups = parameters["groups"], let missing = groups.split(separator: ",").first(where: { name in !access.groups.contains { $0.id == name } }) {
                return failure(500, "create user failed: no such group '\(missing)'")
            }
            var values = ["realm-type": realm, "enable": parameters["enable"] ?? "1"]
            for key in ["firstname", "lastname", "email", "comment", "groups", "expire"] { if let value = parameters[key] { values[key] = value } }
            access.users.append(.init(id: id, values: values))
            return success(nil)
        case (.put, let path) where path.count == 2 && path[0] == "users":
            guard let index = access.users.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "no such user ('\(path[1])')") }
            for key in ["firstname", "lastname", "email", "comment", "groups", "expire", "enable"] {
                if let value = parameters[key] { access.users[index].values[key] = value }
            }
            return success(nil)
        case (.delete, let path) where path.count == 2 && path[0] == "users":
            guard path[1] != "root@pam" else { return failure(500, "deleting user 'root@pam' is not allowed") }
            guard let index = access.users.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "no such user ('\(path[1])')") }
            access.users.remove(at: index)
            access.acl.removeAll { $0.id == path[1] || $0.id.hasPrefix(path[1] + "!") }
            return success(nil)
        case (.get, let path) where path.count == 3 && path[0] == "users" && path[2] == "token":
            guard let found = access.users.first(where: { $0.id == path[1] }) else { return failure(500, "no such user ('\(path[1])')") }
            return success(.array(found.tokens.map(tokenJSON)))
        case (.post, let path) where path.count == 4 && path[0] == "users" && path[2] == "token":
            guard let index = access.users.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "no such user ('\(path[1])')") }
            guard !access.users[index].tokens.contains(where: { $0.id == path[3] }) else { return failure(500, "Token already exists.") }
            access.users[index].tokens.append((id: path[3], comment: parameters["comment"] ?? "", separated: parameters["privsep"] != "0",
                                               expire: Int(parameters["expire"] ?? "") ?? 0))
            return success([
                "full-tokenid": .string("\(path[1])!\(path[3])"), "value": .string(UUID().uuidString.lowercased()),
                "info": ["privsep": .int(parameters["privsep"] == "0" ? 0 : 1)],
            ])
        case (.delete, let path) where path.count == 4 && path[0] == "users" && path[2] == "token":
            guard let index = access.users.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "no such user ('\(path[1])')") }
            access.users[index].tokens.removeAll { $0.id == path[3] }
            access.acl.removeAll { $0.id == "\(path[1])!\(path[3])" }
            return success(nil)
        case (.put, ["password"]):
            guard let target = parameters["userid"], access.users.contains(where: { $0.id == target }) else { return failure(500, "no such user") }
            guard (parameters["password"] ?? "").count >= 5 else { return fieldFailure(["password": "value must be at least 5 characters long"]) }
            // As on a real server: only root@pam skips the confirmation, and a wrong one is not a 401.
            if user != "root@pam" {
                guard let confirmation = parameters["confirmation-password"], !confirmation.isEmpty else {
                    return fieldFailure(["confirmation-password": "password is required to modify user"])
                }
                guard confirmation == "demo" else { return failure(500, "invalid credentials") }
            }
            return success(nil)
        case (.get, ["groups"]):
            return success(.array(access.groups.map { group in
                let members = access.users.filter { ($0.values["groups"] ?? "").split(separator: ",").contains(Substring(group.id)) }.map(\.id)
                return ["groupid": .string(group.id), "comment": .string(group.comment), "users": .string(members.joined(separator: ","))]
            }))
        case (.post, ["groups"]):
            guard let id = parameters["groupid"], !id.isEmpty else { return fieldFailure(["groupid": "property is missing and it is not optional"]) }
            guard !access.groups.contains(where: { $0.id == id }) else { return failure(500, "create group failed: group '\(id)' already exists") }
            access.groups.append((id: id, comment: parameters["comment"] ?? ""))
            return success(nil)
        case (.put, let path) where path.count == 2 && path[0] == "groups":
            guard let index = access.groups.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "group '\(path[1])' does not exist") }
            access.groups[index].comment = parameters["comment"] ?? ""
            return success(nil)
        case (.delete, let path) where path.count == 2 && path[0] == "groups":
            access.groups.removeAll { $0.id == path[1] }
            access.acl.removeAll { $0.type == "group" && $0.id == path[1] }
            for index in access.users.indices {
                let groups = (access.users[index].values["groups"] ?? "").split(separator: ",").filter { $0 != path[1] }
                access.users[index].values["groups"] = groups.joined(separator: ",")
            }
            return success(nil)
        case (.get, ["roles"]):
            return success(.array(access.roles.map { ["roleid": .string($0.id), "privs": .string($0.privileges.joined(separator: ",")), "special": .int($0.builtIn ? 1 : 0)] }))
        case (.post, ["roles"]):
            guard let id = parameters["roleid"], !id.isEmpty else { return fieldFailure(["roleid": "property is missing and it is not optional"]) }
            guard !access.roles.contains(where: { $0.id == id }) else { return failure(500, "role '\(id)' already exists") }
            access.roles.append((id: id, privileges: (parameters["privs"] ?? "").split(separator: ",").map(String.init), builtIn: false))
            return success(nil)
        case (.put, let path) where path.count == 2 && path[0] == "roles":
            guard let index = access.roles.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "role '\(path[1])' does not exist") }
            guard !access.roles[index].builtIn else { return failure(500, "cannot modify predefined role '\(path[1])'") }
            access.roles[index].privileges = (parameters["privs"] ?? "").split(separator: ",").map(String.init)
            return success(nil)
        case (.delete, let path) where path.count == 2 && path[0] == "roles":
            guard let index = access.roles.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "role '\(path[1])' does not exist") }
            guard !access.roles[index].builtIn else { return failure(500, "cannot delete predefined role '\(path[1])'") }
            access.roles.remove(at: index)
            access.acl.removeAll { $0.role == path[1] }
            return success(nil)
        case (.get, ["acl"]):
            return success(.array(access.acl.map { entry in
                ["path": .string(entry.path), "type": .string(entry.type), "ugid": .string(entry.id), "roleid": .string(entry.role), "propagate": .int(entry.propagate ? 1 : 0)]
            }))
        case (.put, ["acl"]):
            guard let path = parameters["path"], path.hasPrefix("/") else { return fieldFailure(["path": "invalid ACL path"]) }
            let roles = (parameters["roles"] ?? "").split(separator: ",").map(String.init)
            if let missing = roles.first(where: { role in !access.roles.contains { $0.id == role } }) { return failure(500, "role '\(missing)' does not exist") }
            var subjects: [(type: String, id: String)] = []
            for (key, type) in [("users", "user"), ("groups", "group"), ("tokens", "token")] {
                subjects += (parameters[key] ?? "").split(separator: ",").map { (type: type, id: String($0)) }
            }
            for subject in subjects {
                for role in roles {
                    access.acl.removeAll { $0.path == path && $0.type == subject.type && $0.id == subject.id && $0.role == role }
                    if parameters["delete"] != "1" {
                        access.acl.append((path: path, type: subject.type, id: subject.id, role: role, propagate: parameters["propagate"] != "0"))
                    }
                }
            }
            return success(nil)
        default:
            return nil
        }
    }

    private func userJSON(_ user: DemoAccess.User, list: Bool) -> JSONValue {
        var object: [String: JSONValue] = ["userid": .string(user.id)]
        for (key, value) in user.values {
            switch key {
            case "enable": object[key] = .int(value == "1" ? 1 : 0)
            case "expire": object[key] = .int(Int(value) ?? 0)
            case "groups": object[key] = list ? .string(value) : .array(value.split(separator: ",").map { .string(String($0)) })
            default: object[key] = .string(value)
            }
        }
        if object["expire"] == nil { object["expire"] = 0 }
        object["tokens"] = .array(user.tokens.map(tokenJSON))
        return .object(object)
    }

    private func tokenJSON(_ token: (id: String, comment: String, separated: Bool, expire: Int)) -> JSONValue {
        ["tokenid": .string(token.id), "comment": .string(token.comment), "privsep": .int(token.separated ? 1 : 0), "expire": .int(token.expire)]
    }
}
