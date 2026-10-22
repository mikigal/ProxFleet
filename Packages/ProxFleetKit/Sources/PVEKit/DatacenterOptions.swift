import Foundation
import ProxmoxCore

/// The datacenter options of `GET /cluster/options`, as text by the names the API uses. Property strings may come
/// as objects; they are turned back into `key=value` text, and lists into `;`-separated text.
public struct DatacenterOptionsConfig: Decodable, Sendable, Hashable {
    public var values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: String] = [:]
        for key in container.allKeys where key.stringValue != "allowed-tags" {
            if let text = container.lossyString(key) {
                values[key.stringValue] = text
            } else if let flag = container.lossyBool(key) {
                values[key.stringValue] = flag ? "1" : "0"
            } else if let list = try? container.decode([String].self, forKey: key) {
                values[key.stringValue] = list.joined(separator: ";")
            } else if let object = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key) {
                var property = PropertyString(items: [])
                for inner in object.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                    if let text = object.lossyString(inner) {
                        property[inner.stringValue] = text
                    } else if let flag = object.lossyBool(inner) {
                        property[inner.stringValue] = flag ? "1" : "0"
                    }
                }
                values[key.stringValue] = property.stringValue
            }
        }
        self.values = values
    }
}

/// The datacenter options as a form. Property strings keep the keys the form does not know.
public struct DatacenterOptionsDraft: Equatable, Sendable {
    /// Empty for the default.
    public var keyboard = ""
    public var language = ""
    /// `html5`, `xtermjs`, `vv` (SPICE) or empty for the default.
    public var console = ""
    public var emailFrom = ""
    public var httpProxy = ""
    public var macPrefix = ""
    public var maxWorkers = ""
    public var consentText = ""
    public var notes = ""
    public var nextIDLower = ""
    public var nextIDUpper = ""
    /// `secure` or `insecure`; empty for the default (secure).
    public var migrationType = ""
    public var migrationNetwork = ""
    /// KiB/s by operation (`default`, `restore`, `migration`, `clone`, `move`); empty for unlimited.
    public var bandwidthLimits: [String: String] = [:]
    /// `full`, `circle`, `dense`, `none` or empty for the default (circle).
    public var tagShape = ""
    /// `config`, `alphabetical` or empty for the default (alphabetical).
    public var tagOrdering = ""
    public var tagsCaseSensitive = false
    /// `none`, `list`, `existing`, `free` or empty for the default (free).
    public var userTagAccess = ""
    public var userTagList: [String] = []
    public var registeredTags: [String] = []
    /// `freeze`, `failover`, `conditional`, `migrate` or empty for the default (conditional).
    public var haShutdownPolicy = ""
    /// `basic`, `static` or empty for the default (basic).
    public var haScheduler = ""

    private var otherMigration = PropertyString(items: [])
    private var otherNextID = PropertyString(items: [])
    private var otherBandwidth = PropertyString(items: [])
    private var otherTagStyle = PropertyString(items: [])
    private var otherTagAccess = PropertyString(items: [])
    private var otherHA = PropertyString(items: [])
    private var otherCRS = PropertyString(items: [])

    public static let bandwidthOperations = ["default", "restore", "migration", "clone", "move"]
    public static let keyboards = ["de", "de-ch", "da", "en-gb", "en-us", "es", "fi", "fr", "fr-be", "fr-ca", "fr-ch", "hu", "is", "it",
                                   "ja", "lt", "mk", "nl", "no", "pl", "pt", "pt-br", "sv", "sl", "tr"]
    public static let languages = ["ar", "ca", "da", "de", "en", "es", "eu", "fa", "fr", "hr", "he", "it", "ja", "ka", "kr", "nb", "nl",
                                   "nn", "pl", "pt_BR", "ru", "sl", "sv", "tr", "ukr", "zh_CN", "zh_TW"]

    public init() {}

    public init(_ config: DatacenterOptionsConfig) {
        let values = config.values
        keyboard = values["keyboard"] ?? ""
        language = values["language"] ?? ""
        console = values["console"] ?? ""
        emailFrom = values["email_from"] ?? ""
        httpProxy = values["http_proxy"] ?? ""
        macPrefix = values["mac_prefix"] ?? ""
        maxWorkers = values["max_workers"] ?? ""
        consentText = values["consent-text"] ?? ""
        notes = values["description"] ?? ""
        registeredTags = Self.tags(values["registered-tags"])

        var migration = PropertyString(parsing: values["migration"] ?? "")
        migrationType = Self.take("type", from: &migration, default: true) ?? ""
        migrationNetwork = Self.take("network", from: &migration) ?? ""
        otherMigration = migration

        var nextID = PropertyString(parsing: values["next-id"] ?? "")
        nextIDLower = Self.take("lower", from: &nextID) ?? ""
        nextIDUpper = Self.take("upper", from: &nextID) ?? ""
        otherNextID = nextID

        var bandwidth = PropertyString(parsing: values["bwlimit"] ?? "")
        for operation in Self.bandwidthOperations {
            if let value = Self.take(operation, from: &bandwidth) { bandwidthLimits[operation] = value }
        }
        otherBandwidth = bandwidth

        var tagStyle = PropertyString(parsing: values["tag-style"] ?? "")
        tagShape = Self.take("shape", from: &tagStyle) ?? ""
        tagOrdering = Self.take("ordering", from: &tagStyle) ?? ""
        tagsCaseSensitive = Self.take("case-sensitive", from: &tagStyle) == "1"
        otherTagStyle = tagStyle

        var tagAccess = PropertyString(parsing: values["user-tag-access"] ?? "")
        userTagAccess = Self.take("user-allow", from: &tagAccess) ?? ""
        userTagList = Self.tags(Self.take("user-allow-list", from: &tagAccess))
        otherTagAccess = tagAccess

        var ha = PropertyString(parsing: values["ha"] ?? "")
        haShutdownPolicy = Self.take("shutdown_policy", from: &ha) ?? ""
        otherHA = ha

        var crs = PropertyString(parsing: values["crs"] ?? "")
        haScheduler = Self.take("ha", from: &crs) ?? ""
        otherCRS = crs
    }

