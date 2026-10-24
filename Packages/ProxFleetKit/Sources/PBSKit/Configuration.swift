import Foundation
import ProxmoxCore
import PVEKit

private func text(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func isValidName(_ name: String, minimum: Int = 3) -> Bool {
    name.count >= minimum && name.count <= 32 && name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\-]*/) != nil
}

// MARK: - Users and tokens

/// A user of the backup server: name, contact, whether the account works and until when. The password is set on
/// creation and changed separately.
public struct BackupServerUserDraft: BackupServerDraft, Sendable {
    /// `name@realm`; fixed once created.
    public var userID = ""
    public var password = ""
    public var passwordConfirmation = ""
    public var comment = ""
    public var email = ""
    public var firstName = ""
    public var lastName = ""
    public var isEnabled = true
    public var expires: Date?

    public init() {}

    public init(_ user: BackupServerUser) {
        userID = user.id
        comment = user.comment ?? ""
        email = user.email ?? ""
        firstName = user.firstName ?? ""
        lastName = user.lastName ?? ""
        isEnabled = user.isEnabled
        expires = user.expires
    }

    public var realm: String { userID.split(separator: "@").last.map(String.init) ?? "" }

    public func serialized() -> [String: String?] {
        [
            "comment": text(comment), "email": text(email), "firstname": text(firstName), "lastname": text(lastName),
            // Both sent as values: the server's defaults (enabled, no expiry) are written explicitly.
            "enable": isEnabled ? "1" : "0", "expire": String(Int(expires?.timeIntervalSince1970 ?? 0)),
        ]
    }

    public var creationParameters: APIParameters {
        var parameters: APIParameters = ["userid": .string(userID.trimmingCharacters(in: .whitespaces))]
        if !password.isEmpty { parameters["password"] = .string(password) }
        for item in creationValues.items where !(item.name == "expire" && item.value == "0") && !(item.name == "enable" && item.value == "1") {
            parameters.append(item.name, item.value)
        }
        return parameters
    }

    public func problems(isNew: Bool, realms: [String]) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew {
            let parts = userID.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
            if parts.count != 2 || parts[0].isEmpty || parts[0].contains(where: { $0.isWhitespace || ":/".contains($0) }) {
                problems["userid"] = String(localized: "Enter the user as name@realm, e.g. backup@pbs.")
            } else if !realms.isEmpty, !realms.contains(String(parts[1])) {
                problems["userid"] = String(localized: "There is no realm \(String(parts[1])).")
            }
            if realm == "pbs", password.count < 8 {
                problems["password"] = String(localized: "Use at least 8 characters.")
            } else if realm == "pbs", password != passwordConfirmation {
                problems["password"] = String(localized: "The passwords do not match.")
            }
        }
        let email = email.trimmingCharacters(in: .whitespaces)
        if !email.isEmpty, email.wholeMatch(of: /[^\s@]+@[^\s@]+/) == nil {
            problems["email"] = String(localized: "Enter an email address.")
        }
        return problems
    }
}

/// `POST /access/users/{userid}/token/{name}`: the new token and its secret, which is shown only once.
public struct BackupServerCreatedToken: Decodable, Sendable, Equatable {
    public var tokenID: String
    public var secret: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        tokenID = container.lossyString(AnyCodingKey("tokenid")) ?? ""
        // Creation answers `value`, regenerating `secret`.
        secret = container.lossyString(AnyCodingKey("value")) ?? container.lossyString(AnyCodingKey("secret")) ?? ""
    }
}

public struct BackupServerTokenDraft: BackupServerDraft, Sendable {
    /// The part after `!`; fixed once created.
    public var name = ""
    public var comment = ""
    public var isEnabled = true
    public var expires: Date?

    public init() {}

    public init(_ token: BackupServerUser.Token) {
        name = String(token.id.split(separator: "!").last ?? "")
        comment = token.comment ?? ""
        isEnabled = token.isEnabled
        expires = token.expires
    }

    public func serialized() -> [String: String?] {
        ["comment": text(comment), "enable": isEnabled ? "1" : "0", "expire": String(Int(expires?.timeIntervalSince1970 ?? 0))]
    }

