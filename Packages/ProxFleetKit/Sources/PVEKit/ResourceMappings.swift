import Foundation
import ProxmoxCore

/// The kinds of cluster resource mappings: names for host devices and directories that guests use instead of
/// node-specific paths, so they keep working on every node with a mapping.
public enum ResourceMappingKind: String, CaseIterable, Sendable, Identifiable {
    case pci, usb, dir

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pci: String(localized: "PCI Devices")
        case .usb: String(localized: "USB Devices")
        case .dir: String(localized: "Directories")
        }
    }
}

/// A mapping with its node entries, from `GET /cluster/mapping/{kind}?check-node=`.
public struct ResourceMappingDetail: Decodable, Sendable, Equatable, Identifiable {
    public struct Check: Sendable, Equatable, Hashable {
        /// `warning` or `error`.
        public var severity: String
        public var message: String
    }

    public var id: String
    public var description: String?
    /// One property string per node and device, e.g. `node=pve,path=0000:01:00.0,id=10de:2204`.
    public var entries: [PropertyString]
    /// Problems the server found on the checked node.
    public var checks: [Check]
    public var mdev: Bool
    public var liveMigration: Bool
    public var digest: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = container.lossyString(AnyCodingKey("id")) ?? ""
        description = container.lossyString(AnyCodingKey("description")).flatMap { $0.isEmpty ? nil : $0 }
        entries = ((try? container.decode([String].self, forKey: AnyCodingKey("map"))) ?? []).map(PropertyString.init(parsing:))
        mdev = container.lossyBool(AnyCodingKey("mdev")) ?? false
        liveMigration = container.lossyBool(AnyCodingKey("live-migration-capable")) ?? false
        digest = container.lossyString(AnyCodingKey("digest"))
        // PCI and directory mappings list `checks`; USB mappings `errors` of the same shape.
        var checks: [Check] = []
        for key in ["checks", "errors"] {
            guard var list = try? container.nestedUnkeyedContainer(forKey: AnyCodingKey(key)) else { continue }
            while !list.isAtEnd {
                guard let item = try? list.nestedContainer(keyedBy: AnyCodingKey.self) else { break }
                checks.append(Check(severity: item.lossyString(AnyCodingKey("severity")) ?? "error",
                                    message: (item.lossyString(AnyCodingKey("message")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        self.checks = checks
    }

    public func entries(on node: String) -> [PropertyString] {
        entries.filter { $0["node"] == node }
    }

    /// Nodes with an entry, in order.
    public var nodes: [String] {
        var seen = Set<String>()
        return entries.compactMap { $0["node"] }.filter { seen.insert($0).inserted }
    }
}

/// The form for a mapping. Entries of nodes the form does not edit are kept as they are.
public struct ResourceMappingDraft: Equatable, Sendable {
    public var kind: ResourceMappingKind
    public var id = ""
    public var description = ""
    /// PCI: the devices offer mediated devices (vGPU), or can be live-migrated (experimental).
    public var mdev = false
    public var liveMigration = false
    public var entries: [PropertyString] = []

    public init(kind: ResourceMappingKind) {
        self.kind = kind
    }

    public init(kind: ResourceMappingKind, _ mapping: ResourceMappingDetail) {
        self.kind = kind
        id = mapping.id
        description = mapping.description ?? ""
        mdev = mapping.mdev
        liveMigration = mapping.liveMigration
        entries = mapping.entries
    }

    public func entries(on node: String) -> [PropertyString] {
        entries.filter { $0["node"] == node }
    }

    /// Replaces the entries of one node.
    public mutating func setEntries(_ new: [PropertyString], on node: String) {
        let firstIndex = entries.firstIndex { $0["node"] == node } ?? entries.endIndex
        entries.removeAll { $0["node"] == node }
        entries.insert(contentsOf: new, at: min(firstIndex, entries.endIndex))
    }

    /// A host PCI device, or with `allFunctions` its whole slot (`0000:01:00`), as the web interface maps it.
    public static func pciEntry(_ device: NodePCIDevice, node: String, allFunctions: Bool = false) -> PropertyString {
        var entry = PropertyString(items: [])
        entry["node"] = node
        entry["path"] = allFunctions ? String(device.id.dropLast(2)) : device.id
        entry["id"] = device.vendorDeviceID
        entry["subsystem-id"] = device.subsystemID
        if let group = device.iommuGroup, group != -1 { entry["iommugroup"] = String(group) }
        return entry
    }

    /// A USB device by its vendor and product ID, or whatever is plugged into a port.
    public static func usbEntry(_ device: NodeUSBDevice, node: String, byPort: Bool) -> PropertyString {
        var entry = PropertyString(items: [])
        entry["node"] = node
        entry["id"] = device.deviceID
        if byPort { entry["path"] = device.portID }
        return entry
    }

    public static func directoryEntry(_ path: String, node: String) -> PropertyString {
        var entry = PropertyString(items: [])
        entry["node"] = node
        entry["path"] = path.trimmingCharacters(in: .whitespaces)
        return entry
    }

    private var options: [String: String?] {
        var values: [String: String?] = [:]
        values.updateValue(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "description")
        if kind == .pci {
            values.updateValue(mdev ? "1" : nil, forKey: "mdev")
            values.updateValue(liveMigration ? "1" : nil, forKey: "live-migration-capable")
        }
        return values
    }

    var creationParameters: APIParameters {
        var parameters: APIParameters = ["id": .string(id.trimmingCharacters(in: .whitespaces))]
        for (key, value) in options.sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        for entry in entries { parameters.append("map", .string(entry.stringValue)) }
        return parameters
    }

    /// The changed settings; the whole map is sent again when any entry changed.
    public func changes(from original: ResourceMappingDraft) -> APIParameters {
        var parameters = APIParameters()
        var deletions: [String] = []
        let old = original.options
        for (key, value) in options.sorted(by: { $0.key < $1.key }) where value != (old[key] ?? nil) {
            if let value { parameters[key] = .string(value) } else { deletions.append(key) }
        }
        if entries.map(\.stringValue) != original.entries.map(\.stringValue) {
            for entry in entries { parameters.append("map", .string(entry.stringValue)) }
        }
        if !deletions.isEmpty { parameters["delete"] = .string(deletions.joined(separator: ",")) }
        return parameters
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew {
            let id = id.trimmingCharacters(in: .whitespaces)
            let valid = id.first?.isLetter == true && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)) }
            if !valid { problems["id"] = String(localized: "Start with a letter and use letters, digits, - and _.") }
        }
        if entries.isEmpty {
            problems["map"] = kind == .dir ? String(localized: "Enter the directory on at least one node.") : String(localized: "Choose a device on at least one node.")
        } else if kind == .dir, entries.contains(where: { !($0["path"]?.hasPrefix("/") ?? false) }) {
            problems["map"] = String(localized: "Use absolute paths, starting with /.")
        }
        return problems
    }
}

extension PVE {
    /// With `checkNode`, each mapping lists the problems of its entries on that node.
    public static func resourceMappingDetails(_ kind: ResourceMappingKind, checkNode: String?) -> APIRequest<[ResourceMappingDetail]> {
        APIRequest(.get, "/cluster/mapping/\(kind.rawValue)", parameters: checkNode.map { ["check-node": .string($0)] } ?? [:])
    }

    public static func createResourceMapping(_ draft: ResourceMappingDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/mapping/\(draft.kind.rawValue)", parameters: draft.creationParameters)
    }

    public static func updateResourceMapping(_ kind: ResourceMappingKind, id: String, _ changes: APIParameters, digest: String?) -> APIRequest<Nothing> {
        var parameters = changes
        if let digest { parameters["digest"] = .string(digest) }
        return APIRequest(.put, "/cluster/mapping/\(kind.rawValue)/\(escapePath(id))", parameters: parameters)
    }

    public static func deleteResourceMapping(_ kind: ResourceMappingKind, id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/mapping/\(kind.rawValue)/\(escapePath(id))")
    }
}
