import Foundation
import ProxmoxCore

/// Users, tokens, second factors, realms, notifications, traffic control, metric servers, S3 endpoints and encryption
/// keys of the demo backup server. Configuration objects reuse the notification entry: a name, a type, values and
/// list settings.
struct DemoBackupServerConfigState: Sendable {
    typealias Entry = DemoNotifications.Entry

    var users: [Entry] = [
        Entry(name: "root@pam", type: "user", values: ["email": "admin@home.arpa"], lists: [:]),
        Entry(name: "backup@pbs", type: "user", values: ["comment": "Proxmox VE cluster homelab"], lists: [:]),
        Entry(name: "anna@pbs", type: "user", values: ["firstname": "Anna", "comment": "Laptop backups"], lists: [:]),
        Entry(name: "monitoring@pbs", type: "user", values: [:], lists: [:]),
    ]
    /// Tokens by their full ID.
    var tokens: [Entry] = [
        Entry(name: "backup@pbs!pve", type: "token", values: ["comment": "Storage pbs"], lists: [:]),
        Entry(name: "monitoring@pbs!zabbix", type: "token", values: [:], lists: [:]),
    ]
    /// The WebAuthn settings, empty until set like on a new server.
    var webAuthn: [String: String] = [:]
    var twoFactors: [String: [DemoTwoFactor]] = ["root@pam": [DemoTwoFactor(id: "totp-1750000000", type: "totp", description: "Phone", created: 1_750_000_000)]]
    var realms: [Entry] = [
        Entry(name: "pam", type: "pam", values: ["comment": "Linux PAM standard authentication", "default": "1"], lists: [:]),
        Entry(name: "pbs", type: "pbs", values: ["comment": "Proxmox Backup authentication server"], lists: [:]),
        Entry(name: "home", type: "ldap", values: [
            "comment": "Home directory", "server1": "ldap.home.arpa", "base-dn": "dc=home,dc=arpa", "user-attr": "uid", "mode": "ldaps", "verify": "1",
        ], lists: [:]),
    ]
    var notifications = DemoNotifications(
        endpoints: [
            Entry(name: "mail-to-root", type: "sendmail", values: ["comment": "Send mails to root@pam's email address"],
                  lists: ["mailto-user": ["root@pam"]], origin: "builtin"),
            Entry(name: "phone", type: "gotify", values: ["server": "https://gotify.home.arpa", "comment": "Alerts on the phone"], lists: [:]),
        ],
        matchers: [
            Entry(name: "default-matcher", type: "matcher", values: ["mode": "all", "comment": "Route all notifications to mail-to-root"],
                  lists: ["target": ["mail-to-root"]], origin: "builtin"),
            Entry(name: "failed-jobs", type: "matcher", values: ["mode": "all", "comment": "Failed jobs to the phone"],
                  lists: ["target": ["phone"], "match-severity": ["error"]]),
        ],
        options: [:]
    )
    var trafficRules: [Entry] = [
        Entry(name: "office-hours", type: "traffic", values: ["comment": "Leave bandwidth during work hours", "rate-in": "50 MiB", "rate-out": "100 MiB"],
              lists: ["network": ["0.0.0.0/0", "::/0"], "timeframe": ["mon..fri 8:00-18:00"]]),
    ]
    var metricServers: [Entry] = [
        Entry(name: "grafana", type: "influxdb-http", values: ["url": "https://influx.home.arpa:8086", "organization": "home", "bucket": "pbs"], lists: [:]),
    ]
    var s3Endpoints: [Entry] = [
        Entry(name: "minio", type: "s3", values: ["endpoint": "minio.home.arpa", "port": "9000", "region": "us-east-1", "access-key": "pbs", "path-style": "1"], lists: [:]),
    ]
    var encryptionKeys: [Entry] = [
        Entry(name: "cloud-2026", type: "key", values: [
            "fingerprint": "a3:5e:21:9c:0f:77:b4:d2:18:6a:e9:40:c3:5b:72:8d:01:f6:2e:94:bb:37:c8:5a:e0:19:4d:73:a2:6f:08:c1",
            "created": "1761300000", "hint": "Password manager",
        ], lists: [:]),
        Entry(name: "cloud-2025", type: "key", values: [
            "fingerprint": "7d:02:b8:4e:91:c5:3a:6f:e2:18:d0:7b:45:9c:a1:e3:66:0f:2d:b7:58:c4:19:8a:f3:20:5e:d6:7c:41:9b:02",
            "created": "1729700000", "archived-at": "1761300000",
        ], lists: [:]),
    ]
}

