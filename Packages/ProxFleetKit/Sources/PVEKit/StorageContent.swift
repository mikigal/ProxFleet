import Foundation
import ProxmoxCore

/// Content types a storage can hold, in the order of the web interface.
public enum StorageContentType: String, CaseIterable, Sendable, Identifiable {
    case images, rootdir, iso, vztmpl, backup, snippets, `import`

    public var id: String { rawValue }

    /// Types files can be uploaded or downloaded to.
    public var acceptsFiles: Bool { self == .iso || self == .vztmpl || self == .import }

    /// File name endings Proxmox accepts for uploads and downloads of this type.
    public var fileExtensions: [String] {
        switch self {
        case .iso: [".iso", ".img"]
        case .vztmpl: [".tar.gz", ".tar.xz", ".tar.zst", ".tgz", ".txz", ".tzst"]
        case .import: [".ova", ".ovf", ".qcow2", ".raw", ".vmdk", ".img"]
        default: []
        }
    }
}

/// `GET /nodes/{node}/storage/{storage}/status`.
public struct StorageStatus: Decodable, Sendable, Equatable {
    public var type: String
    public var content: [String]
    public var isActive: Bool
    public var isEnabled: Bool
    public var isShared: Bool
    public var used: Int64
    public var total: Int64
    public var available: Int64

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func bytes(_ key: String) -> Int64 { Int64(container.lossyDouble(AnyCodingKey(key)) ?? 0) }
        type = container.lossyString(AnyCodingKey("type")) ?? ""
        content = container.lossyString(AnyCodingKey("content"))?.split(separator: ",").map(String.init).sorted() ?? []
        isActive = container.lossyBool(AnyCodingKey("active")) ?? false
        isEnabled = container.lossyBool(AnyCodingKey("enabled")) ?? true
        isShared = container.lossyBool(AnyCodingKey("shared")) ?? false
        used = bytes("used")
        total = bytes("total")
        available = bytes("avail")
    }

    /// The content types in the web interface's order.
    public var contentTypes: [StorageContentType] {
        StorageContentType.allCases.filter { content.contains($0.rawValue) }
    }
}

/// `GET /nodes/{node}/query-url-metadata`: what a URL would download.
public struct URLMetadata: Decodable, Sendable, Equatable {
    public var fileName: String?
    public var size: Int64?
    public var mimeType: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        fileName = container.lossyString(AnyCodingKey("filename"))?.nilIfEmpty
        size = container.lossyDouble(AnyCodingKey("size")).map { Int64($0) }
        mimeType = container.lossyString(AnyCodingKey("mimetype"))
    }
}

/// The form for downloading a file from a URL to a storage, or uploading one from the device.
public struct StorageFileDraft: Equatable, Sendable {
    public static let checksumAlgorithms = ["md5", "sha1", "sha224", "sha256", "sha384", "sha512"]

    public var content: StorageContentType
    public var url = ""
    public var fileName = ""
    /// Empty for no check.
    public var checksum = ""
    public var checksumAlgorithm = "sha256"
    public var verifyCertificates = true
    /// ISO images only: `gz`, `lzo`, `zst` or `bz2` to decompress the download, empty for none.
    public var decompression = ""

    public static let decompressionAlgorithms = ["lzo", "gz", "zst", "bz2"]

    /// The file name to save a download under, from the name the server reported, like the web interface:
    /// compressed ISO images lose their ending and get decompressed, `.img` imports become raw images.
    public mutating func applyQueriedName(_ name: String) {
        var name = name
        decompression = ""
        if content == .iso, let dot = name.lastIndex(of: "."),
           Self.decompressionAlgorithms.contains(name[name.index(after: dot)...].lowercased()) {
            decompression = name[name.index(after: dot)...].lowercased()
            name = String(name[..<dot])
        } else if content == .import, name.hasSuffix(".img") {
            name += ".raw"
        }
        fileName = name
    }

    public init(content: StorageContentType) {
        self.content = content
    }