    /// Removes a key from a property string and returns its value; `default` also takes a first value without a key.
    private static func take(_ key: String, from property: inout PropertyString, default allowsDefault: Bool = false) -> String? {
        if let value = property[key] {
            property[key] = nil
            return value
        }
        if allowsDefault, let index = property.items.firstIndex(where: { $0.key == nil }) {
            return property.items.remove(at: index).value
        }
        return nil
    }

    private static func tags(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " }).map(String.init)
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A property string of the known keys followed by the unknown ones; nil when empty.
    private static func property(_ known: [(String, String?)], others: PropertyString) -> String? {
        var property = PropertyString(items: [])
        for (key, value) in known {
            if let value { property[key] = value }
        }
        property.items += others.items
        return property.items.isEmpty ? nil : property.stringValue
    }

    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("keyboard", Self.text(keyboard))
        set("language", Self.text(language))
        set("console", Self.text(console))
        set("email_from", Self.text(emailFrom))
        set("http_proxy", Self.text(httpProxy))
        set("mac_prefix", Self.text(macPrefix))
        set("max_workers", Self.text(maxWorkers))
        set("consent-text", Self.text(consentText))
        set("description", Self.text(notes))
        let registered = registeredTags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        set("registered-tags", registered.isEmpty ? nil : registered.joined(separator: ";"))
        set("migration", Self.property([("type", Self.text(migrationType)), ("network", Self.text(migrationNetwork))], others: otherMigration))
        set("next-id", Self.property([("lower", Self.text(nextIDLower)), ("upper", Self.text(nextIDUpper))], others: otherNextID))
        set("bwlimit", Self.property(Self.bandwidthOperations.map { ($0, bandwidthLimits[$0].flatMap(Self.text)) }, others: otherBandwidth))
        set("tag-style", Self.property([
            ("shape", Self.text(tagShape)), ("ordering", Self.text(tagOrdering)), ("case-sensitive", tagsCaseSensitive ? "1" : nil),
        ], others: otherTagStyle))
        let allowList = userTagList.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        set("user-tag-access", Self.property([
            ("user-allow", Self.text(userTagAccess)), ("user-allow-list", allowList.isEmpty ? nil : allowList.joined(separator: ";")),
        ], others: otherTagAccess))
        set("ha", Self.property([("shutdown_policy", Self.text(haShutdownPolicy))], others: otherHA))
        set("crs", Self.property([("ha", Self.text(haScheduler))], others: otherCRS))
        return values
    }

    /// The changes against the options the form was opened with. Empty when nothing changed.
    public func changes(from original: DatacenterOptionsDraft) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let old = original.serialized()
        for (key, value) in serialized() where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        return update
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if let email = Self.text(emailFrom), !(email.contains("@") && !email.contains(" ")) {
            problems["email_from"] = String(localized: "Enter a valid email address.")
        }
        if let proxy = Self.text(httpProxy), !proxy.hasPrefix("http://") {
            problems["http_proxy"] = String(localized: "Enter a URL starting with http://.")
        }
        if let prefix = Self.text(macPrefix) {
            let pairs = prefix.split(separator: ":", omittingEmptySubsequences: false)
            let valid = (1...5).contains(pairs.count) && pairs.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
            if !valid {
                problems["mac_prefix"] = String(localized: "Enter hexadecimal pairs separated by colons, e.g. BC:24:11.")
            } else if let first = UInt8(pairs[0], radix: 16), first & 1 == 1 {
                problems["mac_prefix"] = String(localized: "The first byte must be even: odd ones are multicast addresses.")
            }
        }
        let lower = Self.text(nextIDLower).flatMap { Int($0) }
        let upper = Self.text(nextIDUpper).flatMap { Int($0) }
        if (Self.text(nextIDLower) != nil && lower.map({ $0 < 100 }) != false) || (Self.text(nextIDUpper) != nil && upper == nil) {
            problems["next-id"] = String(localized: "Use whole numbers, from 100.")
        } else if let lower, let upper, upper <= lower {
            problems["next-id"] = String(localized: "The upper limit must be above the lower one.")
        }
        if Self.bandwidthOperations.contains(where: { operation in
            bandwidthLimits[operation].flatMap(Self.text).map { Double($0).map { $0 < 0 } ?? true } ?? false
        }) {
            problems["bwlimit"] = String(localized: "Use numbers of 0 or more, or leave fields empty.")
        }
        if let workers = Self.text(maxWorkers), !(Int(workers).map { $0 >= 1 } ?? false) {
            problems["max_workers"] = String(localized: "Use a whole number of 1 or more.")
        }
        return problems
    }
}

extension PVE {
    public static func datacenterOptions() -> APIRequest<DatacenterOptionsConfig> {
        APIRequest(.get, "/cluster/options")
    }

    public static func updateDatacenterOptions(_ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/cluster/options", parameters: update.parameters)
    }
}