extension DemoBackupServerState {
    private static let numberKeys: Set<String> = ["port", "expire", "mtu", "max-body-size", "put-rate-limit", "created", "archived-at"]
    private static let flagKeys: Set<String> = ["enable", "default", "verify", "path-style", "autocreate", "verify-tls", "disable"]

    private static func entryJSON(_ entry: DemoBackupServerConfigState.Entry, nameKey: String = "name") -> JSONValue {
        var object: [String: JSONValue] = [nameKey: .string(entry.name)]
        for (key, value) in entry.values {
            if numberKeys.contains(key), let number = Int(value) {
                object[key] = .int(number)
            } else if flagKeys.contains(key) {
                object[key] = .bool(value == "1" || value == "true")
            } else {
                object[key] = .string(value)
            }
        }
        for (key, list) in entry.lists { object[key] = .array(list.map { .string($0) }) }
        return .object(object)
    }

    /// Applies set and deleted settings; list settings come as repeated parameters.
    private static func apply(_ parameters: [String: String], to entry: inout DemoBackupServerConfigState.Entry, lists: Set<String> = [],
                              ignoring: Set<String> = []) {
        for key in (parameters["delete"] ?? "").components(separatedBy: DemoState.listSeparator) where !key.isEmpty {
            entry.values[key] = nil
            entry.lists[key] = nil
        }
        for (key, value) in parameters where !["delete", "digest"].contains(key) && !ignoring.contains(key) {
            if lists.contains(key) {
                entry.lists[key] = value.components(separatedBy: DemoState.listSeparator).filter { !$0.isEmpty }
            } else {
                entry.values[key] = value
            }
        }
    }

    /// The realms for the login screen, which asks before signing in.
    func realmListJSON() -> JSONValue {
        .array(config.realms.map { realm in
            var object: [String: JSONValue] = ["realm": .string(realm.name), "type": .string(realm.type)]
            if let comment = realm.values["comment"] { object["comment"] = .string(comment) }
            if realm.values["default"] == "1" { object["default"] = true }
            return .object(object)
        })
    }

    /// Routes for users, tokens, second factors, realms, notifications, traffic control, metric servers, S3 endpoints and
    /// encryption keys. nil for other paths.
    func handleConfiguration(_ method: HTTPMethod, parts: [String], parameters: [String: String]) -> HTTPResponse? {
        switch parts.first {
        case "access": return handleUsers(method, rest: Array(parts.dropFirst()), parameters: parameters)
        case "config": return handleSettings(method, rest: Array(parts.dropFirst()), parameters: parameters)
        case "admin" where parts == ["admin", "metrics"]:
            return digested(.array(config.metricServers.map { server in
                var object: [String: JSONValue] = ["name": .string(server.name), "type": .string(server.type),
                                                   "server": .string(server.values["url"] ?? server.values["host"] ?? ""),
                                                   "enable": .bool(server.values["enable"] != "0")]
                if let comment = server.values["comment"] { object["comment"] = .string(comment) }
                return .object(object)
            }))
        case "admin" where parts == ["admin", "traffic-control"]:
            return success(.array(config.trafficRules.enumerated().map { index, rule in
                guard case .object(var object) = Self.entryJSON(rule) else { return .null }
                // Some traffic during the day, as the office's clients back up.
                object["cur-rate-in"] = .int(index == 0 ? 3_407_872 : 0)
                object["cur-rate-out"] = .int(index == 0 ? 524_288 : 0)
                return .object(object)
            }))
        default: return nil
        }
    }

