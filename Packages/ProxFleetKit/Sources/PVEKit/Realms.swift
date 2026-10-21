import Foundation
import ProxmoxCore

/// The kinds of realm, with what the web interface lets you do with each.
public enum RealmType: String, Sendable, CaseIterable, Identifiable {
    case pam, pve, ldap, ad, openid

    public var id: String { rawValue }

    /// PAM and the Proxmox VE realm always exist and cannot be added or removed.
    public var canBeAdded: Bool { ![.pam, .pve].contains(self) }
    /// LDAP and Active Directory can copy their users and groups into Proxmox VE.
    public var canSync: Bool { [.ldap, .ad].contains(self) }
    /// OpenID Connect providers handle second factors themselves.
    public var supportsTwoFactor: Bool { self != .openid }

    public var title: String {
        switch self {
        case .pam: "Linux PAM"
        case .pve: "Proxmox VE"
        case .ldap: "LDAP"
        case .ad: "Active Directory"
        case .openid: "OpenID Connect"
        }
    }
}

/// A realm's settings, from `GET /access/domains/{realm}`.
public struct RealmConfig: Decodable, Sendable, Equatable {
    public var type: String
    /// Every setting as text, by the names the API uses.
    public var values: [String: String]
    public var digest: String?

    public init(type: String, values: [String: String], digest: String? = nil) {
        self.type = type
        self.values = values
        self.digest = digest
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
        type = values.removeValue(forKey: "type") ?? ""
        digest = values.removeValue(forKey: "digest")
        values["realm"] = nil
        self.values = values
    }
}

/// A second factor every user of a realm must use: `type=oath,digits=6,step=30` or `type=yubico,id=…,key=…,url=…`.
public struct RealmTwoFactor: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case none, oath, yubico
        public var id: String { rawValue }
    }

    public var kind: Kind = .none
    /// OATH: code length, empty for 6.
    public var digits = ""
    /// OATH: seconds a code is valid, empty for 30.
    public var step = ""
    public var yubicoID = ""
    public var yubicoKey = ""
    /// Empty for the YubiCloud servers.
    public var yubicoURL = ""

    public init() {}

    public init(_ text: String?) {
        let property = PropertyString(parsing: text ?? "")
        kind = Kind(rawValue: property["type"] ?? "") ?? .none
        digits = property["digits"] ?? ""
        step = property["step"] ?? ""
        yubicoID = property["id"] ?? ""
        yubicoKey = property["key"] ?? ""
        yubicoURL = property["url"] ?? ""
    }

    var serialized: String? {
        var property = PropertyString(items: [])
        func set(_ key: String, _ value: String) {
            let value = value.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { property[key] = value }
        }
        switch kind {
        case .none:
            return nil
        case .oath:
            property["type"] = "oath"
            set("digits", digits)
            set("step", step)
        case .yubico:
            property["type"] = "yubico"
            set("id", yubicoID)
            set("key", yubicoKey)
            set("url", yubicoURL)
        }
        return property.stringValue
    }
}

/// What a sync removes when users or groups vanished from the directory.
public enum VanishedRemoval: String, Sendable, CaseIterable, Identifiable {
    /// Permissions of vanished users and groups.
    case acl
    /// The vanished users and groups themselves.
    case entry
    /// Properties, such as an email address, that vanished from a user.
    case properties

    public var id: String { rawValue }

    /// `acl;entry`, or `none` for nothing.
    static func serialized(_ removals: Set<VanishedRemoval>) -> String {
        let list = allCases.filter(removals.contains).map(\.rawValue)
        return list.isEmpty ? "none" : list.joined(separator: ";")
    }

    static func parse(_ text: String?) -> Set<VanishedRemoval> {
        Set((text ?? "").split(separator: ";").compactMap { VanishedRemoval(rawValue: String($0)) })
    }
}