    public var problems: [String: String] {
        isValidName(name.trimmingCharacters(in: .whitespaces), minimum: 2)
            ? [:] : ["token-name": String(localized: "Use letters, digits, dots, dashes or underscores.")]
    }
}

extension PBS {
    public static func createUser(_ draft: BackupServerUserDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/access/users", parameters: draft.creationParameters)
    }

    public static func updateUser(_ userID: String, _ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/access/users/\(escapePath(userID))", parameters: update.parameters)
    }

    public static func deleteUser(_ userID: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/access/users/\(escapePath(userID))")
    }

    /// Sets a user's password; users other than root@pam confirm with their own current password.
    public static func changePassword(of userID: String, to password: String, confirmation: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["userid": .string(userID), "password": .string(password)]
        if let confirmation, !confirmation.isEmpty { parameters["confirmation-password"] = .string(confirmation) }
        return APIRequest(.put, "/access/password", parameters: parameters)
    }

    public static func createToken(of userID: String, _ draft: BackupServerTokenDraft) -> APIRequest<BackupServerCreatedToken> {
        var parameters = APIParameters()
        // The server's defaults need not be sent.
        for item in draft.creationValues.items where !(item.name == "enable" && item.value == "1") && !(item.name == "expire" && item.value == "0") {
            parameters.append(item.name, item.value)
        }
        return APIRequest(.post, "/access/users/\(escapePath(userID))/token/\(escapePath(draft.name.trimmingCharacters(in: .whitespaces)))", parameters: parameters)
    }

    public static func updateToken(of userID: String, name: String, _ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/access/users/\(escapePath(userID))/token/\(escapePath(name))", parameters: update.parameters)
    }

    /// A new secret for a token, keeping its permissions (3.4 and newer). The old secret stops working.
    public static func regenerateToken(of userID: String, name: String) -> APIRequest<BackupServerCreatedToken> {
        APIRequest(.put, "/access/users/\(escapePath(userID))/token/\(escapePath(name))", parameters: ["regenerate": true])
    }

    public static func deleteToken(of userID: String, name: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/access/users/\(escapePath(userID))/token/\(escapePath(name))")
    }

    /// The users without `full=1`, which the backup server does not know, for the screens shared with Proxmox VE.
    public static func accessUsers() -> APIRequest<[AccessUser]> {
        APIRequest(.get, "/access/users")
    }
}

// MARK: - Realms

/// A realm's settings, from `GET /config/access/{type}/{realm}`. Passwords and client keys are not returned.
public struct BackupServerRealmConfig: Decodable, Sendable, Equatable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: String] = [:]
        for key in container.allKeys {
            if let text = container.lossyString(key) {
                values[key.stringValue] = text
            } else if let flag = container.lossyBool(key) {
                values[key.stringValue] = flag ? "1" : "0"
            }
        }
        self.values = values
    }
}

