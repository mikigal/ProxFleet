import Foundation
import ProxmoxCore

/// One entry of `GET .../snapshot`. The list also contains `current`, the running state, whose parent is the
/// snapshot it is based on.
public struct GuestSnapshot: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    public var date: Date?
    public var parent: String?
    /// VMs only: the snapshot includes the memory, so a rollback resumes the running VM.
    public var includesRAM: Bool

    public var id: String { name }
    public var isCurrent: Bool { name == Self.currentName }

    public static let currentName = "current"

    public init(name: String, description: String = "", date: Date? = nil, parent: String? = nil, includesRAM: Bool = false) {
        self.name = name
        self.description = description
        self.date = date
        self.parent = parent
        self.includesRAM = includesRAM
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        // Proxmox stores descriptions with a trailing newline.
        description = (container.lossyString(AnyCodingKey("description")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        date = container.lossyDouble(AnyCodingKey("snaptime")).map { Date(timeIntervalSince1970: $0) }
        parent = container.lossyString(AnyCodingKey("parent"))
        includesRAM = container.lossyBool(AnyCodingKey("vmstate")) ?? false
    }

    /// Snapshots as a tree in display order: each snapshot after its parent, siblings oldest first,
    /// with its depth for indentation. `current` comes right after the snapshot it is based on.
    public static func tree(_ snapshots: [GuestSnapshot]) -> [(snapshot: GuestSnapshot, depth: Int)] {
        let names = Set(snapshots.map(\.name))
        let children = Dictionary(grouping: snapshots) { snapshot in
            snapshot.parent.flatMap { names.contains($0) ? $0 : nil } ?? ""
        }
        var result: [(snapshot: GuestSnapshot, depth: Int)] = []
        func visit(_ parent: String, depth: Int) {
            let ordered = (children[parent] ?? []).sorted { lhs, rhs in
                // The current state goes last among siblings, after the snapshots taken from the same point.
                if lhs.isCurrent != rhs.isCurrent { return rhs.isCurrent }
                return (lhs.date ?? .distantPast) < (rhs.date ?? .distantPast)
            }
            for snapshot in ordered {
                result.append((snapshot, depth))
                visit(snapshot.name, depth: depth + 1)
            }
        }
        visit("", depth: 0)
        return result
    }

    /// Proxmox snapshot names start with a letter and use letters, digits, `-` and `_`, at most 40 characters.
    public static func nameProblem(_ name: String, existing: [GuestSnapshot]) -> String? {
        guard let first = name.first else { return String(localized: "Enter a name.") }
        guard first.isASCII, first.isLetter,
              name.count <= 40,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return String(localized: "Start with a letter, then use letters, digits, - and _ only.") }
        if name == currentName || existing.contains(where: { $0.name == name }) {
            return String(localized: "A snapshot with this name already exists.")
        }
        return nil
    }
}

/// Settings for cloning a VM or container.
public struct CloneDraft: Sendable, Equatable {
    public let source: GuestReference
    /// Templates can be cloned as linked clones, which share the template's disks.
    public let sourceIsTemplate: Bool
    public var vmid: Int
    /// VM name or container host name, empty for the default.
    public var name = ""
    public var targetNode: String
    public var fullClone: Bool
    /// Full clones only, empty for the same storage as the source.
    public var storage = ""
    /// VMs, full clones to a chosen storage: the image format, nil for the storage's default.
    public var format: String?
    public var pool = ""
    /// Clones the state of a snapshot instead of the current one. Not possible for templates.
    public var snapshot: String?

    public init(source: GuestReference, isTemplate: Bool, vmid: Int = 0) {
        self.source = source
        sourceIsTemplate = isTemplate
        self.vmid = vmid
        targetNode = source.node
        // Like the web interface: linked clones for templates, which is the point of having them.
        fullClone = !isTemplate
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if !(100...999_999_999).contains(vmid) { problems["newid"] = String(localized: "Use a number from 100 to 999999999.") }
        if !name.isEmpty, !VMCreationDraft.isValidDNSName(name) {
            problems[source.kind == .virtualMachine ? "name" : "hostname"] = String(localized: "Use letters, digits, hyphens and dots only.")
        }
        return problems
    }

    public var parameters: APIParameters {
        var parameters: APIParameters = ["newid": .int(vmid)]
        if !name.isEmpty { parameters[source.kind == .virtualMachine ? "name" : "hostname"] = .string(name) }
        if targetNode != source.node { parameters["target"] = .string(targetNode) }
        // Only templates can be cloned linked; for other guests Proxmox always copies, and rejects `full=0`.
        if sourceIsTemplate { parameters["full"] = .bool(fullClone) }
        if fullClone, !storage.isEmpty {
            parameters["storage"] = .string(storage)
            if source.kind == .virtualMachine, let format { parameters["format"] = .string(format) }
        }
        if !pool.isEmpty { parameters["pool"] = .string(pool) }
        if let snapshot, !sourceIsTemplate { parameters["snapname"] = .string(snapshot) }
        return parameters
    }
}

extension PVE {
    public static func snapshots(_ guest: GuestReference) -> APIRequest<[GuestSnapshot]> {
        APIRequest(.get, guest.path + "/snapshot")
    }

    /// Takes a snapshot. `includeRAM` saves the memory of a running VM as well. Returns a task ID.
    public static func createSnapshot(_ guest: GuestReference, name: String, description: String, includeRAM: Bool) -> APIRequest<String?> {
        var parameters: APIParameters = ["snapname": .string(name)]
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { parameters["description"] = .string(description) }
        if guest.kind == .virtualMachine, includeRAM { parameters["vmstate"] = true }
        return APIRequest(.post, guest.path + "/snapshot", parameters: parameters)
    }

    /// Returns the guest to a snapshot; changes since are lost. Returns a task ID.
    public static func rollbackSnapshot(_ guest: GuestReference, name: String, start: Bool) -> APIRequest<String?> {
        APIRequest(.post, guest.path + "/snapshot/\(escapePath(name))/rollback", parameters: start ? ["start": true] : [:])
    }

    public static func deleteSnapshot(_ guest: GuestReference, name: String) -> APIRequest<String?> {
        APIRequest(.delete, guest.path + "/snapshot/\(escapePath(name))")
    }

    /// Changes the description of a snapshot. Synchronous.
    public static func updateSnapshotDescription(_ guest: GuestReference, name: String, description: String) -> APIRequest<String?> {
        APIRequest(.put, guest.path + "/snapshot/\(escapePath(name))/config", parameters: ["description": .string(description.trimmingCharacters(in: .whitespacesAndNewlines))])
    }

    /// Clones a guest. Returns the task ID.
    public static func clone(_ draft: CloneDraft) -> APIRequest<String> {
        APIRequest(.post, draft.source.path + "/clone", parameters: draft.parameters)
    }

    /// Turns a stopped guest into a template. VMs return a task ID, containers finish right away.
    public static func convertToTemplate(_ guest: GuestReference) -> APIRequest<String?> {
        APIRequest(.post, guest.path + "/template")
    }

    /// Deletes a stopped guest and its disks. `purge` also removes it from backup and replication jobs, HA and
    /// permissions; `destroyUnreferencedDisks` removes disks with its ID that its configuration no longer lists.
    public static func destroy(_ guest: GuestReference, purge: Bool, destroyUnreferencedDisks: Bool) -> APIRequest<String> {
        var parameters = APIParameters()
        if purge { parameters["purge"] = true }
        if destroyUnreferencedDisks { parameters["destroy-unreferenced-disks"] = true }
        return APIRequest(.delete, guest.path, parameters: parameters)
    }
}