/// Options of a sync, and the defaults a realm keeps for them in `sync-defaults-options`.
public struct RealmSyncOptions: Equatable, Sendable {
    /// `users`, `groups` or `both`; empty for no default.
    public var scope = ""
    /// nil for the server's default, which enables new users.
    public var enableNew: Bool?
    public var removeVanished: Set<VanishedRemoval> = []

    public init() {}

    init(_ text: String?) {
        let property = PropertyString(parsing: text ?? "")
        scope = property["scope"] ?? ""
        enableNew = property["enable-new"].map { $0 == "1" }
        removeVanished = VanishedRemoval.parse(property["remove-vanished"])
    }

    var serialized: String? {
        var property = PropertyString(items: [])
        if !scope.isEmpty { property["scope"] = scope }
        if let enableNew { property["enable-new"] = enableNew ? "1" : "0" }
        if !removeVanished.isEmpty { property["remove-vanished"] = VanishedRemoval.serialized(removeVanished) }
        return property.items.isEmpty ? nil : property.stringValue
    }
}

/// The settings of a realm as a form. Like `StorageConfigDraft`, the draft and the configuration it came from
/// serialize the same way, so an update sends only what changed, and `delete` for what was cleared.
public struct RealmDraft: Equatable, Sendable {
    public var type: RealmType
    public var realm = ""
    public var comment = ""
    public var isDefault = false
    public var twoFactor = RealmTwoFactor()

    // LDAP and Active Directory
    public var server1 = ""
    public var server2 = ""
    public var port = ""
    /// `ldap`, `ldaps` or `ldap+starttls`.
    public var mode = "ldap"
    public var verifyCertificate = false
    public var baseDN = ""
    public var userAttribute = ""
    public var domain = ""
    public var isCaseSensitive = true
    public var bindDN = ""
    /// Write-only: empty keeps the stored password.
    public var password = ""
    public var emailAttribute = ""
    public var groupNameAttribute = ""
    public var userClasses = ""
    public var groupClasses = ""
    public var userFilter = ""
    public var groupFilter = ""
    public var syncDefaults = RealmSyncOptions()
    /// Not stored: asks the server to try binding before it saves.
    public var checksConnection = false
    private var otherSyncAttributes = PropertyString(items: [])

    // OpenID Connect
    public var issuerURL = ""
    public var clientID = ""
    public var clientKey = ""
    public var scopes = ""
    public var autocreateUsers = false
    /// Fixed once the realm exists, since user names derive from it.
    public var usernameClaim = ""
    public var autocreateGroups = false
    public var groupsClaim = ""
    public var overwriteGroups = false
    public var prompt = ""
    public var acrValues = ""
    public var queriesUserinfo = true
    public var audiences = ""

    public static let modes = ["ldap", "ldaps", "ldap+starttls"]

    public init(type: RealmType) {
        self.type = type
    }

