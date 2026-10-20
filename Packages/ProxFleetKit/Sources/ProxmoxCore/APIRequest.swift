import Foundation

/// A single API parameter value. Proxmox expects booleans as `0`/`1`.
public enum APIValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public var encoded: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "1" : "0"
        }
    }
}

extension APIValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Ordered request parameters, encoded as a query string (GET/DELETE) or form body (POST/PUT).
public struct APIParameters: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    public private(set) var items: [(name: String, value: APIValue)]

    public init() { items = [] }

    public init(dictionaryLiteral elements: (String, APIValue)...) {
        items = elements.map { (name: $0.0, value: $0.1) }
    }

    public var isEmpty: Bool { items.isEmpty }

    public subscript(name: String) -> APIValue? {
        get { items.first { $0.name == name }?.value }
        set {
            items.removeAll { $0.name == name }
            if let newValue { items.append((name: name, value: newValue)) }
        }
    }

    /// `application/x-www-form-urlencoded` representation.
    public var formEncoded: String {
        items.map { "\(Self.escape($0.name))=\(Self.escape($0.value.encoded))" }.joined(separator: "&")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    public static func == (lhs: APIParameters, rhs: APIParameters) -> Bool {
        lhs.items.elementsEqual(rhs.items) { $0.name == $1.name && $0.value == $1.value }
    }
}

/// A typed API call. `path` is relative to `/api2/<format>`, e.g. `/cluster/resources`.
public struct APIRequest<Response: Decodable & Sendable>: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var parameters: APIParameters

    public init(_ method: HTTPMethod, _ path: String, parameters: APIParameters = APIParameters()) {
        self.method = method
        self.path = path
        self.parameters = parameters
    }
}

/// Response type for calls whose `data` is `null` or irrelevant.
public struct Nothing: Decodable, Sendable, Equatable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
}
