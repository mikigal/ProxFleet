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
        return APIRequest(.post, "/nodes/\(node)/storage/\(escapePath(storage))/download-url", parameters: parameters)
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
