import Foundation
import ProxmoxCore

/// One parameter of an API method, or one key of a property-string format, from the API schema.
public struct SchemaParameter: Sendable, Identifiable, Equatable {
    /// `args`, or `numa[n]` for indexed keys (`numa0`, `numa1`…).
    public let name: String
    public let type: String
    public let description: String?
    public let isOptional: Bool
    public let defaultValue: String?
    public let enumValues: [String]?
    /// Labels for enum values, from the `value;; label` lines of the long description, e.g. `l26` → "Linux 2.6 - 7.X Kernel".
    public let enumDescriptions: [String: String]
    public let minimum: Double?
    public let maximum: Double?
    public let typeText: String?
    /// Keys of a property string, when the value is one.
    public let properties: [SchemaParameter]?
    /// For property keys: written without `key=` when first.
    public let isDefaultKey: Bool
    /// Uses the `model=MAC` shorthand, which only a text field can edit faithfully.
    public let hasKeyAliases: Bool

    public var id: String { name }
    public var isIndexed: Bool { name.hasSuffix("[n]") }
    /// `numa` for `numa[n]`.
    public var keyPrefix: String { isIndexed ? String(name.dropLast(3)) : name }

    /// Whether a configuration key belongs to this parameter, e.g. `numa1` to `numa[n]`.
    public func matches(key: String) -> Bool {
        guard isIndexed else { return key == name }
        return key.hasPrefix(keyPrefix) && !key.dropFirst(keyPrefix.count).isEmpty && key.dropFirst(keyPrefix.count).allSatisfy(\.isNumber)
    }

