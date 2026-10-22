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
    /// `basic`, `static`, `dynamic` or empty for the default (basic).
    public var haScheduler = ""
    public var haRebalanceOnStart = false
    public var haAutoRebalance = false
    /// Percent of node imbalance that starts automatic rebalancing; empty for the default (30).
    public var haRebalanceThreshold = ""
    /// Minimum improvement in percent; empty for the default (10).
    public var haRebalanceMargin = ""
    /// HA rounds the imbalance has to last; empty for the default (3).
    public var haRebalanceHoldDuration = ""
    /// `bruteforce`, `topsis` or empty for the default (bruteforce).
    public var haRebalanceMethod = ""
    /// `watchdog`, `hardware`, `both` or empty for the default (watchdog).
    public var fencing = ""
    /// Tags with their own colors in the web interface.
    public var tagColors: [TagColor] = []
    /// `secure` or `insecure`; empty for the default (secure).
    public var replicationType = ""
    public var replicationNetwork = ""
    /// WebAuthn relying party name, ID (the domain) and origin.
    public var webauthnName = ""
    public var webauthnID = ""
    public var webauthnOrigin = ""
    public var webauthnAllowsSubdomains = true
    public var u2fAppID = ""
    public var u2fOrigin = ""
    public var location = Location()

    private var otherMigration = PropertyString(items: [])
    private var otherNextID = PropertyString(items: [])
    private var otherBandwidth = PropertyString(items: [])
    private var otherTagStyle = PropertyString(items: [])
    private var otherTagAccess = PropertyString(items: [])
    private var otherHA = PropertyString(items: [])
    private var otherCRS = PropertyString(items: [])
    private var otherReplication = PropertyString(items: [])
    private var otherWebauthn = PropertyString(items: [])
    private var otherU2F = PropertyString(items: [])

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
        var tagStyleRest = tagStyle

        var tagAccess = PropertyString(parsing: values["user-tag-access"] ?? "")
        userTagAccess = Self.take("user-allow", from: &tagAccess) ?? ""
        userTagList = Self.tags(Self.take("user-allow-list", from: &tagAccess))
        otherTagAccess = tagAccess

        var ha = PropertyString(parsing: values["ha"] ?? "")
        haShutdownPolicy = Self.take("shutdown_policy", from: &ha) ?? ""
        otherHA = ha

        var crs = PropertyString(parsing: values["crs"] ?? "")
        haScheduler = Self.take("ha", from: &crs) ?? ""
        haRebalanceOnStart = Self.take("ha-rebalance-on-start", from: &crs) == "1"
        haAutoRebalance = Self.take("ha-auto-rebalance", from: &crs) == "1"
        haRebalanceThreshold = Self.take("ha-auto-rebalance-threshold", from: &crs) ?? ""
        haRebalanceMargin = Self.take("ha-auto-rebalance-margin", from: &crs) ?? ""
        haRebalanceHoldDuration = Self.take("ha-auto-rebalance-hold-duration", from: &crs) ?? ""
        haRebalanceMethod = Self.take("ha-auto-rebalance-method", from: &crs) ?? ""
        otherCRS = crs

        fencing = values["fencing"] ?? ""
        tagColors = TagColor.parse(Self.take("color-map", from: &tagStyleRest))
        otherTagStyle = tagStyleRest

        var replication = PropertyString(parsing: values["replication"] ?? "")
        replicationType = Self.take("type", from: &replication, default: true) ?? ""
        replicationNetwork = Self.take("network", from: &replication) ?? ""
        otherReplication = replication

        var webauthn = PropertyString(parsing: values["webauthn"] ?? "")
        webauthnName = Self.take("rp", from: &webauthn) ?? ""
        webauthnID = Self.take("id", from: &webauthn) ?? ""
        webauthnOrigin = Self.take("origin", from: &webauthn) ?? ""
        webauthnAllowsSubdomains = Self.take("allow-subdomains", from: &webauthn) != "0"
        otherWebauthn = webauthn

        var u2f = PropertyString(parsing: values["u2f"] ?? "")
        u2fAppID = Self.take("appid", from: &u2f) ?? ""
        u2fOrigin = Self.take("origin", from: &u2f) ?? ""
        otherU2F = u2f

        location = Location(values["location"])
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
            ("color-map", TagColor.serialize(tagColors)),
        ], others: otherTagStyle))
        let allowList = userTagList.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        set("user-tag-access", Self.property([
            ("user-allow", Self.text(userTagAccess)), ("user-allow-list", allowList.isEmpty ? nil : allowList.joined(separator: ";")),
        ], others: otherTagAccess))
        set("ha", Self.property([("shutdown_policy", Self.text(haShutdownPolicy))], others: otherHA))
        set("crs", Self.property([
            ("ha", Self.text(haScheduler)), ("ha-rebalance-on-start", haRebalanceOnStart ? "1" : nil), ("ha-auto-rebalance", haAutoRebalance ? "1" : nil),
            ("ha-auto-rebalance-threshold", Self.text(haRebalanceThreshold)), ("ha-auto-rebalance-margin", Self.text(haRebalanceMargin)),
            ("ha-auto-rebalance-hold-duration", Self.text(haRebalanceHoldDuration)), ("ha-auto-rebalance-method", Self.text(haRebalanceMethod)),
        ], others: otherCRS))
        set("fencing", Self.text(fencing))
        set("replication", Self.property([("type", Self.text(replicationType)), ("network", Self.text(replicationNetwork))], others: otherReplication))
        set("webauthn", Self.property([
            ("rp", Self.text(webauthnName)), ("id", Self.text(webauthnID)), ("origin", Self.text(webauthnOrigin)),
            ("allow-subdomains", webauthnAllowsSubdomains ? nil : "0"),
        ], others: otherWebauthn))
        set("u2f", Self.property([("appid", Self.text(u2fAppID)), ("origin", Self.text(u2fOrigin))], others: otherU2F))
        set("location", location.serialized)
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
        if let problem = TagColor.problem(tagColors) { problems["tag-style"] = problem }
        if [haRebalanceThreshold, haRebalanceMargin, haRebalanceHoldDuration].contains(where: { text in
            Self.text(text).map { Double($0).map { $0 < 0 } ?? true } ?? false
        }) {
            problems["crs"] = String(localized: "Use numbers of 0 or more, or leave fields empty.")
        }
        if let origin = Self.text(webauthnOrigin), !(origin.hasPrefix("https://") || origin.hasPrefix("http://localhost")) {
            problems["webauthn"] = String(localized: "The origin is an https:// address, as typed in the browser.")
        } else if let id = Self.text(webauthnID), id.contains("/") || id.contains(":") {
            problems["webauthn"] = String(localized: "The ID is a domain name only, without protocol or port.")
        }
        if let origin = Self.text(u2fOrigin), !origin.hasPrefix("https://") {
            problems["u2f"] = String(localized: "The origin is an https:// address.")
        }
        if let problem = location.problem { problems["location"] = problem }
        return problems
    }

    /// Fills the WebAuthn settings for an address users type into the browser, as the web interface's Auto-Fill.
    public mutating func fillWebauthn(host: String, port: Int) {
        webauthnName = host
        webauthnID = host
        webauthnOrigin = port == 443 ? "https://\(host)" : "https://\(host):\(port)"
    }
}

