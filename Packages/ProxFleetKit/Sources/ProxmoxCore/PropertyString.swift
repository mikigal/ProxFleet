import Foundation

/// A Proxmox property string such as `virtio=BC:24:11:B1:83:AD,bridge=vmbr0` or
/// `local-lvm:vm-100-disk-0,size=4G`, where the first item may omit its key.
public struct PropertyString: Sendable, Equatable {
    public var items: [(key: String?, value: String)]

    public init(items: [(key: String?, value: String)]) {
        self.items = items
    }

    /// Parses the text. Values may be double-quoted to contain commas.
    public init(parsing text: String) {
        var items: [(key: String?, value: String)] = []
        var current = ""
        var inQuotes = false
        var parts: [String] = []
        for character in text {
            switch character {
            case "\"":
                inQuotes.toggle()
            case "," where !inQuotes:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.isEmpty || !parts.isEmpty { parts.append(current) }

        for part in parts where !part.isEmpty {
            if let separator = part.firstIndex(of: "=") {
                items.append((key: String(part[..<separator]), value: String(part[part.index(after: separator)...])))
            } else {
                items.append((key: nil, value: part))
            }
        }
        self.items = items
    }

    /// Value of the first item without a key, e.g. the volume of a disk.
    public var defaultValue: String? {
        items.first { $0.key == nil }?.value
    }

    public subscript(key: String) -> String? {
        get { items.first { $0.key == key }?.value }
        set {
            if let index = items.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    items[index].value = newValue
                } else {
                    items.remove(at: index)
                }
            } else if let newValue {
                items.append((key: key, value: newValue))
            }
        }
    }

    /// The text form, quoting values that contain commas.
    public var stringValue: String {
        items.map { item in
            let value = item.value.contains(",") ? "\"\(item.value)\"" : item.value
            return item.key.map { "\($0)=\(value)" } ?? value
        }.joined(separator: ",")
    }

    public static func == (lhs: PropertyString, rhs: PropertyString) -> Bool {
        lhs.items.elementsEqual(rhs.items) { $0.key == $1.key && $0.value == $1.value }
    }
}

/// Unique task ID: `UPID:node:pid:pstart:starttime:type:id:user:`, with hex numbers.
public struct UPID: Sendable, Hashable, Codable, CustomStringConvertible {
    public var rawValue: String
    public var node: String
    public var type: String
    /// Object the task works on, often a VMID. Empty for node-wide tasks.
    public var objectID: String
    public var user: String
    public var startTime: Date

    public init?(_ rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 8, parts[0] == "UPID", let start = UInt64(parts[4], radix: 16) else { return nil }
        self.rawValue = rawValue
        node = parts[1]
        type = parts[5]
        objectID = parts[6]
        // User IDs of API tokens contain a "!" but no ":", so the user is always one part.
        user = parts[7]
        startTime = Date(timeIntervalSince1970: TimeInterval(start))
    }

    public var description: String { rawValue }
}