    init(name: String, json: [String: Any]) {
        self.name = name
        type = json["type"] as? String ?? "string"
        description = (json["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        isOptional = Self.flag(json["optional"])
        defaultValue = json["default"].flatMap(Self.text)
        enumValues = json["enum"] as? [String]
        enumDescriptions = Self.enumDescriptions(in: json["verbose_description"] as? String)
        minimum = json["minimum"].flatMap(Self.number)
        maximum = json["maximum"].flatMap(Self.number)
        typeText = json["typetext"] as? String ?? json["format_description"] as? String
        isDefaultKey = Self.flag(json["default_key"])
        if let format = json["format"] as? [String: [String: Any]] {
            hasKeyAliases = format.values.contains { $0["keyAlias"] != nil }
            properties = format
                .filter { $0.value["alias"] == nil }
                .map { SchemaParameter(name: $0.key, json: $0.value) }
                .sorted { ($0.isDefaultKey ? 0 : 1, $0.name) < ($1.isDefaultKey ? 0 : 1, $1.name) }
        } else {
            hasKeyAliases = false
            properties = nil
        }
    }

    static func enumDescriptions(in text: String?) -> [String: String] {
        var result: [String: String] = [:]
        for line in (text ?? "").split(separator: "\n") {
            let parts = line.components(separatedBy: ";;")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let label = parts[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !key.contains(" "), !label.isEmpty { result[key] = label }
        }
        return result
    }

    private static func flag(_ value: Any?) -> Bool {
        (value as? Bool) ?? ((value as? Int).map { $0 != 0 } ?? false)
    }

    private static func number(_ value: Any) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    private static func text(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

/// The parts of the Proxmox API schema the app uses, read from the API viewer's `apidoc.js`.
public struct APISchema: Sendable {
    public let vmConfig: [SchemaParameter]
    public let containerConfig: [SchemaParameter]

    /// Parameters of the config methods that are not configuration keys.
    static let requestOnly: Set<String> = [
        "delete", "digest", "revert", "node", "vmid", "force", "skiplock", "background_delay", "import-working-storage",
    ]

    /// Path of the schema file on a Proxmox VE server; it needs no login.
    public static let path = "/pve-docs/api-viewer/apidoc.js"

    public init(apidoc: Data) throws {
        guard let text = String(data: apidoc, encoding: .utf8),
              let start = text.firstIndex(of: "["),
              let end = text.range(of: "\n;", range: start..<text.endIndex)?.lowerBound,
              let tree = try JSONSerialization.jsonObject(with: Data(text[start..<end].utf8)) as? [[String: Any]]
        else { throw ProxmoxError.invalidResponse("unrecognized API schema") }
        vmConfig = Self.parameters(in: tree, path: "/nodes/{node}/qemu/{vmid}/config", method: "POST")
        containerConfig = Self.parameters(in: tree, path: "/nodes/{node}/lxc/{vmid}/config", method: "PUT")
        guard !vmConfig.isEmpty || !containerConfig.isEmpty else { throw ProxmoxError.invalidResponse("API schema without guest configuration") }
    }

    public func config(for kind: GuestKind) -> [SchemaParameter] {
        kind == .virtualMachine ? vmConfig : containerConfig
    }

    private static func parameters(in tree: [[String: Any]], path: String, method: String) -> [SchemaParameter] {
        guard let node = find(path, in: tree),
              let info = (node["info"] as? [String: Any])?[method] as? [String: Any],
              let properties = (info["parameters"] as? [String: Any])?["properties"] as? [String: [String: Any]]
        else { return [] }
        return properties
            .filter { !requestOnly.contains($0.key) }
            .map { SchemaParameter(name: $0.key, json: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func find(_ path: String, in nodes: [[String: Any]]) -> [String: Any]? {
        for node in nodes {
            if node["path"] as? String == path { return node }
            if let children = node["children"] as? [[String: Any]], let match = find(path, in: children) { return match }
        }
        return nil
    }
}

/// Editable form of one configuration value, driven by its schema parameter.
public struct SchemaValueDraft: Sendable, Equatable {
    public let parameter: SchemaParameter
    /// Plain values, or the whole property string when edited as text.
    public var text: String
    /// Property-string values by key; empty means not set.
    public var fields: [String: String]
    public var editsAsText: Bool
    private let original: PropertyString

    public init(parameter: SchemaParameter, value: String?) {
        self.parameter = parameter
        text = value ?? ""
        original = PropertyString(parsing: value ?? "")
        editsAsText = parameter.properties == nil || parameter.hasKeyAliases
        fields = [:]
        for property in parameter.properties ?? [] {
            let value = original[property.name] ?? (property.isDefaultKey ? original.defaultValue : nil)
            if let value { fields[property.name] = value }
        }
    }

    /// The value to store, or nil to remove the key.
    public var value: String? {
        if editsAsText {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var result = original
        for property in parameter.properties ?? [] {
            let new = fields[property.name].flatMap { $0.isEmpty ? nil : $0 }
            if property.isDefaultKey, result.items.first?.key == nil, !result.items.isEmpty {
                if let new { result.items[0].value = new } else { result.items.removeFirst() }
            } else {
                result[property.name] = new
            }
        }
        return result.items.isEmpty ? nil : result.stringValue
    }

    /// A problem with a plain value, such as a number out of range.
    public var validationMessage: String? {
        guard editsAsText, parameter.properties == nil, !text.isEmpty else { return nil }
        return Self.validate(text, against: parameter)
    }

    static func validate(_ text: String, against parameter: SchemaParameter) -> String? {
        switch parameter.type {
        case "integer", "number":
            guard let number = Double(text), parameter.type == "number" || number == number.rounded() else {
                return String(localized: "Enter a number.")
            }
            if let minimum = parameter.minimum, number < minimum { return String(localized: "At least \(CPUDraft.number(minimum)).") }
            if let maximum = parameter.maximum, number > maximum { return String(localized: "At most \(CPUDraft.number(maximum)).") }
            return nil
        default:
            return nil
        }
    }
}

extension GuestConfig {
    /// The next unused key for an indexed parameter, e.g. `numa2`.
    public func nextKey(for parameter: SchemaParameter) -> String? {
        guard parameter.isIndexed else { return values[parameter.name] == nil ? parameter.name : nil }
        return nextFreeKey(prefix: parameter.keyPrefix, slots: 256)
    }
}

extension ProxmoxSession {
    /// Loads and parses the API schema of a Proxmox VE server.
    public func apiSchema() async throws -> APISchema {
        try APISchema(apidoc: try await fetchStaticFile(APISchema.path))
    }
}
