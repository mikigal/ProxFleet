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
public final class URLSessionTransport: HTTPTransport, CertificatePinning {
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

    private static func describe(_ error: URLError) -> String {
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

private final class TrustDelegate: NSObject, URLSessionDelegate, Sendable {
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