/// An authentication realm: LDAP, Active Directory or OpenID Connect, or the built-in PAM and Proxmox Backup
/// realms, of which only the comment and default can change.
public struct BackupServerRealmDraft: BackupServerDraft, Sendable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case ldap, ad, openid, pam, pbs
        public var id: String { rawValue }
        public var isDirectory: Bool { self == .ldap || self == .ad }
        public var isBuiltIn: Bool { self == .pam || self == .pbs }
    }

    public static let modes = ["ldap", "ldap+starttls", "ldaps"]

    public var kind: Kind
    public var realm = ""
    public var comment = ""
    public var isDefault = false
    // LDAP and Active Directory
    public var server1 = ""
    public var server2 = ""
    public var port: Int?
    public var mode = "ldap"
    public var verifiesCertificate = false
    public var baseDN = ""
    public var bindDN = ""
    /// Write-only: empty keeps the stored one.
    public var password = ""
    public var userAttribute = "uid"
    public var filter = ""
    public var userClasses = ""
    public var syncAttributes = ""
    public var syncDefaults = ""
    // OpenID Connect
    public var issuerURL = ""
    public var clientID = ""
    /// Write-only: empty keeps the stored one.
    public var clientKey = ""
    public var scopes = ""
    public var prompt = ""
    public var acrValues = ""
    public var usernameClaim = ""
    public var autocreate = false

    public init(kind: Kind) {
        self.kind = kind
        if kind == .ad { userAttribute = "" }
    }

    public init(kind: Kind, realm: String, config: BackupServerRealmConfig) {
        self.init(kind: kind)
        let values = config.values
        self.realm = realm
        comment = values["comment"] ?? ""
        isDefault = values["default"] == "1"
        server1 = values["server1"] ?? ""
        server2 = values["server2"] ?? ""
        port = values["port"].flatMap(Int.init)
        mode = values["mode"] ?? "ldap"
        verifiesCertificate = values["verify"] == "1"
        baseDN = values["base-dn"] ?? ""
        bindDN = values["bind-dn"] ?? ""
        userAttribute = values["user-attr"] ?? ""
        filter = values["filter"] ?? ""
        userClasses = values["user-classes"] ?? ""
        syncAttributes = values["sync-attributes"] ?? ""
        syncDefaults = values["sync-defaults-options"] ?? ""
        issuerURL = values["issuer-url"] ?? ""
        clientID = values["client-id"] ?? ""
        scopes = values["scopes"] ?? ""
        prompt = values["prompt"] ?? ""
        acrValues = values["acr-values"] ?? ""
        usernameClaim = values["username-claim"] ?? ""
        autocreate = values["autocreate"] == "1"
    }

    public func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("comment", text(comment))
        set("default", isDefault ? "1" : nil)
        switch kind {
        case .ldap, .ad:
            set("server1", text(server1))
            set("server2", text(server2))
            set("port", port.map(String.init))
            set("mode", mode == "ldap" ? nil : mode)
            set("verify", verifiesCertificate ? "1" : nil)
            set("base-dn", text(baseDN))
            set("bind-dn", text(bindDN))
            if kind == .ldap { set("user-attr", text(userAttribute)) }
            set("filter", text(filter))
            set("user-classes", text(userClasses))
            set("sync-attributes", text(syncAttributes))
            set("sync-defaults-options", text(syncDefaults))
        case .openid:
            set("issuer-url", text(issuerURL))
            set("client-id", text(clientID))
            set("scopes", text(scopes))
            set("prompt", text(prompt))
            set("acr-values", text(acrValues))
            set("username-claim", text(usernameClaim))
            set("autocreate", autocreate ? "1" : nil)
        case .pam, .pbs:
            break
        }
        return values
    }

    /// Typed secrets: the bind password or client key; empty ones are not sent, so the stored ones stay.
    var secrets: [String: String] {
        switch kind {
        case .ldap, .ad: password.isEmpty ? [:] : ["password": password]
        case .openid: clientKey.isEmpty ? [:] : ["client-key": clientKey]
        case .pam, .pbs: [:]
        }
    }

    public var creationParameters: APIParameters {
        var parameters: APIParameters = ["realm": .string(realm.trimmingCharacters(in: .whitespaces))]
        for item in creationValues.items { parameters.append(item.name, item.value) }
        for (key, value) in secrets.sorted(by: { $0.key < $1.key }) { parameters[key] = .string(value) }
        return parameters
    }

    /// The changes, with secrets only when typed.
    public func update(from original: BackupServerRealmDraft, digest: String?) -> BackupServerConfigUpdate {
        var update = changes(from: original, digest: digest)
        for (key, value) in secrets { update.set(key, value) }
        return update
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, !isValidName(realm.trimmingCharacters(in: .whitespaces), minimum: 2) {
            problems["realm"] = String(localized: "Use 2 to 32 letters, digits, dots, dashes or underscores.")
        }
        switch kind {
        case .ldap, .ad:
            if text(server1) == nil { problems["server1"] = String(localized: "Enter the server.") }
            if kind == .ldap, text(baseDN) == nil { problems["base-dn"] = String(localized: "Enter the base DN, e.g. dc=example,dc=com.") }
            if kind == .ldap, text(userAttribute) == nil { problems["user-attr"] = String(localized: "Enter the attribute, e.g. uid.") }
            if let port, !(1...65_535).contains(port) { problems["port"] = String(localized: "Enter a port from 1 to 65535.") }
        case .openid:
            if text(issuerURL) == nil || !issuerURL.lowercased().hasPrefix("http") { problems["issuer-url"] = String(localized: "Enter the issuer URL, starting with https://.") }
            if text(clientID) == nil { problems["client-id"] = String(localized: "Enter the client ID.") }
        case .pam, .pbs:
            break
        }
        return problems
    }
}

