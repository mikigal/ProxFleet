import Foundation
import ProxmoxCore

/// `GET /nodes/{node}/apt/repositories`: the parsed APT sources of a node.
public struct AptRepositories: Decodable, Sendable, Equatable {
    public struct Repository: Sendable, Equatable, Identifiable {
        /// The file and the index within it, which together identify the repository for changes.
        public var path: String
        public var index: Int
        public var isEnabled: Bool
        public var types: [String]
        public var uris: [String]
        public var suites: [String]
        public var components: [String]
        public var comment: String?
        /// `Proxmox`, `Debian`… from the server's origin detection; nil when unknown.
        public var origin: String?
        /// Warnings the server found, e.g. about a suite that does not match the installed release.
        public var warnings: [String]

        public var id: String { "\(path)#\(index)" }

        /// `http://download.proxmox.com/debian/pve trixie pve-no-subscription`, like a one-line sources entry.
        public var summary: String {
            ([uris.joined(separator: " ")] + [suites.joined(separator: " ")] + [components.joined(separator: " ")])
                .filter { !$0.isEmpty }.joined(separator: " ")
        }

        public var isEnterprise: Bool {
            uris.contains { $0.contains("enterprise.proxmox.com") }
        }
    }

    public struct File: Sendable, Equatable, Identifiable {
        public var path: String
        public var repositories: [Repository]

        public var id: String { path }
    }

    /// One of the repositories the web interface offers to add.
    public struct StandardRepository: Decodable, Sendable, Equatable, Identifiable {
        public var handle: String
        public var name: String
        public var description: String
        /// true: configured and enabled; false: configured but disabled; nil: not configured.
        public var isEnabled: Bool?

        public var id: String { handle }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            handle = container.lossyString(AnyCodingKey("handle")) ?? ""
            name = container.lossyString(AnyCodingKey("name")) ?? handle
            description = container.lossyString(AnyCodingKey("description")) ?? ""
            isEnabled = container.lossyBool(AnyCodingKey("status"))
        }
    }

    public var files: [File]
    public var standardRepositories: [StandardRepository]
    /// Files that could not be parsed, with the reason.
    public var errors: [(path: String, message: String)]
    /// Digest of all files, sent with changes to detect edits made meanwhile.
    public var digest: String?

    public var repositories: [Repository] { files.flatMap(\.repositories) }

    /// Whether some enabled repository provides Proxmox packages.
    public var hasEnabledProxmoxRepository: Bool {
        repositories.contains { $0.isEnabled && ($0.origin == "Proxmox" || $0.uris.contains { $0.contains("proxmox.com") }) }
    }

    public var hasEnabledEnterpriseRepository: Bool {
        repositories.contains { $0.isEnabled && $0.isEnterprise }
    }

    public static func == (lhs: AptRepositories, rhs: AptRepositories) -> Bool {
        lhs.files == rhs.files && lhs.standardRepositories == rhs.standardRepositories && lhs.digest == rhs.digest
            && lhs.errors.map(\.path) == rhs.errors.map(\.path) && lhs.errors.map(\.message) == rhs.errors.map(\.message)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        digest = container.lossyString(AnyCodingKey("digest"))
        standardRepositories = (try? container.decodeIfPresent([StandardRepository].self, forKey: AnyCodingKey("standard-repos"))) ?? []

        let infos = (try? container.decodeIfPresent([Info].self, forKey: AnyCodingKey("infos"))) ?? []
        let rawFiles = (try? container.decodeIfPresent([RawFile].self, forKey: AnyCodingKey("files"))) ?? []
        files = rawFiles.map { file in
            File(path: file.path, repositories: file.repositories.enumerated().map { index, raw in
                let notes = infos.filter { $0.path == file.path && $0.index == index }
                return Repository(
                    path: file.path, index: index, isEnabled: raw.isEnabled, types: raw.types, uris: raw.uris, suites: raw.suites,
                    components: raw.components, comment: raw.comment,
                    origin: notes.first { $0.kind == "origin" }?.message,
                    warnings: notes.filter { $0.kind == "warning" }.map(\.message)
                )
            })
        }
        errors = ((try? container.decodeIfPresent([RawError].self, forKey: AnyCodingKey("errors"))) ?? []).map { (path: $0.path, message: $0.error) }
    }

    private struct Info: Decodable {
        var path: String
        var index: Int
        var kind: String
        var message: String

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            path = container.lossyString(AnyCodingKey("path")) ?? ""
            index = container.lossyInt(AnyCodingKey("index")) ?? -1
            kind = container.lossyString(AnyCodingKey("kind")) ?? ""
            message = container.lossyString(AnyCodingKey("message")) ?? ""
        }
    }

    private struct RawFile: Decodable {
        var path: String
        var repositories: [RawRepository]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            path = container.lossyString(AnyCodingKey("path")) ?? ""
            repositories = (try? container.decodeIfPresent([RawRepository].self, forKey: AnyCodingKey("repositories"))) ?? []
        }
    }

    private struct RawRepository: Decodable {
        var isEnabled: Bool
        var types: [String]
        var uris: [String]
        var suites: [String]
        var components: [String]
        var comment: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            func list(_ key: String) -> [String] {
                (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey(key))) ?? []
            }
            isEnabled = container.lossyBool(AnyCodingKey("Enabled")) ?? true
            types = list("Types")
            uris = list("URIs")
            suites = list("Suites")
            components = list("Components")
            comment = container.lossyString(AnyCodingKey("Comment"))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    private struct RawError: Decodable {
        var path: String
        var error: String
    }
}

/// `GET /nodes/{node}/subscription`.
public struct NodeSubscription: Decodable, Sendable, Equatable {
    /// `active`, `notfound`, `expired`, `invalid`…
    public var status: String
    public var productName: String?
    public var message: String?
    public var nextDueDate: String?

    public var isActive: Bool { status.lowercased() == "active" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        status = container.lossyString(AnyCodingKey("status")) ?? "unknown"
        productName = container.lossyString(AnyCodingKey("productname"))
        message = container.lossyString(AnyCodingKey("message"))
        nextDueDate = container.lossyString(AnyCodingKey("nextduedate"))
    }
}

extension PVE {
    public static func aptRepositories(node: String) -> APIRequest<AptRepositories> {
        APIRequest(.get, "/nodes/\(node)/apt/repositories")
    }

    /// Enables or disables a repository, unless the files changed since `digest`.
    public static func setRepository(node: String, _ repository: AptRepositories.Repository, enabled: Bool, digest: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["path": .string(repository.path), "index": .int(repository.index), "enabled": .bool(enabled)]
        if let digest { parameters["digest"] = .string(digest) }
        return APIRequest(.post, "/nodes/\(node)/apt/repositories", parameters: parameters)
    }

    /// Adds one of the standard repositories, such as `no-subscription`.
    public static func addStandardRepository(node: String, handle: String, digest: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["handle": .string(handle)]
        if let digest { parameters["digest"] = .string(digest) }
        return APIRequest(.put, "/nodes/\(node)/apt/repositories", parameters: parameters)
    }

    public static func subscription(node: String) -> APIRequest<NodeSubscription> {
        APIRequest(.get, "/nodes/\(node)/subscription")
    }
}