    public init?(realm: String, _ config: RealmConfig) {
        guard let type = RealmType(rawValue: config.type) else { return nil }
        self.type = type
        self.realm = realm
        let values = config.values
        comment = values["comment"] ?? ""
        isDefault = values["default"] == "1"
        twoFactor = RealmTwoFactor(values["tfa"])
        server1 = values["server1"] ?? ""
        server2 = values["server2"] ?? ""
        port = values["port"] ?? ""
        mode = values["mode"] ?? (values["secure"] == "1" ? "ldaps" : "ldap")
        verifyCertificate = values["verify"] == "1"
        baseDN = values["base_dn"] ?? ""
        userAttribute = values["user_attr"] ?? ""
        domain = values["domain"] ?? ""
        isCaseSensitive = values["case-sensitive"] != "0"
        bindDN = values["bind_dn"] ?? ""
        var attributes = PropertyString(parsing: values["sync_attributes"] ?? "")
        emailAttribute = attributes["email"] ?? ""
        attributes["email"] = nil
        otherSyncAttributes = attributes
        groupNameAttribute = values["group_name_attr"] ?? ""
        userClasses = values["user_classes"] ?? ""
        groupClasses = values["group_classes"] ?? ""
        userFilter = values["filter"] ?? ""
        groupFilter = values["group_filter"] ?? ""
        syncDefaults = RealmSyncOptions(values["sync-defaults-options"])
        issuerURL = values["issuer-url"] ?? ""
        clientID = values["client-id"] ?? ""
        clientKey = values["client-key"] ?? ""
        scopes = values["scopes"] ?? ""
        autocreateUsers = values["autocreate"] == "1"
        usernameClaim = values["username-claim"] ?? ""
        autocreateGroups = values["groups-autocreate"] == "1"
        groupsClaim = values["groups-claim"] ?? ""
        overwriteGroups = values["groups-overwrite"] == "1"
        prompt = values["prompt"] ?? ""
        acrValues = values["acr-values"] ?? ""
        queriesUserinfo = values["query-userinfo"] != "0"
        audiences = values["audiences"] ?? ""
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The settings this form manages; nil means "not set".
    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        // updateValue keeps nil values, which mark settings to delete; assigning nil would drop the key.
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("comment", Self.text(comment))
        set("default", isDefault ? "1" : nil)
        if type.supportsTwoFactor { set("tfa", twoFactor.serialized) }
        switch type {
        case .pam, .pve:
            break
        case .ldap, .ad:
            set("server1", Self.text(server1))
            set("server2", Self.text(server2))
            set("port", Self.text(port))
            set("mode", mode == "ldap" ? nil : mode)
            set("verify", verifyCertificate ? "1" : nil)
            if type == .ldap {
                set("base_dn", Self.text(baseDN))
                set("user_attr", Self.text(userAttribute))
            } else {
                set("domain", Self.text(domain))
                set("case-sensitive", isCaseSensitive ? nil : "0")
            }
            set("bind_dn", Self.text(bindDN))
            var attributes = otherSyncAttributes
            if let email = Self.text(emailAttribute) { attributes.items.insert((key: "email", value: email), at: 0) }
            set("sync_attributes", attributes.items.isEmpty ? nil : attributes.stringValue)
            set("group_name_attr", Self.text(groupNameAttribute))
            set("user_classes", Self.text(userClasses))
            set("group_classes", Self.text(groupClasses))
            set("filter", Self.text(userFilter))
            set("group_filter", Self.text(groupFilter))
            set("sync-defaults-options", syncDefaults.serialized)
        case .openid:
            set("issuer-url", Self.text(issuerURL))
            set("client-id", Self.text(clientID))
            set("client-key", Self.text(clientKey))
            set("scopes", Self.text(scopes))
            set("autocreate", autocreateUsers ? "1" : nil)
            set("username-claim", Self.text(usernameClaim))
            set("groups-autocreate", autocreateGroups ? "1" : nil)
            set("groups-claim", Self.text(groupsClaim))
            set("groups-overwrite", overwriteGroups ? "1" : nil)
            set("prompt", Self.text(prompt))
            set("acr-values", Self.text(acrValues))
            set("query-userinfo", queriesUserinfo ? nil : "0")
            set("audiences", Self.text(audiences))
        }
        return values
    }

    /// Settings `PUT /access/domains/{realm}` does not take.
    static let fixedKeys: Set<String> = ["username-claim"]

