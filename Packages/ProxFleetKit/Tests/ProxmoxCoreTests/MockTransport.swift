import Foundation
import ProxmoxCore
import Synchronization

/// Records requests and answers them with a handler.
final class MockTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse

    private let handler: Handler
    private let recorded = Mutex<[HTTPRequest]>([])

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [HTTPRequest] { recorded.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.withLock { $0.append(request) }
        return try handler(request)
    }
}

extension HTTPResponse {
    static func json(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(text.utf8))
    }
}

extension HTTPRequest {
    /// Decoded form body or query parameters.
    var parameters: [String: String] {
        let encoded = body.flatMap { String(data: $0, encoding: .utf8) } ?? url.query(percentEncoded: true) ?? ""
        var result: [String: String] = [:]
        for pair in encoded.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }
}

/// Clock that tests can move forward.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        current.withLock { $0 += interval }
    }
}
