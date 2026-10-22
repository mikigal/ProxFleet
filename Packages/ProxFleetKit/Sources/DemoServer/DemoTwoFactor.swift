import Foundation
import ProxmoxCore

/// A second factor in demo mode.
struct DemoTwoFactor: Sendable {
    var id: String
    var type: String
    var description: String
    var created: Int
    var isEnabled = true
}

/// A realm in demo mode, with its settings as the API names them.
struct DemoRealm: Sendable {
    var id: String
    var type: String
    var values: [String: String]
}

extension DemoAccess {
    static let sampleTwoFactors: [String: [DemoTwoFactor]] = [
        "root@pam": [DemoTwoFactor(id: "webauthn-1", type: "webauthn", description: "MacBook Touch ID", created: 1_780_000_000)],
        "anna@pve": [
            DemoTwoFactor(id: "totp-1", type: "totp", description: "iPhone", created: 1_785_000_000),
            DemoTwoFactor(id: "recovery", type: "recovery", description: "", created: 1_785_000_100),
        ],
        "auditor@pve": [DemoTwoFactor(id: "totp-2", type: "totp", description: "Authenticator", created: 1_786_000_000)],
    ]

    static let sampleRealms: [DemoRealm] = [
        DemoRealm(id: "pam", type: "pam", values: ["comment": "Linux PAM standard authentication"]),
        DemoRealm(id: "pve", type: "pve", values: ["comment": "Proxmox VE authentication server", "default": "1"]),
        DemoRealm(id: "corp", type: "ad", values: [
            "comment": "Company directory", "domain": "corp.example.com", "server1": "dc1.corp.example.com", "server2": "dc2.corp.example.com",
            "mode": "ldaps", "verify": "1", "bind_dn": "CN=proxmox,OU=Service,DC=corp,DC=example,DC=com", "sync_attributes": "email=mail",
            "sync-defaults-options": "scope=both,remove-vanished=acl;entry",
        ]),
        DemoRealm(id: "sso", type: "openid", values: [
            "comment": "Keycloak", "issuer-url": "https://auth.example.com/realms/main", "client-id": "proxmox", "username-claim": "email",
            "autocreate": "1", "scopes": "email profile",
        ]),
    ]
}

extension DemoState {
    /// `GET /access/domains`, which works without signing in.
    func realmList() -> HTTPResponse {
        success(.array(access.realms.map { realm in
            var object: [String: JSONValue] = ["realm": .string(realm.id), "type": .string(realm.type)]
            if let comment = realm.values["comment"] { object["comment"] = .string(comment) }
            if realm.values["default"] == "1" { object["default"] = 1 }
            if let tfa = realm.values["tfa"] { object["tfa"] = .string(String(tfa.split(separator: ",").first?.split(separator: "=").last ?? "")) }
            return .object(object)
        }))
    }