/// A tag with its own background and optionally text color, from `tag-style`'s `color-map`.
public struct TagColor: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var tag: String
    /// Hexadecimal `RRGGBB`.
    public var background: String
    /// Empty to let the web interface pick a readable color.
    public var text: String

    public init(tag: String, background: String, text: String = "") {
        self.tag = tag
        self.background = background
        self.text = text
    }

    public static func == (lhs: TagColor, rhs: TagColor) -> Bool {
        (lhs.tag, lhs.background, lhs.text) == (rhs.tag, rhs.background, rhs.text)
    }

    /// `prod:FF0000;web:00AA00:FFFFFF`.
    static func parse(_ text: String?) -> [TagColor] {
        (text ?? "").split(separator: ";").compactMap { item in
            let parts = item.split(separator: ":").map(String.init)
            guard parts.count >= 2 else { return nil }
            return TagColor(tag: parts[0], background: parts[1].uppercased(), text: parts.count > 2 ? parts[2].uppercased() : "")
        }
    }

    static func serialize(_ colors: [TagColor]) -> String? {
        let items = colors.filter { !$0.tag.trimmingCharacters(in: .whitespaces).isEmpty }.map { color in
            ([color.tag.trimmingCharacters(in: .whitespaces), color.background] + (color.text.isEmpty ? [] : [color.text])).joined(separator: ":")
        }
        return items.isEmpty ? nil : items.joined(separator: ";")
    }

    static func problem(_ colors: [TagColor]) -> String? {
        let isHex = { (text: String) in text.count == 6 && text.allSatisfy(\.isHexDigit) }
        for color in colors where !color.tag.trimmingCharacters(in: .whitespaces).isEmpty {
            if !isHex(color.background) || !(color.text.isEmpty || isHex(color.text)) {
                return String(localized: "Colors are six hexadecimal digits, e.g. 2E7D32.")
            }
        }
        return nil
    }
}

/// `latitude=…,longitude=…[,name=…]` of the datacenter's or a node's `location`.
public struct Location: Equatable, Sendable {
    public var latitude = ""
    public var longitude = ""
    public var name = ""

    public init() {}

    public init(_ text: String?) {
        let property = PropertyString(parsing: text ?? "")
        latitude = property["latitude"] ?? ""
        longitude = property["longitude"] ?? ""
        name = property["name"] ?? ""
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// nil when no coordinates are set.
    public var serialized: String? {
        guard let latitude = Self.text(latitude), let longitude = Self.text(longitude) else { return nil }
        var property = PropertyString(items: [])
        property["latitude"] = latitude
        property["longitude"] = longitude
        if let name = Self.text(name) { property["name"] = name }
        return property.stringValue
    }

    public var problem: String? {
        let latitude = Self.text(latitude), longitude = Self.text(longitude)
        if latitude == nil && longitude == nil {
            return Self.text(name) == nil ? nil : String(localized: "A location needs coordinates.")
        }
        guard let lat = latitude.flatMap(Double.init), (-90...90).contains(lat), let lon = longitude.flatMap(Double.init), (-180...180).contains(lon) else {
            return String(localized: "Use a latitude from -90 to 90 and a longitude from -180 to 180, with a dot for decimals.")
        }
        if Self.text(name)?.contains(",") == true { return String(localized: "The name cannot contain commas.") }
        return nil
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