/// What a directory sync removes when a user or their attribute vanishes from the directory.
public enum RealmSyncRemoval: String, Sendable, CaseIterable, Identifiable {
    case acl, entry, properties
    public var id: String { rawValue }
}

extension PBS {
    public static func realmConfig(_ kind: BackupServerRealmDraft.Kind, _ realm: String) -> APIRequest<Digested<BackupServerRealmConfig>> {
        APIRequest(.get, kind.isBuiltIn ? "/config/access/\(kind.rawValue)" : "/config/access/\(kind.rawValue)/\(escapePath(realm))")
    }

    public static func createRealm(_ draft: BackupServerRealmDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/config/access/\(draft.kind.rawValue)", parameters: draft.creationParameters)
    }

    public static func updateRealm(_ kind: BackupServerRealmDraft.Kind, _ realm: String, _ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, kind.isBuiltIn ? "/config/access/\(kind.rawValue)" : "/config/access/\(kind.rawValue)/\(escapePath(realm))",
                   parameters: update.parameters)
    }

    public static func deleteRealm(_ kind: BackupServerRealmDraft.Kind, _ realm: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/config/access/\(kind.rawValue)/\(escapePath(realm))")
    }

    /// Syncs users from an LDAP or Active Directory realm. Returns a task ID.
    public static func syncRealm(_ realm: String, dryRun: Bool, enableNew: Bool?, removeVanished: Set<RealmSyncRemoval>) -> APIRequest<String> {
        var parameters: APIParameters = ["dry-run": .bool(dryRun)]
        if let enableNew { parameters["enable-new"] = .bool(enableNew) }
        if !removeVanished.isEmpty {
            parameters["remove-vanished"] = .string(RealmSyncRemoval.allCases.filter(removeVanished.contains).map(\.rawValue).joined(separator: ";"))
        }
        return APIRequest(.post, "/access/domains/\(escapePath(realm))/sync", parameters: parameters)
    }
}

// MARK: - Traffic control

public struct TrafficControlDraft: Sendable, Equatable {
    public var name = ""
    public var comment = ""
    /// Networks in CIDR form, e.g. `0.0.0.0/0` for all IPv4 clients.
    public var networks: [String] = []
    /// Users the rule applies to, whatever their address (4.1 and newer); tokens are not accepted.
    public var users: [String] = []
    public var rateIn = ByteRate()
    public var rateOut = ByteRate()
    public var burstIn = ByteRate()
    public var burstOut = ByteRate()
    /// When the rule applies, e.g. `mon..fri 8:00-18:00`; always without.
    public var timeframes: [String] = []

    public init() {}

