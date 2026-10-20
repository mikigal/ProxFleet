import Foundation

/// Details of a TLS certificate the user has to confirm before the app trusts it.
public struct CertificateDetails: Sendable, Equatable, Codable {
    /// SHA-256 of the DER certificate, formatted like the Proxmox web UI: `AB:CD:...`.
    public var sha256Fingerprint: String
    public var subject: String?
    public var notValidBefore: Date?
    public var notValidAfter: Date?

    public init(sha256Fingerprint: String, subject: String? = nil, notValidBefore: Date? = nil, notValidAfter: Date? = nil) {
        self.sha256Fingerprint = sha256Fingerprint
        self.subject = subject
        self.notValidBefore = notValidBefore
        self.notValidAfter = notValidAfter
    }

    /// Formats raw digest bytes as uppercase, colon-separated hex.
    public static func formatFingerprint<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { byte in
            let hex = String(byte, radix: 16, uppercase: true)
            return hex.count == 1 ? "0" + hex : hex
        }.joined(separator: ":")
    }
}

public enum ProxmoxError: Error, Sendable, Equatable {
    /// The server presented a certificate that is neither publicly trusted nor pinned.
    case untrustedCertificate(CertificateDetails)
    /// Network-level failure: no route, timeout, connection refused and similar.
    case transport(String)
    /// Wrong credentials, or the ticket expired or was revoked.
    case unauthorized(String?)
    /// The API rejected the request. `fieldErrors` maps parameter names to validation messages.
    case api(status: Int, message: String?, fieldErrors: [String: String])
    /// The response could not be understood.
    case invalidResponse(String)
    /// A request needing authentication was made before logging in.
    case notAuthenticated
}

extension ProxmoxError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .untrustedCertificate:
            return "The server's certificate is not trusted."
        case .transport(let message):
            return message
        case .unauthorized(let message):
            return message.map { "Authentication failed: \($0)" } ?? "Authentication failed."
        case .api(let status, let message, let fieldErrors):
            if let message, !message.isEmpty { return message }
            if let first = fieldErrors.sorted(by: { $0.key < $1.key }).first {
                return "\(first.key): \(first.value)"
            }
            return "The server returned error \(status)."
        case .invalidResponse(let detail):
            return "Unexpected response from the server (\(detail))."
        case .notAuthenticated:
            return "You are not signed in."
        }
    }
}