    /// Second factors and realm settings. nil for other paths.
    func handleTwoFactorAndRealms(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard parts.first == "access", parts.count >= 2 else { return nil }
        let canModifyUsers = privileges(for: user).contains("User.Modify")
        switch (method, Array(parts.dropFirst())) {
        case (.get, ["tfa"]):
            let visible = Set(access.twoFactors.keys).union(access.lockedTOTP).filter { canModifyUsers || $0 == user }
            return success(.array(visible.sorted().map { userid in
                var object: [String: JSONValue] = ["userid": .string(userid), "entries": .array((access.twoFactors[userid] ?? []).map(twoFactorJSON))]
                if access.lockedTOTP.contains(userid) { object["totp-locked"] = 1 }
                return .object(object)
            }))
        case (.post, let path) where path.count == 2 && path[0] == "tfa":
            let userid = path[1]
            if let refusal = refuseTwoFactorChange(of: userid, by: user, parameters: parameters) { return refusal }
            let now = Int(Date().timeIntervalSince1970)
            switch parameters["type"] {
            case "totp":
                // Demo mode cannot check the app's code, only its shape.
                guard let value = parameters["value"], value.count == 6, value.allSatisfy(\.isNumber) else {
                    return fieldFailure(["value": "failed to verify TOTP challenge"])
                }
                guard parameters["totp"]?.hasPrefix("otpauth://totp/") == true else { return fieldFailure(["totp": "invalid TOTP uri"]) }
                let id = "totp-\(now)"
                access.twoFactors[userid, default: []].append(DemoTwoFactor(id: id, type: "totp", description: parameters["description"] ?? "", created: now))
                return success(["id": .string(id)])
            case "recovery":
                guard !(access.twoFactors[userid] ?? []).contains(where: { $0.type == "recovery" }) else {
                    return failure(500, "user already has recovery keys")
                }
                access.twoFactors[userid, default: []].append(DemoTwoFactor(id: "recovery", type: "recovery", description: "", created: now))
                let keys = (0..<10).map { _ in (0..<4).map { _ in String(format: "%04x", Int.random(in: 0...0xFFFF)) }.joined(separator: "-") }
                return success(["id": "recovery", "recovery": .array(keys.map { .string($0) })])
            default:
                return failure(500, "adding \(parameters["type"] ?? "this kind of second factor") is not available in demo mode")
            }
        case (.put, let path) where path.count == 3 && path[0] == "tfa":
            if let refusal = refuseTwoFactorChange(of: path[1], by: user, parameters: parameters) { return refusal }
            guard let index = access.twoFactors[path[1]]?.firstIndex(where: { $0.id == path[2] }) else { return failure(500, "no such entry") }
            if let description = parameters["description"] { access.twoFactors[path[1]]?[index].description = description }
            if let enable = parameters["enable"] { access.twoFactors[path[1]]?[index].isEnabled = enable == "1" }
            return success(nil)
        case (.delete, let path) where path.count == 3 && path[0] == "tfa":
            if let refusal = refuseTwoFactorChange(of: path[1], by: user, parameters: parameters) { return refusal }
            guard access.twoFactors[path[1]]?.contains(where: { $0.id == path[2] }) == true else { return failure(500, "no such entry") }
            access.twoFactors[path[1]]?.removeAll { $0.id == path[2] }
            if access.twoFactors[path[1]]?.isEmpty == true { access.twoFactors[path[1]] = nil }
            return success(nil)
        case (.put, let path) where path.count == 3 && path[0] == "users" && path[2] == "unlock-tfa":
            guard canModifyUsers else { return failure(403, "Permission check failed (/access, User.Modify)") }
            access.lockedTOTP.remove(path[1])
            return success(1)
        case (.get, let path) where path.count == 2 && path[0] == "domains":
            guard let realm = access.realms.first(where: { $0.id == path[1] }) else { return failure(500, "domain '\(path[1])' does not exist") }
            var object: [String: JSONValue] = ["type": .string(realm.type), "digest": .string(String(realm.values.description.hashValue, radix: 16))]
            for (key, value) in realm.values where key != "password" { object[key] = .string(value) }
            return success(.object(object))
        case (.post, ["domains"]):
            guard privileges(for: user).contains("Realm.Allocate") else { return failure(403, "Permission check failed (/access/realm, Realm.Allocate)") }
            guard let id = parameters["realm"], id.count >= 2 else { return fieldFailure(["realm": "value does not match the regex pattern"]) }
            guard !access.realms.contains(where: { $0.id == id }) else { return failure(500, "domain '\(id)' already exists") }
            guard let type = parameters["type"], ["ldap", "ad", "openid"].contains(type) else { return fieldFailure(["type": "value is not a valid realm type"]) }
            var values = parameters
            values["realm"] = nil
            values["type"] = nil
            values["check-connection"] = nil
            if values["default"] == "1" { clearDefaultRealm() }
            access.realms.append(DemoRealm(id: id, type: type, values: values))
            return success(nil)
        case (.put, let path) where path.count == 2 && path[0] == "domains":
            guard privileges(for: user).contains("Realm.Allocate") else { return failure(403, "Permission check failed (/access/realm, Realm.Allocate)") }
            guard let index = access.realms.firstIndex(where: { $0.id == path[1] }) else { return failure(500, "domain '\(path[1])' does not exist") }
            if parameters["check-connection"] == "1", access.realms[index].type != "openid" {
                return failure(500, "Could not connect to \(access.realms[index].values["server1"] ?? "the server") in demo mode")
            }
            if parameters["default"] == "1" { clearDefaultRealm() }
            for key in (parameters["delete"] ?? "").split(separator: ",") { access.realms[index].values[String(key)] = nil }
            for (key, value) in parameters where !["delete", "digest", "check-connection"].contains(key) {
                access.realms[index].values[key] = value
            }
            return success(nil)
        case (.delete, let path) where path.count == 2 && path[0] == "domains":
            guard privileges(for: user).contains("Realm.Allocate") else { return failure(403, "Permission check failed (/access/realm, Realm.Allocate)") }
            guard let realm = access.realms.first(where: { $0.id == path[1] }) else { return failure(500, "domain '\(path[1])' does not exist") }
            guard !["pam", "pve"].contains(realm.type) else { return failure(500, "can't delete \(realm.type) realm") }
            access.realms.removeAll { $0.id == path[1] }
            return success(nil)
        case (.post, let path) where path.count == 3 && path[0] == "domains" && path[2] == "sync":
            guard let realm = access.realms.first(where: { $0.id == path[1] }), ["ldap", "ad"].contains(realm.type) else {
                return failure(500, "realm '\(path[1])' cannot be synced")
            }
            let scope = parameters["scope"] ?? "both"
            if parameters["dry-run"] != "1" {
                if scope != "groups" {
                    for name in ["j.smith", "m.nowak"] where !access.users.contains(where: { $0.id == "\(name)@\(realm.id)" }) {
                        access.users.append(.init(id: "\(name)@\(realm.id)", values: ["realm-type": realm.type, "enable": parameters["enable-new"] == "0" ? "0" : "1"]))
                    }
                }
                if scope != "users", !access.groups.contains(where: { $0.id == "staff-\(realm.id)" }) {
                    access.groups.append((id: "staff-\(realm.id)", comment: ""))
                }
            }
            let node = cluster.nodes.first(where: \.isOnline)?.name ?? "pve1"
            return startTask(node: node, type: "auth-realm-sync", objectID: realm.id, user: user, duration: 2)
        default:
            return nil
        }
    }