    public init(_ rule: TrafficControlRule) {
        name = rule.name
        comment = rule.comment ?? ""
        networks = rule.networks
        users = rule.users
        rateIn = ByteRate(parsing: rule.rateIn)
        rateOut = ByteRate(parsing: rule.rateOut)
        burstIn = ByteRate(parsing: rule.burstIn)
        burstOut = ByteRate(parsing: rule.burstOut)
        timeframes = rule.timeframes
    }

    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        values.updateValue(text(comment), forKey: "comment")
        values.updateValue(rateIn.stringValue, forKey: "rate-in")
        values.updateValue(rateOut.stringValue, forKey: "rate-out")
        values.updateValue(burstIn.stringValue, forKey: "burst-in")
        values.updateValue(burstOut.stringValue, forKey: "burst-out")
        return values
    }

    private var lists: [String: [String]] {
        ["network": networks.compactMap(text), "users": users.compactMap(text), "timeframe": timeframes.compactMap(text)]
    }

    public var creationParameters: APIParameters {
        var parameters: APIParameters = ["name": .string(name.trimmingCharacters(in: .whitespaces))]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        for (key, items) in lists.sorted(by: { $0.key < $1.key }) {
            for item in items { parameters.append(key, .string(item)) }
        }
        return parameters
    }

    public func changes(from original: TrafficControlDraft, digest: String? = nil) -> BackupServerConfigUpdate {
        var update = BackupServerConfigUpdate(digest: digest)
        let old = original.serialized()
        for (key, value) in serialized() where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        let oldLists = original.lists
        for (key, items) in lists where items != oldLists[key] {
            update.setList(key, items)
        }
        return update
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, !isValidName(name.trimmingCharacters(in: .whitespaces)) {
            problems["name"] = String(localized: "Use 3 to 32 letters, digits, dots, dashes or underscores.")
        }
        let networks = networks.compactMap(text)
        if networks.isEmpty {
            problems["network"] = String(localized: "Add at least one network, e.g. 0.0.0.0/0 for all IPv4 clients.")
        } else if networks.contains(where: { $0.wholeMatch(of: /[0-9a-fA-F:.]+\/\d{1,3}/) == nil }) {
            problems["network"] = String(localized: "Enter networks in CIDR form, e.g. 10.0.0.0/8.")
        }
        if [rateIn, rateOut, burstIn, burstOut].allSatisfy({ $0.stringValue == nil }) {
            problems["rate-in"] = String(localized: "Set at least one rate or burst; a rule without limits does nothing.")
        }
        return problems
    }
}

extension PBS {
    public static func createTrafficControlRule(_ draft: TrafficControlDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/config/traffic-control", parameters: draft.creationParameters)
    }

    public static func updateTrafficControlRule(_ name: String, _ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/config/traffic-control/\(escapePath(name))", parameters: update.parameters)
    }
}

// MARK: - Metric servers

/// A server the backup server sends its metrics to, from `GET /admin/metrics` (`/config/metrics` only lists the types).
public struct BackupServerMetricServer: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case influxDBHTTP = "influxdb-http", influxDBUDP = "influxdb-udp"
        public var id: String { rawValue }
    }

    public var name: String
    public var kind: Kind?
    /// The URL (HTTP) or `host:port` (UDP).
    public var server: String
    public var isEnabled: Bool
    public var comment: String?

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        kind = container.lossyString(AnyCodingKey("type")).flatMap(Kind.init)
        server = container.lossyString(AnyCodingKey("server")) ?? container.lossyString(AnyCodingKey("url"))
            ?? container.lossyString(AnyCodingKey("host")) ?? ""
        isEnabled = container.lossyBool(AnyCodingKey("enable")) ?? true
        comment = container.lossyString(AnyCodingKey("comment")).flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct BackupServerMetricServerDraft: BackupServerDraft, Sendable {
    public var kind: BackupServerMetricServer.Kind
    public var name = ""
    public var isEnabled = true
    public var comment = ""
    /// HTTP: the URL with an optional port.
    public var url = ""
    /// Write-only: empty keeps the stored one.
    public var token = ""
    public var organization = ""
    public var bucket = ""
    public var maxBodySize: Int?
    public var verifiesTLS = true
    /// UDP: `host:port`.
    public var host = ""
    public var mtu: Int?

    public init(kind: BackupServerMetricServer.Kind) {
        self.kind = kind
    }

    public init(kind: BackupServerMetricServer.Kind, name: String, config: BackupServerRealmConfig) {
        self.init(kind: kind)
        let values = config.values
        self.name = name
        isEnabled = values["enable"] != "0"
        comment = values["comment"] ?? ""
        url = values["url"] ?? ""
        organization = values["organization"] ?? ""
        bucket = values["bucket"] ?? ""
        maxBodySize = values["max-body-size"].flatMap(Int.init)
        verifiesTLS = values["verify-tls"] != "0"
        host = values["host"] ?? ""
        mtu = values["mtu"].flatMap(Int.init)
    }

    public func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("enable", isEnabled ? nil : "0")
        set("comment", text(comment))
        switch kind {
        case .influxDBHTTP:
            set("url", text(url))
            set("organization", text(organization))
            set("bucket", text(bucket))
            set("max-body-size", maxBodySize.map(String.init))
            set("verify-tls", verifiesTLS ? nil : "0")
        case .influxDBUDP:
            set("host", text(host))
            set("mtu", mtu.map(String.init))
        }
        return values
    }

    public var creationParameters: APIParameters {
        var parameters: APIParameters = ["name": .string(name.trimmingCharacters(in: .whitespaces))]
        for item in creationValues.items { parameters.append(item.name, item.value) }
        if kind == .influxDBHTTP, !token.isEmpty { parameters["token"] = .string(token) }
        return parameters
    }

    public func update(from original: BackupServerMetricServerDraft, digest: String?) -> BackupServerConfigUpdate {
        var update = changes(from: original, digest: digest)
        if kind == .influxDBHTTP, !token.isEmpty { update.set("token", token) }
        return update
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, !isValidName(name.trimmingCharacters(in: .whitespaces)) {
            problems["name"] = String(localized: "Use 3 to 32 letters, digits, dots, dashes or underscores.")
        }
        switch kind {
        case .influxDBHTTP:
            if !url.lowercased().hasPrefix("http") { problems["url"] = String(localized: "Enter the URL, e.g. https://influx.example.net:8086.") }
        case .influxDBUDP:
            if host.wholeMatch(of: /.+:\d+/) == nil { problems["host"] = String(localized: "Enter host and port, e.g. influx.lan:8089.") }
        }
        return problems
    }
}

