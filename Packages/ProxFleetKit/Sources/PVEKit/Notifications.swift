import Foundation
import ProxmoxCore

/// Where notifications go: the four kinds of endpoint Proxmox VE can send to.
public enum NotificationEndpointType: String, Sendable, CaseIterable, Identifiable {
    case sendmail, smtp, gotify, webhook

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sendmail: "Sendmail"
        case .smtp: "SMTP"
        case .gotify: "Gotify"
        case .webhook: "Webhook"
        }
    }
}

/// An endpoint, from `GET /cluster/notifications/targets`.
public struct NotificationTarget: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var type: String
    public var comment: String?
    public var isDisabled: Bool
    /// `builtin` for the endpoint every server has, `modified-builtin` once it was changed, `user-created` otherwise.
    public var origin: String

    public var id: String { name }
    public var endpointType: NotificationEndpointType? { NotificationEndpointType(rawValue: type) }
    public var isBuiltIn: Bool { origin != "user-created" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        type = container.lossyString(AnyCodingKey("type")) ?? ""
        comment = container.lossyString(AnyCodingKey("comment")).flatMap { $0.isEmpty ? nil : $0 }
        isDisabled = container.lossyBool(AnyCodingKey("disable")) ?? false
        origin = container.lossyString(AnyCodingKey("origin")) ?? "user-created"
    }
}

/// A notification object's settings: text values and lists, by the names the API uses.
public struct NotificationConfig: Decodable, Sendable, Equatable {
    public var values: [String: String]
    public var lists: [String: [String]]
    public var digest: String?

    public init(values: [String: String] = [:], lists: [String: [String]] = [:], digest: String? = nil) {
        self.values = values
        self.lists = lists
        self.digest = digest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: String] = [:]
        var lists: [String: [String]] = [:]
        for key in container.allKeys {
            if let list = try? container.decode([String].self, forKey: key) {
                lists[key.stringValue] = list
            } else if let text = container.lossyString(key) {
                values[key.stringValue] = text
            } else if let flag = container.lossyBool(key) {
                values[key.stringValue] = flag ? "1" : "0"
            }
        }
        digest = values.removeValue(forKey: "digest")
        self.values = values
        self.lists = lists
    }
}

/// A header or secret of a webhook. Secret values are write-only: the server returns names only, and a name
/// without a value keeps the stored secret.
public struct WebhookPair: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public var name: String
    public var value: String
    /// A secret that exists on the server; an empty value keeps it.
    public var isStored = false

    public init(name: String = "", value: String = "", isStored: Bool = false) {
        self.name = name
        self.value = value
        self.isStored = isStored
    }

    public static func == (lhs: WebhookPair, rhs: WebhookPair) -> Bool {
        lhs.name == rhs.name && lhs.value == rhs.value && lhs.isStored == rhs.isStored
    }

    /// `name=Authorization,value=<base64>`.
    init(parsing text: String, isSecret: Bool) {
        let property = PropertyString(parsing: text)
        name = property["name"] ?? ""
        value = property["value"].flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        isStored = isSecret
    }

    var serialized: String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var property = PropertyString(items: [(key: "name", value: name)])
        if !value.isEmpty || !isStored { property["value"] = Data(value.utf8).base64EncodedString() }
        return property.stringValue
    }
}

/// The settings of an endpoint as a form. Secrets (SMTP password, Gotify token, webhook secrets) are write-only.
public struct NotificationEndpointDraft: Equatable, Sendable {
    public var type: NotificationEndpointType
    public var name = ""
    public var comment = ""
    public var isEnabled = true
    /// sendmail and SMTP: addresses and users whose email address is used.
    public var mailto: [String] = []
    public var mailtoUsers: [String] = []
    public var fromAddress = ""
    public var author = ""
    /// SMTP and Gotify: the server; SMTP takes a host name, Gotify a URL.
    public var server = ""
    public var port = ""
    /// SMTP: `tls`, `starttls` or `insecure`.
    public var mode = "tls"
    public var username = ""
    /// SMTP password or Gotify token; empty keeps the stored one.
    public var secret = ""
    /// Webhook.
    public var url = ""
    public var method = "post"
    public var body = ""
    public var headers: [WebhookPair] = []
    public var secrets: [WebhookPair] = []

    public init(type: NotificationEndpointType) {
        self.type = type
        if type == .sendmail || type == .smtp { mailtoUsers = ["root@pam"] }
    }

