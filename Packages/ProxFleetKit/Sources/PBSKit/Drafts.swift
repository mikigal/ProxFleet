import Foundation
import ProxmoxCore

/// Settings to change on the backup server: values to set, settings to clear, and the digest of the configuration
/// the form was opened with. Proxmox Backup Server takes `delete` as a list, so each cleared setting is its own
/// parameter.
public struct BackupServerConfigUpdate: Sendable, Equatable {
    public var values: [String: String] = [:]
    public var deletions: Set<String> = []
    public var digest: String?

    public init(digest: String? = nil) {
        self.digest = digest
    }

    public var isEmpty: Bool { values.isEmpty && deletions.isEmpty }

    /// Sets a setting, or clears it when `value` is nil.
    public mutating func set(_ key: String, _ value: String?) {
        if let value {
            values[key] = value
            deletions.remove(key)
        } else {
            values[key] = nil
            deletions.insert(key)
        }
    }

    public var parameters: APIParameters {
        var parameters = APIParameters()
        for key in values.keys.sorted() {
            parameters[key] = .string(values[key]!)
        }
        for key in deletions.sorted() {
            parameters.append("delete", .string(key))
        }
        if let digest { parameters["digest"] = .string(digest) }
        return parameters
    }
}

/// A form that edits a configuration object. The draft and the original serialize the same way, so only settings
/// the user changed are sent, even when the server stores defaults differently.
public protocol BackupServerDraft: Equatable {
    /// The settings the form manages; nil means "not set", which is the server's default.
    func serialized() -> [String: String?]
}

extension BackupServerDraft {
    public func changes(from original: Self, digest: String? = nil) -> BackupServerConfigUpdate {
        var update = BackupServerConfigUpdate(digest: digest)
        let old = original.serialized()
        for (key, value) in serialized() where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        return update
    }

    /// The set settings as parameters of a creation call.
    var creationValues: APIParameters {
        var parameters = APIParameters()
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value, !value.isEmpty { parameters[key] = .string(value) }
        }
        return parameters
    }
}

/// An ordered property string whose known keys a form edits while the others are kept, e.g. datastore tuning.
public struct PropertyMap: Sendable, Equatable {
    public private(set) var items: [(key: String, value: String)] = []

    public init(parsing text: String?) {
        items = PropertyString(parsing: text ?? "").items.compactMap { item in item.key.map { ($0, item.value) } }
    }

    public subscript(key: String) -> String? {
        get { items.first { $0.key == key }?.value }
        set {
            let value = newValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            if let index = items.firstIndex(where: { $0.key == key }) {
                if let value { items[index].value = value } else { items.remove(at: index) }
            } else if let value {
                items.append((key, value))
            }
        }
    }

    /// The text, or nil when empty so the setting is cleared.
    public var stringValue: String? {
        items.isEmpty ? nil : items.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    public static func == (lhs: PropertyMap, rhs: PropertyMap) -> Bool {
        lhs.items.elementsEqual(rhs.items) { $0.key == $1.key && $0.value == $1.value }
    }
}

extension RetentionPolicy {
    /// The rules as settings: an unset or zero rule clears its `keep-*` setting.
    var serialized: [String: String?] {
        var values: [String: String?] = [:]
        for (key, value) in zip(Self.keys, self.values) {
            // `updateValue`, as assigning nil would drop the key instead of marking the rule as cleared.
            values.updateValue(value.flatMap { $0 > 0 ? String($0) : nil }, forKey: key)
        }
        return values
    }
}