extension PBS {
    public static func metricServers() -> APIRequest<Digested<[BackupServerMetricServer]>> {
        APIRequest(.get, "/admin/metrics")
    }

    public static func metricServer(_ kind: BackupServerMetricServer.Kind, _ name: String) -> APIRequest<Digested<BackupServerRealmConfig>> {
        APIRequest(.get, "/config/metrics/\(kind.rawValue)/\(escapePath(name))")
    }

    public static func createMetricServer(_ draft: BackupServerMetricServerDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/config/metrics/\(draft.kind.rawValue)", parameters: draft.creationParameters)
    }

    public static func updateMetricServer(_ kind: BackupServerMetricServer.Kind, _ name: String, _ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/config/metrics/\(kind.rawValue)/\(escapePath(name))", parameters: update.parameters)
    }

    public static func deleteMetricServer(_ kind: BackupServerMetricServer.Kind, _ name: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/config/metrics/\(kind.rawValue)/\(escapePath(name))")
    }
}

// MARK: - S3 endpoints

public struct S3EndpointDraft: BackupServerDraft, Sendable {
    /// Skips the `If-None-Match` header, which some providers do not support.
    public static let skipIfNoneMatchQuirk = "skip-if-none-match-header"

    public var id = ""
    public var endpoint = ""
    public var region = ""
    public var port: Int?
    public var accessKey = ""
    /// Write-only: empty keeps the stored one.
    public var secretKey = ""
    public var usesPathStyle = false
    public var fingerprint = ""
    public var skipsIfNoneMatch = false
    /// Requests per second; 4.1 and newer.
    public var putRateLimit: Int?
    public var rateIn = ByteRate()
    public var rateOut = ByteRate()
    /// Settings the form does not show, kept as they are.
    var otherQuirks: [String] = []

    public init() {}

    public init(_ endpoint: S3Endpoint) {
        id = endpoint.id
        self.endpoint = endpoint.endpoint
        region = endpoint.region ?? ""
        port = endpoint.port
        accessKey = endpoint.accessKey ?? ""
        usesPathStyle = endpoint.usesPathStyle
        fingerprint = endpoint.fingerprint ?? ""
        skipsIfNoneMatch = endpoint.providerQuirks.contains(Self.skipIfNoneMatchQuirk)
        otherQuirks = endpoint.providerQuirks.filter { $0 != Self.skipIfNoneMatchQuirk }
        putRateLimit = endpoint.values["put-rate-limit"].flatMap(Int.init)
        rateIn = ByteRate(parsing: endpoint.values["rate-in"])
        rateOut = ByteRate(parsing: endpoint.values["rate-out"])
    }