    /// The file name from the last path component of a URL, without its query.
    public static func fileName(from url: String) -> String {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespaces)) else { return "" }
        return components.path.split(separator: "/").last.map(String.init)?.removingPercentEncoding ?? ""
    }

    /// Problems the app can see itself, by parameter name. `forUpload` skips the URL.
    public func problems(forUpload: Bool = false) -> [String: String] {
        var problems: [String: String] = [:]
        if !forUpload {
            let url = url.trimmingCharacters(in: .whitespaces)
            if !(url.hasPrefix("http://") || url.hasPrefix("https://")) || URL(string: url)?.host == nil {
                problems["url"] = String(localized: "Enter an http or https URL.")
            }
        }
        let name = fileName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            problems["filename"] = String(localized: "Enter a file name.")
        } else if name.contains("/") {
            problems["filename"] = String(localized: "The file name cannot contain a slash.")
        } else if !content.fileExtensions.contains(where: { name.lowercased().hasSuffix($0) }) {
            problems["filename"] = String(localized: "The file name must end with \(content.fileExtensions.joined(separator: ", ")).")
        }
        let checksum = checksum.trimmingCharacters(in: .whitespaces)
        if !checksum.isEmpty, !checksum.allSatisfy(\.isHexDigit) {
            problems["checksum"] = String(localized: "A checksum is a hexadecimal string.")
        }
        return problems
    }

    var commonParameters: APIParameters {
        var parameters: APIParameters = ["content": .string(content.rawValue), "filename": .string(fileName.trimmingCharacters(in: .whitespaces))]
        let checksum = checksum.trimmingCharacters(in: .whitespaces).lowercased()
        if !checksum.isEmpty {
            // The algorithm first: pveproxy reads upload fields in order and refuses a checksum before it (HTTP 400).
            parameters["checksum-algorithm"] = .string(checksumAlgorithm)
            parameters["checksum"] = .string(checksum)
        }
        return parameters
    }
}

extension PVE {
    public static func storageStatus(node: String, storage: String) -> APIRequest<StorageStatus> {
        APIRequest(.get, "/nodes/\(node)/storage/\(escapePath(storage))/status")
    }

    /// Every volume of a storage, or only those of one content type.
    public static func storageVolumes(node: String, storage: String, content: StorageContentType? = nil) -> APIRequest<[StorageVolume]> {
        var parameters = APIParameters()
        if let content { parameters["content"] = .string(content.rawValue) }
        return APIRequest(.get, "/nodes/\(node)/storage/\(escapePath(storage))/content", parameters: parameters)
    }

    /// Deletes a volume. Returns a task ID.
    public static func deleteVolume(node: String, storage: String, volume: String) -> APIRequest<String?> {
        APIRequest(.delete, "/nodes/\(node)/storage/\(escapePath(storage))/content/\(escapePath(volume))")
    }

    public static func urlMetadata(node: String, url: String, verifyCertificates: Bool = true) -> APIRequest<URLMetadata> {
        var parameters: APIParameters = ["url": .string(url)]
        if !verifyCertificates { parameters["verify-certificates"] = false }
        return APIRequest(.get, "/nodes/\(node)/query-url-metadata", parameters: parameters)
    }

    /// Lets the node download a file from a URL to the storage. Returns a task ID.
    public static func downloadURL(node: String, storage: String, _ draft: StorageFileDraft) -> APIRequest<String?> {
        var parameters = draft.commonParameters
        parameters["url"] = .string(draft.url.trimmingCharacters(in: .whitespaces))
        if !draft.verifyCertificates { parameters["verify-certificates"] = false }
        if draft.content == .iso, !draft.decompression.isEmpty { parameters["compression"] = .string(draft.decompression) }
        return APIRequest(.post, "/nodes/\(node)/storage/\(escapePath(storage))/download-url", parameters: parameters)
    }

    /// Usage of a storage over time, as `used` and `total` bytes.
    public static func storageRRD(node: String, storage: String, timeframe: RRDTimeframe) -> APIRequest<[RRDPoint]> {
        APIRequest(.get, "/nodes/\(node)/storage/\(escapePath(storage))/rrddata", parameters: ["timeframe": .string(timeframe.rawValue), "cf": "AVERAGE"])
    }

    /// Tags of an OCI image repository, e.g. `docker.io/library/alpine`.
    public static func ociTags(node: String, reference: String) -> APIRequest<[String]> {
        APIRequest(.get, "/nodes/\(node)/query-oci-repo-tags", parameters: ["reference": .string(reference)])
    }

    /// Pulls an OCI image (`reference:tag`) as a container template. Returns a task ID.
    public static func pullOCIImage(node: String, storage: String, _ draft: OCIPullDraft) -> APIRequest<String> {
        var parameters: APIParameters = ["reference": .string(draft.fullReference)]
        if let name = draft.fileName.trimmingCharacters(in: .whitespaces).nilIfEmpty { parameters["filename"] = .string(name) }
        return APIRequest(.post, "/nodes/\(node)/storage/\(escapePath(storage))/oci-registry-pull", parameters: parameters)
    }

    /// What pruning with `options` would keep and remove of one guest's backups; nil options use the storage's settings.
    public static func prunePreview(node: String, storage: String, kind: GuestKind, vmid: Int, options: PruneOptions?) -> APIRequest<[PruneCandidate]> {
        APIRequest(.get, "/nodes/\(node)/storage/\(escapePath(storage))/prunebackups", parameters: pruneParameters(kind: kind, vmid: vmid, options: options))
    }

    /// Removes the backups of one guest that the retention options do not keep. Returns a task ID.
    public static func pruneBackups(node: String, storage: String, kind: GuestKind, vmid: Int, options: PruneOptions?) -> APIRequest<String?> {
        APIRequest(.delete, "/nodes/\(node)/storage/\(escapePath(storage))/prunebackups", parameters: pruneParameters(kind: kind, vmid: vmid, options: options))
    }

