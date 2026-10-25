import Foundation
import ProxmoxCore

/// An S3-compatible object store that datastores can keep their chunks in, from `GET /config/s3`.
/// The secret key is never returned.
public struct S3Endpoint: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Host name, which may contain `{{bucket}}` and `{{region}}` placeholders.
    public var endpoint: String
    public var region: String?
    public var port: Int?
    public var accessKey: String?
    /// Addresses buckets as a path instead of a host name, as MinIO and Ceph need.
    public var usesPathStyle: Bool
    public var fingerprint: String?
    public var providerQuirks: [String]
    public var values: [String: String]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: String] = [:]
        for key in container.allKeys {
            if let text = container.lossyString(key) {
                values[key.stringValue] = text
            } else if let flag = container.lossyBool(key) {
                values[key.stringValue] = flag ? "1" : "0"
            }
        }
        self.values = values
        id = values["id"] ?? ""
        endpoint = values["endpoint"] ?? ""
        region = values["region"]
        port = container.lossyInt(AnyCodingKey("port"))
        accessKey = values["access-key"]
        usesPathStyle = container.lossyBool(AnyCodingKey("path-style")) ?? false
        fingerprint = values["fingerprint"]
        providerQuirks = container.stringList("provider-quirks")
    }
}

/// Bucket names from `GET /config/s3/{id}/list-buckets`, whose shape the API schema leaves open: plain names or
/// objects with a `name`.
public struct S3BucketList: Decodable, Sendable, Equatable {
    public var names: [String]

    public init(from decoder: any Decoder) throws {
        var list = try decoder.unkeyedContainer()
        var names: [String] = []
        while !list.isAtEnd {
            if let name = try? list.decode(String.self) {
                names.append(name)
            } else if let object = try? list.nestedContainer(keyedBy: AnyCodingKey.self),
                      let name = object.lossyString(AnyCodingKey("name")) {
                names.append(name)
            } else {
                _ = try? list.decode(Nothing.self)
            }
        }
        self.names = names.sorted()
    }
}

extension PBS {
    public static func s3Endpoints() -> APIRequest<Digested<[S3Endpoint]>> {
        APIRequest(.get, "/config/s3")
    }

    public static func s3Buckets(_ endpoint: String) -> APIRequest<S3BucketList> {
        APIRequest(.get, "/config/s3/\(escapePath(endpoint))/list-buckets")
    }
}