    // MARK: - Users, tokens and second factors

    private func handleUsers(_ method: HTTPMethod, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        switch (method, rest) {
        case (.get, ["users"]):
            if parameters["full"] != nil { return fieldFailure(["full": "schema does not allow additional properties"]) }
            let withTokens = parameters["include_tokens"] == "1"
            return digested(.array(config.users.map { user in
                guard case .object(var object) = Self.entryJSON(user, nameKey: "userid") else { return .null }
                if object["enable"] == nil { object["enable"] = true }
                if withTokens {
                    object["tokens"] = .array(config.tokens.filter { $0.name.hasPrefix(user.name + "!") }.map { token in
                        guard case .object(var tokenObject) = Self.entryJSON(token, nameKey: "tokenid") else { return .null }
                        if tokenObject["enable"] == nil { tokenObject["enable"] = true }
                        return .object(tokenObject)
                    })
                }
                return .object(object)
            }))
        case (.post, ["users"]):
            guard let userID = parameters["userid"], let at = userID.firstIndex(of: "@"), at != userID.startIndex else {
                return fieldFailure(["userid": "value does not match the regex pattern"])
            }
            let realm = String(userID[userID.index(after: at)...])
            guard config.realms.contains(where: { $0.name == realm }) else { return failure(400, "unknown realm '\(realm)'") }
            guard !config.users.contains(where: { $0.name == userID }) else { return failure(400, "user '\(userID)' already exists.") }
            if let password = parameters["password"], password.count < 8 { return fieldFailure(["password": "value must be at least 8 characters long"]) }
            var user = DemoBackupServerConfigState.Entry(name: userID, type: "user", values: [:], lists: [:])
            Self.apply(parameters, to: &user, ignoring: ["userid", "password"])
            config.users.append(user)
            return success(nil)
        case (.put, let path) where path.count == 2 && path[0] == "users":
            guard let index = config.users.firstIndex(where: { $0.name == path[1] }) else { return failure(400, "user '\(path[1])' does not exist.") }
            Self.apply(parameters, to: &config.users[index], ignoring: ["userid", "password"])
            return success(nil)
        case (.delete, let path) where path.count == 2 && path[0] == "users":
            guard path[1] != "root@pam" else { return failure(400, "cannot delete root@pam") }
            guard config.users.contains(where: { $0.name == path[1] }) else { return failure(400, "user '\(path[1])' does not exist.") }
            config.users.removeAll { $0.name == path[1] }
            config.tokens.removeAll { $0.name.hasPrefix(path[1] + "!") }
            acl.removeAll { $0.authID == path[1] || $0.authID.hasPrefix(path[1] + "!") }
            return success(nil)
        case (.put, ["password"]):
            guard let password = parameters["password"], password.count >= 8 else {
                return fieldFailure(["password": "value must be at least 8 characters long"])
            }
            guard config.users.contains(where: { $0.name == parameters["userid"] }) else { return failure(400, "user does not exist") }
            return success(nil)
        case (.post, let path) where path.count == 4 && path[0] == "users" && path[2] == "token":
            let id = "\(path[1])!\(path[3])"
            guard !config.tokens.contains(where: { $0.name == id }) else { return failure(400, "token '\(id)' already exists.") }
            var token = DemoBackupServerConfigState.Entry(name: id, type: "token", values: [:], lists: [:])
            Self.apply(parameters, to: &token, ignoring: ["userid", "token-name"])
            config.tokens.append(token)
            return success(["tokenid": .string(id), "value": .string(UUID().uuidString.lowercased())])
        case (.put, let path) where path.count == 4 && path[0] == "users" && path[2] == "token":
            guard let index = config.tokens.firstIndex(where: { $0.name == "\(path[1])!\(path[3])" }) else { return failure(400, "no such token") }
            if parameters["regenerate"] == "1" {
                return success(["secret": .string(UUID().uuidString.lowercased())])
            }
            Self.apply(parameters, to: &config.tokens[index], ignoring: ["userid", "token-name"])
            return success(nil)
        case (.delete, let path) where path.count == 4 && path[0] == "users" && path[2] == "token":
            let id = "\(path[1])!\(path[3])"
            guard config.tokens.contains(where: { $0.name == id }) else { return failure(400, "no such token") }
            config.tokens.removeAll { $0.name == id }
            acl.removeAll { $0.authID == id }
            return success(nil)
        case (.get, ["tfa"]):
            return success(.array(config.twoFactors.keys.sorted().map { userID in
                ["userid": .string(userID), "entries": .array((config.twoFactors[userID] ?? []).map { entry in
                    ["id": .string(entry.id), "type": .string(entry.type), "description": .string(entry.description), "created": .int(entry.created),
                     "enable": .bool(entry.isEnabled)]
                })]
            }))
        case (.post, let path) where path.count == 2 && path[0] == "tfa":
            let now = Int(Date().timeIntervalSince1970)
            switch parameters["type"] {
            case "totp":
                guard let value = parameters["value"], value.count == 6, value.allSatisfy(\.isNumber) else {
                    return fieldFailure(["value": "failed to verify TOTP challenge"])
                }
                let id = "totp-\(now)"
                config.twoFactors[path[1], default: []].append(DemoTwoFactor(id: id, type: "totp", description: parameters["description"] ?? "", created: now))
                return success(["id": .string(id)])
            case "recovery":
                guard !(config.twoFactors[path[1]] ?? []).contains(where: { $0.type == "recovery" }) else { return failure(400, "user already has recovery keys") }
                config.twoFactors[path[1], default: []].append(DemoTwoFactor(id: "recovery", type: "recovery", description: "", created: now))
                let keys = (0..<10).map { _ in (0..<4).map { _ in String(format: "%04x", Int.random(in: 0...0xFFFF)) }.joined(separator: "-") }
                return success(["id": "recovery", "recovery": .array(keys.map { .string($0) })])
            default:
                return failure(400, "adding \(parameters["type"] ?? "this kind of second factor") is not available in demo mode")
            }
        case (.put, let path) where path.count == 3 && path[0] == "tfa":
            guard let index = config.twoFactors[path[1]]?.firstIndex(where: { $0.id == path[2] }) else { return failure(400, "no such entry") }
            if let description = parameters["description"] { config.twoFactors[path[1]]?[index].description = description }
            if let enable = parameters["enable"] { config.twoFactors[path[1]]?[index].isEnabled = enable == "1" }
            return success(nil)
        case (.delete, let path) where path.count == 3 && path[0] == "tfa":
            guard config.twoFactors[path[1]]?.contains(where: { $0.id == path[2] }) == true else { return failure(400, "no such entry") }
            config.twoFactors[path[1]]?.removeAll { $0.id == path[2] }
            if config.twoFactors[path[1]]?.isEmpty == true { config.twoFactors[path[1]] = nil }
            return success(nil)
        case (.put, let path) where path.count == 3 && path[0] == "users" && path[2] == "unlock-tfa":
            return success(true)
        case (.post, let path) where path.count == 3 && path[0] == "domains" && path[2] == "sync":
            guard let realm = config.realms.first(where: { $0.name == path[1] }), ["ldap", "ad"].contains(realm.type) else {
                return failure(400, "realm '\(path[1])' cannot be synced")
            }
            if parameters["dry-run"] != "1", !config.users.contains(where: { $0.name == "maria@\(realm.name)" }) {
                config.users.append(DemoBackupServerConfigState.Entry(name: "maria@\(realm.name)", type: "user",
                                                                       values: ["firstname": "Maria", "email": "maria@home.arpa", "enable": parameters["enable-new"] == "0" ? "0" : "1"], lists: [:]))
            }
            return startTask("realm-sync", realm.name, duration: 2)
        default:
            return nil
        }
    }