    var quirks: [String] { otherQuirks + (skipsIfNoneMatch ? [Self.skipIfNoneMatchQuirk] : []) }

    public func serialized() -> [String: String?] {
        [
            "endpoint": text(endpoint), "region": text(region), "port": port.map(String.init), "access-key": text(accessKey),
            "path-style": usesPathStyle ? "1" : nil, "fingerprint": text(fingerprint), "put-rate-limit": putRateLimit.map(String.init),
            "rate-in": rateIn.stringValue, "rate-out": rateOut.stringValue,
        ]
    }

    public var creationParameters: APIParameters {
        var parameters: APIParameters = ["id": .string(id.trimmingCharacters(in: .whitespaces)), "secret-key": .string(secretKey)]
        for item in creationValues.items { parameters.append(item.name, item.value) }
        for quirk in quirks { parameters.append("provider-quirks", .string(quirk)) }
        return parameters
    }

    public func update(from original: S3EndpointDraft, digest: String?) -> BackupServerConfigUpdate {
        var update = changes(from: original, digest: digest)
        if !secretKey.isEmpty { update.set("secret-key", secretKey) }
        if quirks != original.quirks { update.setList("provider-quirks", quirks) }
        return update
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew {
            if !isValidName(id.trimmingCharacters(in: .whitespaces)) { problems["id"] = String(localized: "Use 3 to 32 letters, digits, dots, dashes or underscores.") }
            if secretKey.isEmpty { problems["secret-key"] = String(localized: "Enter the secret key.") }
        }
        if text(endpoint) == nil { problems["endpoint"] = String(localized: "Enter the endpoint, e.g. s3.example.net or {{bucket}}.s3.{{region}}.amazonaws.com.") }
        if text(accessKey) == nil { problems["access-key"] = String(localized: "Enter the access key.") }
        if let port, !(1...65_535).contains(port) { problems["port"] = String(localized: "Enter a port from 1 to 65535.") }
        return problems
    }
}

extension PBS {
    public static func createS3Endpoint(_ draft: S3EndpointDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/config/s3", parameters: draft.creationParameters)
    }

    public static func updateS3Endpoint(_ id: String, _ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/config/s3/\(escapePath(id))", parameters: update.parameters)
    }

    public static func deleteS3Endpoint(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/config/s3/\(escapePath(id))")
    }
}

// MARK: - Encryption keys

extension PBS {
    /// Creates a key for sync jobs, or imports `key` (a key file's JSON) instead (4.2 and newer).
    public static func createEncryptionKey(_ id: String, importing key: String? = nil) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["id": .string(id)]
        if let key, !key.isEmpty { parameters["key"] = .string(key) }
        return APIRequest(.post, "/config/encryption-keys", parameters: parameters)
    }

    /// Archives a key: it still decrypts, but sync jobs no longer encrypt with it.
    public static func archiveEncryptionKey(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.post, "/config/encryption-keys/\(escapePath(id))")
    }

    public static func deleteEncryptionKey(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/config/encryption-keys/\(escapePath(id))")
    }
}

// MARK: - Notifications

/// The notification API of the backup server is Proxmox VE's under `/config/notifications`, with each cleared
/// setting as its own `delete`.
extension PBS {
    static let notifications = "/config/notifications"

    /// Rewrites a Proxmox VE notification request for the backup server.
    public static func notificationRequest<Value>(_ request: APIRequest<Value>) -> APIRequest<Value> {
        var parameters = APIParameters()
        for item in request.parameters.items {
            if item.name == "delete", case .string(let keys) = item.value {
                for key in keys.split(separator: ",") { parameters.append("delete", .string(String(key))) }
            } else {
                parameters.append(item.name, item.value)
            }
        }
        let path = request.path.replacingOccurrences(of: "/cluster/notifications", with: notifications)
        return APIRequest(request.method, path, parameters: parameters)
    }
}