    /// Parameters of `POST /access/domains`.
    var creationParameters: APIParameters {
        var parameters: APIParameters = ["realm": .string(realm.trimmingCharacters(in: .whitespaces)), "type": .string(type.rawValue)]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value, !value.isEmpty { parameters[key] = .string(value) }
        }
        if let password = Self.text(password) { parameters["password"] = .string(password) }
        if checksConnection, type.canSync { parameters["check-connection"] = true }
        return parameters
    }

    /// The changes against the configuration the form was opened with. Empty when nothing changed.
    public func changes(from original: RealmDraft) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let old = original.serialized()
        for (key, value) in serialized() where !Self.fixedKeys.contains(key) && value != (old[key] ?? nil) {
            update.set(key, value)
        }
        if let password = Self.text(password) { update.set("password", password) }
        if checksConnection, type.canSync, !update.isEmpty { update.set("check-connection", "1") }
        return update
    }

    /// Problems the app can see itself, by parameter name as the server reports them.
    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew {
            let id = realm.trimmingCharacters(in: .whitespaces)
            if id.isEmpty {
                problems["realm"] = String(localized: "Enter a realm ID.")
            } else if id.count < 2 || !(id.first?.isLetter ?? false) || id.contains(where: { !($0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0))) }) {
                problems["realm"] = String(localized: "Use at least 2 characters: a letter first, then letters, digits, and - _ . only.")
            }
        }
        func require(_ key: String, _ value: String, _ message: String) {
            if Self.text(value) == nil { problems[key] = message }
        }
        switch type {
        case .pam, .pve:
            break
        case .ldap:
            require("server1", server1, String(localized: "Enter the server address."))
            require("base_dn", baseDN, String(localized: "Enter the base DN, e.g. dc=example,dc=com."))
            require("user_attr", userAttribute, String(localized: "Enter the user attribute, e.g. uid."))
        case .ad:
            require("server1", server1, String(localized: "Enter the server address."))
            require("domain", domain, String(localized: "Enter the domain, e.g. example.com."))
        case .openid:
            require("issuer-url", issuerURL, String(localized: "Enter the issuer URL."))
            if let url = Self.text(issuerURL), !(url.hasPrefix("https://") || url.hasPrefix("http://")) {
                problems["issuer-url"] = String(localized: "Enter a URL starting with https://.")
            }
            require("client-id", clientID, String(localized: "Enter the client ID."))
        }
        if let port = Self.text(port), !(Int(port).map { (1...65535).contains($0) } ?? false) {
            problems["port"] = String(localized: "Enter a port from 1 to 65535.")
        }
        if twoFactor.kind == .oath {
            if let digits = Self.text(twoFactor.digits), !(Int(digits).map { (6...8).contains($0) } ?? false) {
                problems["tfa"] = String(localized: "Codes have 6 to 8 digits.")
            } else if let step = Self.text(twoFactor.step), !(Int(step).map { $0 >= 10 } ?? false) {
                problems["tfa"] = String(localized: "Use a time step of 10 seconds or more.")
            }
        } else if twoFactor.kind == .yubico {
            require("tfa", twoFactor.yubicoID, String(localized: "Enter the Yubico API client ID."))
            if problems["tfa"] == nil { require("tfa", twoFactor.yubicoKey, String(localized: "Enter the Yubico API key.")) }
        }
        return problems
    }
}

extension PVE {
    public static func realmConfig(_ realm: String) -> APIRequest<RealmConfig> {
        APIRequest(.get, "/access/domains/\(escapePath(realm))")
    }

    public static func createRealm(_ draft: RealmDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/access/domains", parameters: draft.creationParameters)
    }

    public static func updateRealm(_ realm: String, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/access/domains/\(escapePath(realm))", parameters: update.parameters)
    }

    /// Removes the realm. Its users stay, but cannot sign in anymore.
    public static func deleteRealm(_ realm: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/access/domains/\(escapePath(realm))")
    }

    /// Copies users and groups from an LDAP or Active Directory realm. With `dryRun`, the task log only
    /// lists what would change. Returns the task ID.
    public static func syncRealm(_ realm: String, scope: String, enableNew: Bool, removeVanished: Set<VanishedRemoval>, dryRun: Bool) -> APIRequest<String> {
        APIRequest(.post, "/access/domains/\(escapePath(realm))/sync", parameters: [
            "scope": .string(scope), "enable-new": .bool(enableNew),
            "remove-vanished": .string(VanishedRemoval.serialized(removeVanished)), "dry-run": .bool(dryRun),
        ])
    }
}
