import CryptoKit
import Foundation
import ProxmoxCore
import Security
import Synchronization

/// URLSession transport with trust-on-first-use certificate handling.
///
/// Certificates trusted by the system (for example from Let's Encrypt) are accepted as usual. Anything else,
/// typically the self-signed certificate of a fresh Proxmox install, is accepted only when its SHA-256
/// fingerprint was pinned before. Otherwise the request fails with `ProxmoxError.untrustedCertificate`
/// so the app can ask the user.
public final class URLSessionTransport: WebSocketTransport, CertificatePinning {
    private let session: URLSession
    private let trust: TrustDelegate

    public init(pinnedFingerprints: Set<String> = [], timeout: TimeInterval = 20) {
        trust = TrustDelegate(pinned: pinnedFingerprints)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public var pinnedFingerprints: Set<String> {
        trust.pinned
    }

    /// Trusts a certificate from now on, typically after the user confirmed its fingerprint.
    public func pin(_ fingerprint: String) {
        trust.pin(fingerprint)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let host = request.url.host ?? ""
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ProxmoxError.invalidResponse("not an HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as URLError {
            if let rejected = trust.takeRejection(for: host) {
                throw ProxmoxError.untrustedCertificate(rejected)
            }
            if error.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            throw ProxmoxError.transport(Self.describe(error))
        }
    }

    public func openWebSocket(_ request: HTTPRequest, protocols: [String]) async throws -> any WebSocketConnection {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if !protocols.isEmpty {
            urlRequest.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = 64 * 1024 * 1024
        let socket = URLSessionWebSocket(task: task, host: request.url.host ?? "", trust: trust)
        task.resume()
        return socket
    }

    fileprivate static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: "The server did not respond in time."
        case .cannotFindHost, .dnsLookupFailed: "The server address could not be found."
        case .cannotConnectToHost: "Could not connect to the server. Check the address and port."
        case .notConnectedToInternet: "You are offline."
        case .networkConnectionLost: "The network connection was lost."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            "A secure connection to the server could not be established."
        default: error.localizedDescription
        }
    }
}

final class TrustDelegate: NSObject, URLSessionDelegate, Sendable {
    private struct State {
        var pinned: Set<String>
        var rejections: [String: CertificateDetails] = [:]
    }

    private let state: Mutex<State>

    init(pinned: Set<String>) {
        state = Mutex(State(pinned: Set(pinned.map(Self.normalize))))
    }

    var pinned: Set<String> {
        state.withLock { $0.pinned }
    }

    func pin(_ fingerprint: String) {
        state.withLock { _ = $0.pinned.insert(Self.normalize(fingerprint)) }
    }

    func takeRejection(for host: String) -> CertificateDetails? {
        state.withLock { $0.rejections.removeValue(forKey: host) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first
        else {
            return (.performDefaultHandling, nil)
        }

        let details = Self.details(of: leaf)
        if pinned.contains(details.sha256Fingerprint) {
            return (.useCredential, URLCredential(trust: serverTrust))
        }
        if SecTrustEvaluateWithError(serverTrust, nil) {
            return (.performDefaultHandling, nil)
        }
        state.withLock { $0.rejections[challenge.protectionSpace.host] = details }
        return (.cancelAuthenticationChallenge, nil)
    }

    private static func details(of certificate: SecCertificate) -> CertificateDetails {
        let der = SecCertificateCopyData(certificate) as Data
        let fingerprint = CertificateDetails.formatFingerprint(SHA256.hash(data: der))
        return CertificateDetails(
            sha256Fingerprint: fingerprint,
            subject: SecCertificateCopySubjectSummary(certificate) as String?,
            notValidBefore: SecCertificateCopyNotValidBeforeDate(certificate) as Date?,
            notValidAfter: SecCertificateCopyNotValidAfterDate(certificate) as Date?
        )
    }

    private static func normalize(_ fingerprint: String) -> String {
        fingerprint.uppercased().replacingOccurrences(of: " ", with: "")
    }
}

/// URLSessionWebSocketTask behind the `WebSocketConnection` protocol, with the transport's error mapping.
final class URLSessionWebSocket: WebSocketConnection {
    private let task: URLSessionWebSocketTask
    private let host: String
    private let trust: TrustDelegate

    init(task: URLSessionWebSocketTask, host: String, trust: TrustDelegate) {
        self.task = task
        self.host = host
        self.trust = trust
    }

    deinit {
        task.cancel(with: .goingAway, reason: nil)
    }

    func send(_ message: WebSocketMessage) async throws {
        do {
            switch message {
            case .data(let data): try await task.send(.data(data))
            case .text(let text): try await task.send(.string(text))
            }
        } catch {
            throw map(error)
        }
    }

    func receive() async throws -> WebSocketMessage {
        do {
            switch try await task.receive() {
            case .data(let data): return .data(data)
            case .string(let text): return .text(text)
            @unknown default: throw ProxmoxError.invalidResponse("unknown WebSocket message")
            }
        } catch {
            throw map(error)
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func map(_ error: any Error) -> any Error {
        if let rejected = trust.takeRejection(for: host) {
            return ProxmoxError.untrustedCertificate(rejected)
        }
        if let response = task.response as? HTTPURLResponse, response.statusCode >= 400 {
            return response.statusCode == 401
                ? ProxmoxError.unauthorized(nil)
                : ProxmoxError.api(status: response.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode), fieldErrors: [:])
        }
        if let urlError = error as? URLError {
            return ProxmoxError.transport(URLSessionTransport.describe(urlError))
        }
        if (error as NSError).domain == NSPOSIXErrorDomain, (error as NSError).code == 57 {
            return ProxmoxError.transport("The console connection was closed.")
        }
        return error
    }
}

extension URLSessionTransport: FileUploadTransport {
    /// Streams the body from a file. Certificate checks go through the session's trust delegate as usual.
    public func upload(_ request: HTTPRequest, bodyFile: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        // A data task with a body stream, not an upload task: upload tasks add the headers of resumable uploads
        // (`Upload-Draft-Interop-Version`, `Upload-Complete`), which pveproxy answers with 400 or a stalled request.
        // pveproxy does not accept chunked bodies either, so the length goes up front.
        guard let size = try? FileManager.default.attributesOfItem(atPath: bodyFile.path)[.size] as? Int64 else {
            throw ProxmoxError.transport("The file to upload could not be read.")
        }
        urlRequest.setValue(String(size), forHTTPHeaderField: "Content-Length")
        urlRequest.httpBodyStream = InputStream(url: bodyFile)
        let host = request.url.host ?? ""
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: UploadProgressDelegate(file: bodyFile, progress: progress))
            guard let http = response as? HTTPURLResponse else {
                throw ProxmoxError.invalidResponse("not an HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as URLError {
            if let rejected = trust.takeRejection(for: host) {
                throw ProxmoxError.untrustedCertificate(rejected)
            }
            if error.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            throw ProxmoxError.transport(Self.describe(error))
        }
    }
}

/// Reports the bytes sent by one upload and reopens the body when the system needs to send it again.
/// Authentication challenges fall through to the session's delegate.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let file: URL
    private let progress: @Sendable (Int64, Int64) -> Void

    init(file: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.file = file
        self.progress = progress
    }

    func urlSession(_ session: URLSession, needNewBodyStreamForTask task: URLSessionTask) async -> InputStream? {
        InputStream(url: file)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent, totalBytesExpectedToSend)
    }
}