    public init(type: NotificationEndpointType, name: String, _ config: NotificationConfig) {
        self.type = type
        self.name = name
        let values = config.values
        comment = values["comment"] ?? ""
        isEnabled = values["disable"] != "1"
        mailto = config.lists["mailto"] ?? values["mailto"].map { [$0] } ?? []
        mailtoUsers = config.lists["mailto-user"] ?? values["mailto-user"].map { [$0] } ?? []
        fromAddress = values["from-address"] ?? ""
        author = values["author"] ?? ""
        server = values["server"] ?? ""
        port = values["port"] ?? ""
        mode = values["mode"] ?? "tls"
        username = values["username"] ?? ""
        url = values["url"] ?? ""
        method = values["method"] ?? "post"
        body = values["body"].flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        headers = (config.lists["header"] ?? values["header"].map { [$0] } ?? []).map { WebhookPair(parsing: $0, isSecret: false) }
        secrets = (config.lists["secret"] ?? values["secret"].map { [$0] } ?? []).map { WebhookPair(parsing: $0, isSecret: true) }
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func list(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Settings with single values; nil means "not set".
    func serializedValues() -> [String: String?] {
        var values: [String: String?] = [:]
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("comment", Self.text(comment))
        set("disable", isEnabled ? nil : "1")
        switch type {
        case .sendmail:
            set("from-address", Self.text(fromAddress))
            set("author", Self.text(author))
        case .smtp:
            set("server", Self.text(server))
            set("port", Self.text(port))
            set("mode", mode == "tls" ? nil : mode)
            set("username", Self.text(username))
            set("from-address", Self.text(fromAddress))
            set("author", Self.text(author))
        case .gotify:
            set("server", Self.text(server))
        case .webhook:
            set("url", Self.text(url))
            set("method", method)
            set("body", body.isEmpty ? nil : Data(body.utf8).base64EncodedString())
        }
        return values
    }

    /// Settings with lists; empty means "not set".
    func serializedLists() -> [String: [String]] {
        switch type {
        case .sendmail, .smtp:
            ["mailto": Self.list(mailto), "mailto-user": Self.list(mailtoUsers)]
        case .gotify:
            [:]
        case .webhook:
            ["header": headers.compactMap(\.serialized), "secret": secrets.compactMap(\.serialized)]
        }
    }

    /// The write-only secret of SMTP or Gotify, sent only when typed.
    private var secretParameter: (name: String, value: String)? {
        guard let secret = Self.text(secret) else { return nil }
        switch type {
        case .smtp: return ("password", secret)
        case .gotify: return ("token", secret)
        default: return nil
        }
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["name": .string(name.trimmingCharacters(in: .whitespaces))]
        for (key, value) in serializedValues().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        for (key, list) in serializedLists().sorted(by: { $0.key < $1.key }) {
            for item in list { parameters.append(key, .string(item)) }
        }
        if let secret = secretParameter { parameters[secret.name] = .string(secret.value) }
        return parameters
    }

    /// Only what changed, `delete` for what was cleared. Lists go whole when they changed.
    public func changes(from original: NotificationEndpointDraft) -> APIParameters {
        var parameters = APIParameters()
        var deletions: [String] = []
        let old = original.serializedValues()
        for (key, value) in serializedValues().sorted(by: { $0.key < $1.key }) where value != (old[key] ?? nil) {
            if let value { parameters[key] = .string(value) } else { deletions.append(key) }
        }
        let oldLists = original.serializedLists()
        for (key, list) in serializedLists().sorted(by: { $0.key < $1.key }) where list != (oldLists[key] ?? []) {
            if list.isEmpty { deletions.append(key) } else { for item in list { parameters.append(key, .string(item)) } }
        }
        if let secret = secretParameter { parameters[secret.name] = .string(secret.value) }
        if !deletions.isEmpty { parameters["delete"] = .string(deletions.joined(separator: ",")) }
        return parameters
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, let problem = NotificationNames.problem(name) { problems["name"] = problem }
        let hasRecipients = !Self.list(mailto).isEmpty || !Self.list(mailtoUsers).isEmpty
        switch type {
        case .sendmail:
            if !hasRecipients { problems["mailto"] = String(localized: "Add an address or a user.") }
        case .smtp:
            if Self.text(server) == nil { problems["server"] = String(localized: "Enter the SMTP server.") }
            if Self.text(fromAddress) == nil { problems["from-address"] = String(localized: "Enter the sender address.") }
            if !hasRecipients { problems["mailto"] = String(localized: "Add an address or a user.") }
            if let port = Self.text(port), !(Int(port).map { (1...65535).contains($0) } ?? false) {
                problems["port"] = String(localized: "Enter a port from 1 to 65535.")
            }
        case .gotify:
            if Self.text(server) == nil { problems["server"] = String(localized: "Enter the Gotify server URL.") }
            if isNew, Self.text(secret) == nil { problems["token"] = String(localized: "Enter the application token.") }
        case .webhook:
            if Self.text(url) == nil { problems["url"] = String(localized: "Enter the URL.") }
            if (headers + secrets).contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.value.isEmpty }) {
                problems["header"] = String(localized: "Give every header and secret a name.")
            }
        }
        return problems
    }
}