    private static func pruneParameters(kind: GuestKind, vmid: Int, options: PruneOptions?) -> APIParameters {
        var parameters: APIParameters = ["type": .string(kind.rawValue), "vmid": .int(vmid)]
        if let value = options?.serialized { parameters["prune-backups"] = .string(value) }
        return parameters
    }

    /// The upload call; send it with `ProxmoxSession.upload`, which adds the file as the `filename` field.
    /// Returns a task ID that copies the file into place.
    public static func uploadFile(node: String, storage: String, _ draft: StorageFileDraft) -> APIRequest<String?> {
        var parameters = draft.commonParameters
        // The file part carries the name; a separate `filename` field would clash with it.
        parameters["filename"] = nil
        return APIRequest(.post, "/nodes/\(node)/storage/\(escapePath(storage))/upload", parameters: parameters)
    }
}

/// Pulling an OCI image from a registry as a container template, like the web interface's Pull from OCI Registry.
public struct OCIPullDraft: Equatable, Sendable {
    /// For example `docker.io/library/alpine`; a `:tag` typed here moves to `tag`.
    public var reference = ""
    public var tag = "latest"
    /// Empty for the server's default, `<reference>_<tag>`.
    public var fileName = ""

    public init() {}

    var fullReference: String { "\(reference.trimmingCharacters(in: .whitespaces)):\(tag.trimmingCharacters(in: .whitespaces))" }

    /// Splits `name:tag` typed into the reference, as the web interface does.
    public mutating func takeTagFromReference() {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":"), !trimmed[trimmed.index(after: colon)...].contains("/") else { return }
        let tag = trimmed[trimmed.index(after: colon)...]
        // A colon followed by digits only after a host name is a port, e.g. `registry:5000/name`.
        guard !tag.isEmpty, trimmed[..<colon].contains("/") || !tag.allSatisfy(\.isNumber) else { return }
        self.tag = String(tag)
        reference = String(trimmed[..<colon])
    }

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        let reference = reference.trimmingCharacters(in: .whitespaces)
        // Repository names are lowercase; only a registry host may have capitals, which is rare enough to ignore.
        let valid = !reference.isEmpty && !reference.contains(" ") && !reference.hasPrefix("/") && !reference.hasSuffix("/")
            && reference.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 == $0.lowercased() }
        if !valid { problems["reference"] = String(localized: "Enter an image reference such as docker.io/library/alpine.") }
        let tag = tag.trimmingCharacters(in: .whitespaces)
        if tag.isEmpty || tag.count > 128 || !tag.allSatisfy({ $0.isLetter || $0.isNumber || "_.-".contains($0) }) {
            problems["tag"] = String(localized: "Enter a tag, e.g. latest.")
        }
        return problems
    }
}

/// One backup in a prune preview, from `GET .../prunebackups`.
public struct PruneCandidate: Decodable, Sendable, Equatable, Identifiable {
    public var volumeID: String
    public var date: Date?
    /// `keep`, `remove`, `protected` or `renamed`.
    public var mark: String
    /// Why it is kept, e.g. `keep-daily: 2`; set by `withKeepReasons`.
    public var keepReason: String?

    public var id: String { volumeID }
    public var isKept: Bool { mark != "remove" }

    public init(volumeID: String, date: Date?, mark: String) {
        self.volumeID = volumeID
        self.date = date
        self.mark = mark
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        volumeID = container.lossyString(AnyCodingKey("volid")) ?? ""
        date = container.lossyDouble(AnyCodingKey("ctime")).map { Date(timeIntervalSince1970: $0) }
        mark = container.lossyString(AnyCodingKey("mark")) ?? "keep"
    }

    /// The candidates newest first, with the rule that keeps each one, like the web interface explains it:
    /// kept backups count towards the first rule, then the next once that rule's count is reached.
    public static func withKeepReasons(_ candidates: [PruneCandidate], options: PruneOptions) -> [PruneCandidate] {
        var rules = PruneOptions.keys.compactMap { key -> (key: String, count: Int)? in
            guard let count = options.counts[key].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), count > 0 else { return nil }
            return (key, count)
        }[...]
        var counter = 0
        return candidates.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.map { candidate in
            var candidate = candidate
            switch candidate.mark {
            case "keep":
                if options.keepAll || rules.isEmpty {
                    candidate.keepReason = "keep-all"
                } else if let rule = rules.first {
                    counter += 1
                    candidate.keepReason = "\(rule.key): \(counter)"
                    if counter >= rule.count {
                        rules = rules.dropFirst()
                        counter = 0
                    }
                }
            case "protected", "renamed":
                candidate.keepReason = candidate.mark
            default:
                break
            }
            return candidate
        }
    }
}