    // MARK: - Settings

    private func handleSettings(_ method: HTTPMethod, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        switch rest.first {
        case "access": return handleRealms(method, rest: Array(rest.dropFirst()), parameters: parameters)
        case "notifications": return handleNotifications(method, rest: Array(rest.dropFirst()), parameters: parameters)
        case "traffic-control":
            return handleList(\.trafficRules, method: method, name: rest.count > 1 ? rest[1] : nil, type: "traffic", parameters: parameters,
                              lists: ["network", "users", "timeframe"], required: ["network"])
        case "metrics":
            if method == .get, rest.count == 1 {
                // Like the real server: only the types; `/admin/metrics` lists the servers.
                return success([["subdir": "influxdb-http"], ["subdir": "influxdb-udp"]])
            }
            guard rest.count >= 2, ["influxdb-http", "influxdb-udp"].contains(rest[1]) else { return nil }
            return handleList(\.metricServers, method: method, name: rest.count > 2 ? rest[2] : nil, type: rest[1], parameters: parameters,
                              required: [rest[1] == "influxdb-http" ? "url" : "host"], writeOnly: ["token"])
        case "s3":
            if method == .get, rest.count == 3, rest[2] == "list-buckets" {
                guard config.s3Endpoints.contains(where: { $0.name == rest[1] }) else { return failure(400, "no such endpoint") }
                return success([["name": "pbs-offsite"], ["name": "photos"]])
            }
            return handleList(\.s3Endpoints, method: method, name: rest.count > 1 ? rest[1] : nil, type: "s3", parameters: parameters,
                              lists: ["provider-quirks"], required: ["endpoint", "access-key", "secret-key"], writeOnly: ["secret-key"], nameKey: "id")
        case "encryption-keys":
            switch (method, rest.count) {
            case (.get, 1):
                let includeArchived = parameters["include-archived"] == "1"
                return digested(.array(config.encryptionKeys.filter { includeArchived || $0.values["archived-at"] == nil }.map { Self.entryJSON($0, nameKey: "id") }))
            case (.post, 1):
                guard let id = parameters["id"], id.count >= 3 else { return fieldFailure(["id": "value does not match the regex pattern"]) }
                guard !config.encryptionKeys.contains(where: { $0.name == id }) else { return failure(400, "key '\(id)' already exists") }
                let fingerprint = (0..<32).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined(separator: ":")
                config.encryptionKeys.append(DemoBackupServerConfigState.Entry(name: id, type: "key", values: [
                    "fingerprint": fingerprint, "created": String(Int(Date().timeIntervalSince1970)),
                ], lists: [:]))
                return success(nil)
            case (.post, 2):
                guard let index = config.encryptionKeys.firstIndex(where: { $0.name == rest[1] }) else { return failure(400, "no such key") }
                config.encryptionKeys[index].values["archived-at"] = String(Int(Date().timeIntervalSince1970))
                return success(nil)
            case (.delete, 2):
                guard config.encryptionKeys.contains(where: { $0.name == rest[1] }) else { return failure(400, "no such key") }
                if let job = jobs.first(where: { $0.settings["active-encryption-key"] == rest[1] || $0.lists["associated-key"]?.contains(rest[1]) == true }) {
                    return failure(400, "key '\(rest[1])' is in use by sync job '\(job.id)'")
                }
                config.encryptionKeys.removeAll { $0.name == rest[1] }
                return success(nil)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Create, read, update and delete for a list of configuration objects.
    private func handleList(_ list: WritableKeyPath<DemoBackupServerConfigState, [DemoBackupServerConfigState.Entry]>, method: HTTPMethod, name: String?,
                            type: String, parameters: [String: String], lists: Set<String> = [], required: [String] = [], writeOnly: Set<String> = [],
                            nameKey: String = "name") -> HTTPResponse? {
        func hidden(_ entry: DemoBackupServerConfigState.Entry) -> DemoBackupServerConfigState.Entry {
            var entry = entry
            for key in writeOnly { entry.values[key] = nil }
            return entry
        }
        switch (method, name) {
        case (.get, nil):
            return digested(.array(config[keyPath: list].filter { $0.type == type }.map { Self.entryJSON(hidden($0), nameKey: nameKey) }))
        case (.get, let name?):
            guard let entry = config[keyPath: list].first(where: { $0.name == name }) else { return failure(404, "'\(name)' does not exist") }
            return digested(Self.entryJSON(hidden(entry), nameKey: nameKey))
        case (.post, nil):
            guard let name = parameters[nameKey], name.count >= 3, name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\-]*/) != nil else {
                return fieldFailure([nameKey: "value does not match the regex pattern"])
            }
            guard !config[keyPath: list].contains(where: { $0.name == name }) else { return failure(400, "'\(name)' already exists") }
            if let missing = required.first(where: { parameters[$0] == nil }) {
                return fieldFailure([missing: "parameter is missing and it is not optional."])
            }
            var entry = DemoBackupServerConfigState.Entry(name: name, type: type, values: [:], lists: [:])
            Self.apply(parameters, to: &entry, lists: lists, ignoring: [nameKey])
            config[keyPath: list].append(entry)
            configRevision += 1
            return success(nil)
        case (.put, let name?):
            guard let index = config[keyPath: list].firstIndex(where: { $0.name == name }) else { return failure(404, "'\(name)' does not exist") }
            if let digest = parameters["digest"], digest != configDigest {
                return failure(400, "detected modified configuration - file changed by other user? Try again.")
            }
            Self.apply(parameters, to: &config[keyPath: list][index], lists: lists, ignoring: [nameKey])
            configRevision += 1
            return success(nil)
        case (.delete, let name?):
            guard config[keyPath: list].contains(where: { $0.name == name }) else { return failure(404, "'\(name)' does not exist") }
            config[keyPath: list].removeAll { $0.name == name }
            configRevision += 1
            return success(nil)
        default:
            return nil
        }
    }

    /// `/config/access/tfa/webauthn`: null until set; the ID and name cannot be removed again.
    private func webAuthn(_ method: HTTPMethod, parameters: [String: String]) -> HTTPResponse {
        switch method {
        case .get:
            guard !config.webAuthn.isEmpty else { return digested(nil) }
            var object = config.webAuthn.mapValues { JSONValue.string($0) }
            object["allow-subdomains"] = config.webAuthn["allow-subdomains"].map { .bool($0 != "0") }
            return digested(.object(object))
        case .put:
            if let digest = parameters["digest"], digest != configDigest {
                return failure(400, "detected modified configuration - file changed by other user? Try again.")
            }
            let deletions = (parameters["delete"] ?? "").components(separatedBy: DemoState.listSeparator).filter { !$0.isEmpty }
            if let refused = deletions.first(where: { !["origin", "allow-subdomains"].contains($0) }) {
                return fieldFailure(["delete": "value '\(refused)' is not defined in the enumeration."])
            }
            var updated = config.webAuthn
            for key in deletions { updated[key] = nil }
            for key in ["rp", "origin", "id", "allow-subdomains"] {
                if let value = parameters[key] { updated[key] = key == "allow-subdomains" ? (value == "1" || value == "true" ? "1" : "0") : value }
            }
            guard updated["rp"] != nil, updated["id"] != nil else { return failure(400, "missing 'rp' and 'id' for a new webauthn configuration") }
            if let origin = updated["origin"], !origin.hasPrefix("https://"), !origin.hasPrefix("http://localhost") {
                return fieldFailure(["origin": "origin must be an https:// URL"])
            }
            config.webAuthn = updated
            configRevision += 1
            return success(nil)
        default:
            return failure(501, "Method not allowed")
        }
    }

    private func handleRealms(_ method: HTTPMethod, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        if rest == ["tfa", "webauthn"] { return webAuthn(method, parameters: parameters) }
        guard let type = rest.first, ["pam", "pbs", "ldap", "ad", "openid"].contains(type) else { return nil }
        if type == "pam" || type == "pbs" {
            guard rest.count == 1, let index = config.realms.firstIndex(where: { $0.name == type }) else { return nil }
            switch method {
            case .get:
                return digested(Self.entryJSON(config.realms[index], nameKey: "realm"))
            case .put:
                if parameters["default"] == "1" { clearDefaultRealm() }
                Self.apply(parameters, to: &config.realms[index])
                return success(nil)
            default:
                return nil
            }
        }
        switch (method, rest.count) {
        case (.get, 1):
            return digested(.array(config.realms.filter { $0.type == type }.map { Self.entryJSON($0, nameKey: "realm") }))
        case (.post, 1):
            guard let name = parameters["realm"], name.count >= 2 else { return fieldFailure(["realm": "value does not match the regex pattern"]) }
            guard !config.realms.contains(where: { $0.name == name }) else { return failure(400, "realm '\(name)' already exists.") }
            let required = type == "openid" ? ["issuer-url", "client-id"] : type == "ldap" ? ["server1", "base-dn", "user-attr"] : ["server1"]
            if let missing = required.first(where: { parameters[$0] == nil }) {
                return fieldFailure([missing: "parameter is missing and it is not optional."])
            }
            if parameters["default"] == "1" { clearDefaultRealm() }
            var realm = DemoBackupServerConfigState.Entry(name: name, type: type, values: [:], lists: [:])
            Self.apply(parameters, to: &realm, ignoring: ["realm", "password", "client-key"])
            config.realms.append(realm)
            return success(nil)
        case (.get, 2):
            guard let realm = config.realms.first(where: { $0.name == rest[1] && $0.type == type }) else { return failure(400, "realm '\(rest[1])' does not exist.") }
            return digested(Self.entryJSON(realm, nameKey: "realm"))
        case (.put, 2):
            guard let index = config.realms.firstIndex(where: { $0.name == rest[1] && $0.type == type }) else { return failure(400, "realm '\(rest[1])' does not exist.") }
            if parameters["default"] == "1" { clearDefaultRealm() }
            Self.apply(parameters, to: &config.realms[index], ignoring: ["realm", "password", "client-key"])
            return success(nil)
        case (.delete, 2):
            guard config.realms.contains(where: { $0.name == rest[1] && $0.type == type }) else { return failure(400, "realm '\(rest[1])' does not exist.") }
            config.realms.removeAll { $0.name == rest[1] }
            return success(nil)
        default:
            return nil
        }
    }

    private func clearDefaultRealm() {
        for index in config.realms.indices { config.realms[index].values["default"] = nil }
    }

    private func handleNotifications(_ method: HTTPMethod, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        let listKeys: Set<String> = ["mailto", "mailto-user", "header", "secret", "target", "match-field", "match-severity", "match-calendar"]
        func update(_ list: WritableKeyPath<DemoNotifications, [DemoNotifications.Entry]>, name: String) -> HTTPResponse {
            guard let index = config.notifications[keyPath: list].firstIndex(where: { $0.name == name }) else { return failure(404, "'\(name)' does not exist") }
            var entry = config.notifications[keyPath: list][index]
            // The backup server takes each deletion as its own parameter; a comma-separated list is an unknown setting.
            if let deleted = parameters["delete"], deleted.contains(",") {
                return fieldFailure(["delete": "value '\(deleted)' is not defined in the enumeration."])
            }
            Self.apply(parameters, to: &entry, lists: listKeys, ignoring: ["name", "password", "token"])
            if entry.origin == "builtin" { entry.origin = "modified-builtin" }
            config.notifications[keyPath: list][index] = entry
            return success(nil)
        }
        func create(_ list: WritableKeyPath<DemoNotifications, [DemoNotifications.Entry]>, type: String) -> HTTPResponse {
            guard let name = parameters["name"], name.first?.isLetter == true else { return fieldFailure(["name": "invalid configuration ID"]) }
            guard !(config.notifications.endpoints + config.notifications.matchers).contains(where: { $0.name == name }) else {
                return failure(400, "name '\(name)' already exists")
            }
            var entry = DemoNotifications.Entry(name: name, type: type, values: [:], lists: [:])
            Self.apply(parameters, to: &entry, lists: listKeys, ignoring: ["name", "password", "token"])
            config.notifications[keyPath: list].append(entry)
            return success(nil)
        }
        switch (method, rest) {
        case (.get, ["targets"]):
            return success(.array(config.notifications.endpoints.map { entry in
                var object: [String: JSONValue] = ["name": .string(entry.name), "type": .string(entry.type), "origin": .string(entry.origin)]
                if let comment = entry.values["comment"] { object["comment"] = .string(comment) }
                if entry.values["disable"] == "1" { object["disable"] = true }
                return .object(object)
            }))
        case (.get, ["matchers"]):
            return success(.array(config.notifications.matchers.map { Self.entryJSON($0) }))
        case (.get, ["matcher-field-values"]):
            let values = ["gc", "prune", "verify", "sync", "acme", "package-updates", "system-mail"].map { ["field": "type", "value": JSONValue.string($0)] }
                + server.datastores.map { ["field": "datastore", "value": JSONValue.string($0.name)] }
                + [["field": "hostname", "value": .string(server.name)]]
            return success(.array(values.map { .object($0) }))
        case (.post, ["matchers"]):
            return create(\.matchers, type: "matcher")
        case (.put, let path) where path.count == 2 && path[0] == "matchers":
            return update(\.matchers, name: path[1])
        case (.delete, let path) where path.count == 2 && path[0] == "matchers":
            guard config.notifications.matchers.contains(where: { $0.name == path[1] && $0.origin == "user-created" }) else {
                return failure(400, "cannot delete built-in matcher")
            }
            config.notifications.matchers.removeAll { $0.name == path[1] }
            return success(nil)
        case (.get, let path) where path.count == 3 && path[0] == "endpoints":
            guard let entry = config.notifications.endpoints.first(where: { $0.name == path[2] && $0.type == path[1] }) else { return failure(404, "no such endpoint") }
            return success(Self.entryJSON(entry))
        case (.post, let path) where path.count == 2 && path[0] == "endpoints":
            return create(\.endpoints, type: path[1])
        case (.put, let path) where path.count == 3 && path[0] == "endpoints":
            return update(\.endpoints, name: path[2])
        case (.delete, let path) where path.count == 3 && path[0] == "endpoints":
            guard config.notifications.endpoints.contains(where: { $0.name == path[2] && $0.origin == "user-created" }) else {
                return failure(400, "cannot delete built-in target")
            }
            config.notifications.endpoints.removeAll { $0.name == path[2] }
            for index in config.notifications.matchers.indices {
                config.notifications.matchers[index].lists["target"]?.removeAll { $0 == path[2] }
            }
            return success(nil)
        case (.post, let path) where path.count == 3 && path[0] == "targets" && path[2] == "test":
            guard let entry = config.notifications.endpoints.first(where: { $0.name == path[1] }) else { return failure(404, "no such target") }
            if entry.type == "sendmail" { return success(nil) }
            return failure(400, "could not notify via target '\(entry.name)': demo mode does not reach \(entry.values["server"] ?? entry.values["url"] ?? "the network")")
        default:
            return nil
        }
    }
}