enum NotificationNames {
    /// Names are configuration IDs: a letter, then letters, digits, `-` and `_`.
    static func problem(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return String(localized: "Enter a name.") }
        guard name.first?.isLetter == true, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return String(localized: "Start with a letter; use letters, digits, - and _ only.")
        }
        return nil
    }
}

/// How bad a notification is.
public enum NotificationSeverity: String, Sendable, CaseIterable, Identifiable {
    case info, notice, warning, error, unknown
    public var id: String { rawValue }
}

/// A rule matching a metadata field: `exact:type=vzdump,replication` or `regex:hostname=^pve`.
public struct MatcherFieldRule: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public var isRegex = false
    public var field = "type"
    /// Exact rules may list several values.
    public var value = ""

    public init(isRegex: Bool = false, field: String = "type", value: String = "") {
        self.isRegex = isRegex
        self.field = field
        self.value = value
    }

    public static func == (lhs: MatcherFieldRule, rhs: MatcherFieldRule) -> Bool {
        lhs.isRegex == rhs.isRegex && lhs.field == rhs.field && lhs.value == rhs.value
    }

    init(parsing text: String) {
        var rest = Substring(text)
        if rest.hasPrefix("regex:") {
            isRegex = true
            rest = rest.dropFirst(6)
        } else if rest.hasPrefix("exact:") {
            rest = rest.dropFirst(6)
        }
        let parts = rest.split(separator: "=", maxSplits: 1)
        field = parts.first.map(String.init) ?? ""
        value = parts.count > 1 ? String(parts[1]) : ""
    }

    var serialized: String? {
        let field = field.trimmingCharacters(in: .whitespaces)
        guard !field.isEmpty else { return nil }
        return "\(isRegex ? "regex" : "exact"):\(field)=\(value.trimmingCharacters(in: .whitespaces))"
    }
}

/// A matcher, from `GET /cluster/notifications/matchers`: which notifications go to which targets.
public struct NotificationMatcher: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var comment: String?
    public var isDisabled: Bool
    public var origin: String
    public var targets: [String]
    public var config: NotificationConfig

    public var id: String { name }
    public var isBuiltIn: Bool { origin != "user-created" }

    public init(from decoder: any Decoder) throws {
        config = try NotificationConfig(from: decoder)
        name = config.values["name"] ?? ""
        comment = config.values["comment"].flatMap { $0.isEmpty ? nil : $0 }
        isDisabled = config.values["disable"] == "1"
        origin = config.values["origin"] ?? "user-created"
        targets = config.lists["target"] ?? config.values["target"].map { [$0] } ?? []
    }
}

/// The settings of a matcher as a form.
public struct NotificationMatcherDraft: Equatable, Sendable {
    public var name = ""
    public var comment = ""
    public var isEnabled = true
    /// `all` or `any` of the rules must match.
    public var matchesAll = true
    public var isInverted = false
    /// Empty matches every severity.
    public var severities: Set<NotificationSeverity> = []
    public var fields: [MatcherFieldRule] = []
    /// Calendar events such as `mon..fri 8-17`.
    public var calendars: [String] = []
    public var targets: Set<String> = []

    public init() {}

    public init(_ matcher: NotificationMatcher) {
        let config = matcher.config
        func list(_ key: String) -> [String] { config.lists[key] ?? config.values[key].map { [$0] } ?? [] }
        name = matcher.name
        comment = matcher.comment ?? ""
        isEnabled = !matcher.isDisabled
        matchesAll = config.values["mode"] != "any"
        isInverted = config.values["invert-match"] == "1"
        severities = Set(list("match-severity").flatMap { $0.split(separator: ",") }.compactMap { NotificationSeverity(rawValue: String($0)) })
        fields = list("match-field").map(MatcherFieldRule.init(parsing:))
        calendars = list("match-calendar")
        targets = Set(matcher.targets)
    }