    /// `/cluster/jobs/realm-sync`. nil for other paths.
    func handleRealmSyncJobs(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard parts.count >= 3, parts[0] == "cluster", parts[1] == "jobs", parts[2] == "realm-sync" else { return nil }
        let keys: Set<String> = ["realm", "schedule", "enabled", "comment", "scope", "enable-new", "remove-vanished"]
        if method != .get, !privileges(for: user).contains("Realm.AllocateUser") {
            return failure(403, "Permission check failed (/access/realm, Realm.AllocateUser)")
        }
        switch (method, Array(parts.dropFirst(3))) {
        case (.get, []):
            return success(.array(access.realmSyncJobs.map { job in
                var object: [String: JSONValue] = ["id": .string(job.id)]
                for (key, value) in job.values { object[key] = key == "enabled" || key == "enable-new" ? .int(Int(value) ?? 1) : .string(value) }
                if job.values["enabled"] != "0", let next = Self.nextRuns(of: job.values["schedule"] ?? "", count: 1)?.first {
                    object["next-run"] = .int(Int(next.timeIntervalSince1970))
                }
                return .object(object)
            }))
        case (.post, let path) where path.count == 1:
            guard !access.realmSyncJobs.contains(where: { $0.id == path[0] }) else { return failure(500, "Job '\(path[0])' already exists") }
            guard let realm = access.realms.first(where: { $0.id == parameters["realm"] }), ["ldap", "ad"].contains(realm.type) else {
                return fieldFailure(["realm": "realm '\(parameters["realm"] ?? "")' is not an LDAP or AD realm"])
            }
            guard let schedule = parameters["schedule"], Self.nextRuns(of: schedule, count: 1) != nil else { return fieldFailure(["schedule": "value does not look like a valid calendar event"]) }
            access.realmSyncJobs.append((id: path[0], values: parameters.filter { keys.contains($0.key) }))
            return success(nil)
        case (.put, let path) where path.count == 1:
            guard let index = access.realmSyncJobs.firstIndex(where: { $0.id == path[0] }) else { return failure(500, "no such realm-sync job") }
            guard parameters["schedule"] != nil else { return fieldFailure(["schedule": "property is missing and it is not optional"]) }
            if let schedule = parameters["schedule"], Self.nextRuns(of: schedule, count: 1) == nil { return fieldFailure(["schedule": "value does not look like a valid calendar event"]) }
            for key in (parameters["delete"] ?? "").split(separator: ",") { access.realmSyncJobs[index].values[String(key)] = nil }
            for (key, value) in parameters where keys.contains(key) && key != "realm" { access.realmSyncJobs[index].values[key] = value }
            return success(nil)
        case (.delete, let path) where path.count == 1:
            access.realmSyncJobs.removeAll { $0.id == path[0] }
            return success(nil)
        default:
            return nil
        }
    }

    /// Everyone may change their own second factors; others need User.Modify. Like a real server, everyone but
    /// root@pam confirms with their password, which is `demo` here.
    private func refuseTwoFactorChange(of userid: String, by user: String, parameters: [String: String]) -> HTTPResponse? {
        guard userid == user || privileges(for: user).contains("User.Modify") else {
            return failure(403, "Permission check failed (/access/groups, User.Modify)")
        }
        guard access.users.contains(where: { $0.id == userid }) else { return failure(500, "no such user ('\(userid)')") }
        if user != "root@pam" {
            guard let password = parameters["password"], !password.isEmpty else { return fieldFailure(["password": "password is required to modify TFA data"]) }
            guard password == "demo" else { return failure(500, "invalid credentials") }
        }
        return nil
    }

    private func clearDefaultRealm() {
        for index in access.realms.indices { access.realms[index].values["default"] = nil }
    }

    private func twoFactorJSON(_ entry: DemoTwoFactor) -> JSONValue {
        ["id": .string(entry.id), "type": .string(entry.type), "description": .string(entry.description), "created": .int(entry.created),
         "enable": .int(entry.isEnabled ? 1 : 0)]
    }
}
