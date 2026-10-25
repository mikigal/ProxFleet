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

/// Unique task ID with hex numbers. Proxmox VE writes `UPID:node:pid:pstart:starttime:type:id:user:`; Proxmox Backup
/// Server adds a task number before the start time, `UPID:node:pid:pstart:task:starttime:type:id:user:`, and escapes
/// the ID like a systemd unit name (`store1\x3act-200` for `store1:ct/200`).
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
        guard parts.count >= 8, parts[0] == "UPID" else { return nil }
        // Neither product lets a part contain ":", so the count tells them apart: 9 parts for Proxmox VE (the last
        // one empty after the closing ":"), 10 for Proxmox Backup Server.
        let isBackupServer = parts.count >= 10
        let offset = isBackupServer ? 1 : 0
        guard let start = UInt64(parts[4 + offset], radix: 16) else { return nil }
        self.rawValue = rawValue
        node = parts[1]
        type = parts[5 + offset]
        objectID = isBackupServer ? Self.unescape(parts[6 + offset]) : parts[6]
        // User IDs of API tokens contain a "!" but no ":", so the user is always one part.
        user = parts[7 + offset]
        startTime = Date(timeIntervalSince1970: TimeInterval(start))
    }

    public var description: String { rawValue }

    /// Reverses systemd's unit name escaping, which Proxmox Backup Server uses for task IDs: `-` stands for `/`,
    /// and `\xNN` for any other character that needs escaping, such as `:` or `-` itself.
    static func unescape(_ text: String) -> String {
        var bytes: [UInt8] = []
        var characters = Array(text.utf8)[...]
        while let byte = characters.popFirst() {
            if byte == UInt8(ascii: "-") {
                bytes.append(UInt8(ascii: "/"))
            } else if byte == UInt8(ascii: "\\"), characters.first == UInt8(ascii: "x"), characters.count >= 3,
                      let value = UInt8(String(decoding: characters.dropFirst().prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(value)
                characters = characters.dropFirst(3)
            } else {
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