    func serializedValues() -> [String: String?] {
        let comment = comment.trimmingCharacters(in: .whitespaces)
        return [
            "comment": comment.isEmpty ? nil : comment,
            "disable": isEnabled ? nil : "1",
            "mode": matchesAll ? nil : "any",
            "invert-match": isInverted ? "1" : nil,
        ]
    }

    func serializedLists() -> [String: [String]] {
        let severityList = NotificationSeverity.allCases.filter(severities.contains).map(\.rawValue)
        return [
            "match-severity": severityList.isEmpty ? [] : [severityList.joined(separator: ",")],
            "match-field": fields.compactMap(\.serialized),
            "match-calendar": calendars.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            "target": targets.sorted(),
        ]
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["name": .string(name.trimmingCharacters(in: .whitespaces))]
        for (key, value) in serializedValues().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        for (key, list) in serializedLists().sorted(by: { $0.key < $1.key }) {
            for item in list { parameters.append(key, .string(item)) }
        }
        return parameters
    }

    public func changes(from original: NotificationMatcherDraft) -> APIParameters {
        var parameters = APIParameters()
        var deletions: [String] = []
        let old = original.serializedValues()
        for (key, value) in serializedValues().sorted(by: { $0.key < $1.key }) where value != (old[key] ?? nil) {
            if let value { parameters[key] = .string(value) } else { deletions.append(key) }
        }
        let oldLists = original.serializedLists()
        for (key, list) in serializedLists().sorted(by: { $0.key < $1.key }) where list != (oldLists[key] ?? []) {
            if list.isEmpty { deletions.append(key) } else { for item in list { parameters.append(key, .string(item)) } }
        }
        if !deletions.isEmpty { parameters["delete"] = .string(deletions.joined(separator: ",")) }
        return parameters
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, let problem = NotificationNames.problem(name) { problems["name"] = problem }
        if targets.isEmpty { problems["target"] = String(localized: "Choose at least one target.") }
        if fields.contains(where: { $0.field.trimmingCharacters(in: .whitespaces).isEmpty }) {
            problems["match-field"] = String(localized: "Give every field rule a field.")
        }
        return problems
    }
}

/// A known value of a metadata field, e.g. `type` = `vzdump`, from `GET /cluster/notifications/matcher-field-values`.
public struct MatcherFieldValue: Decodable, Sendable, Equatable, Hashable {
    public var field: String
    public var value: String
    public var comment: String?
}

extension PVE {
    public static func notificationTargets() -> APIRequest<[NotificationTarget]> {
        APIRequest(.get, "/cluster/notifications/targets")
    }

    public static func notificationEndpoint(_ type: NotificationEndpointType, name: String) -> APIRequest<NotificationConfig> {
        APIRequest(.get, "/cluster/notifications/endpoints/\(type.rawValue)/\(escapePath(name))")
    }

    public static func createNotificationEndpoint(_ draft: NotificationEndpointDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/notifications/endpoints/\(draft.type.rawValue)", parameters: draft.creationParameters)
    }

    public static func updateNotificationEndpoint(_ type: NotificationEndpointType, name: String, _ changes: APIParameters, digest: String?) -> APIRequest<Nothing> {
        var parameters = changes
        if let digest { parameters["digest"] = .string(digest) }
        return APIRequest(.put, "/cluster/notifications/endpoints/\(type.rawValue)/\(escapePath(name))", parameters: parameters)
    }

    public static func deleteNotificationEndpoint(_ type: NotificationEndpointType, name: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/notifications/endpoints/\(type.rawValue)/\(escapePath(name))")
    }

    /// Sends a test notification through a target.
    public static func testNotificationTarget(_ name: String) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/notifications/targets/\(escapePath(name))/test")
    }

    public static func notificationMatchers() -> APIRequest<[NotificationMatcher]> {
        APIRequest(.get, "/cluster/notifications/matchers")
    }

    public static func createNotificationMatcher(_ draft: NotificationMatcherDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/notifications/matchers", parameters: draft.creationParameters)
    }

    public static func updateNotificationMatcher(_ name: String, _ changes: APIParameters, digest: String?) -> APIRequest<Nothing> {
        var parameters = changes
        if let digest { parameters["digest"] = .string(digest) }
        return APIRequest(.put, "/cluster/notifications/matchers/\(escapePath(name))", parameters: parameters)
    }

    public static func deleteNotificationMatcher(_ name: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/notifications/matchers/\(escapePath(name))")
    }

    public static func matcherFieldValues() -> APIRequest<[MatcherFieldValue]> {
        APIRequest(.get, "/cluster/notifications/matcher-field-values")
    }
}
