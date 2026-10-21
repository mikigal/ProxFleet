import Foundation

/// The app talks to the `extjs` API format, the same one the web UI uses. Unlike plain `json`, it reports
/// error messages in the body (`success`, `status`, `message`, `errors`) instead of only in the HTTP status line,
/// which URLSession does not expose.
public enum APIFormat {
    public static let pathPrefix = "/api2/extjs"
}

/// Values that can represent JSON `null` in `data`.
public protocol NullDecodable {
    static var nullValue: Self { get }
}

extension Optional: NullDecodable {
    public static var nullValue: Optional<Wrapped> { nil }
}

extension Nothing: NullDecodable {
    public static var nullValue: Nothing { Nothing() }
}

/// A response that needs more of the body than `data`: it decodes from the whole envelope, for example
/// `GET /nodes/{node}/network`, which reports pending changes in `changes` next to `data`.
public protocol EnvelopeDecodable: Decodable {}

enum ResponseDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: response.body)
        } catch let error as ProxmoxError {
            throw error
        } catch {
            if response.statusCode >= 400 {
                throw httpError(status: response.statusCode, message: bodyText(response.body))
            }
            throw ProxmoxError.invalidResponse(String(describing: error))
        }

        let status = envelope.status ?? response.statusCode
        if envelope.success == false || status >= 400 {
            // Proxmox ends messages with a newline.
            let message = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            if status == 401 { throw ProxmoxError.unauthorized(message) }
            throw ProxmoxError.api(status: status, message: message, fieldErrors: envelope.errors)
        }
        if T.self is EnvelopeDecodable.Type {
            do {
                return try JSONDecoder().decode(T.self, from: response.body)
            } catch {
                throw ProxmoxError.invalidResponse(String(describing: error))
            }
        }
        if let data = envelope.data { return data }
        if let null = T.self as? NullDecodable.Type, let value = null.nullValue as? T { return value }
        throw ProxmoxError.invalidResponse("missing data")
    }

    private static func httpError(status: Int, message: String?) -> ProxmoxError {
        status == 401 ? .unauthorized(message) : .api(status: status, message: message, fieldErrors: [:])
    }

    private static func bodyText(_ data: Data) -> String? {
        // Short plain-text bodies only; HTML error pages are not useful to show.
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count < 500, !text.hasPrefix("<")
        else { return nil }
        return text
    }
}

private struct Envelope<T: Decodable>: Decodable {
    var data: T?
    var success: Bool?
    var status: Int?
    var message: String?
    var errors: [String: String]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        success = container.lossyBool(AnyCodingKey("success"))
        status = container.lossyInt(AnyCodingKey("status"))
        message = container.lossyString(AnyCodingKey("message"))

        var errors: [String: String] = [:]
        if let nested = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("errors")) {
            for key in nested.allKeys {
                errors[key.stringValue] = nested.lossyString(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        self.errors = errors

        // Failed responses carry `data: null`, which must not fail decoding of a non-optional `T`.
        if success == false || (status ?? 200) >= 400 || T.self is EnvelopeDecodable.Type {
            data = nil
        } else {
            data = try container.decodeIfPresent(T.self, forKey: AnyCodingKey("data"))
        }
    }
}
