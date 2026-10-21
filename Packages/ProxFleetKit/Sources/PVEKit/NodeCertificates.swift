import Foundation
import ProxmoxCore

/// One entry of `GET /nodes/{node}/certificates/info`.
public struct NodeCertificate: Decodable, Sendable, Equatable, Identifiable {
    /// `pve-root-ca.pem` (the cluster CA), `pve-ssl.pem` (the node's default) or `pveproxy-ssl.pem` (custom or ACME).
    public var fileName: String
    public var subject: String
    public var issuer: String
    public var notBefore: Date?
    public var notAfter: Date?
    public var subjectAlternativeNames: [String]
    /// SHA-256, as `AB:CD:…`.
    public var fingerprint: String?
    public var keyType: String?
    public var keyBits: Int?
    public var pem: String?

    public var id: String { fileName }

    /// The certificate pveproxy serves instead of `pve-ssl.pem`.
    public var isCustom: Bool { fileName == "pveproxy-ssl.pem" }
    public var isAuthority: Bool { fileName == "pve-root-ca.pem" }

    /// `/OU=PVE Cluster Node/O=Proxmox Virtual Environment/CN=pve.local` → `pve.local`.
    public var commonName: String {
        subject.split(separator: "/").first { $0.hasPrefix("CN=") }.map { String($0.dropFirst(3)) } ?? subject
    }

    public var issuerName: String {
        issuer.split(separator: "/").first { $0.hasPrefix("CN=") }.map { String($0.dropFirst(3)) } ?? issuer
    }

    public func isExpired(at date: Date = Date()) -> Bool { notAfter.map { $0 < date } ?? false }

    /// Expires within 30 days.
    public func expiresSoon(at date: Date = Date()) -> Bool {
        notAfter.map { $0 < date.addingTimeInterval(30 * 86_400) } ?? false
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        func date(_ key: String) -> Date? {
            container.lossyInt(AnyCodingKey(key)).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
        fileName = container.lossyString(AnyCodingKey("filename")) ?? ""
        subject = container.lossyString(AnyCodingKey("subject")) ?? ""
        issuer = container.lossyString(AnyCodingKey("issuer")) ?? ""
        notBefore = date("notbefore")
        notAfter = date("notafter")
        subjectAlternativeNames = (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("san"))) ?? []
        fingerprint = container.lossyString(AnyCodingKey("fingerprint"))
        keyType = container.lossyString(AnyCodingKey("public-key-type"))
        keyBits = container.lossyInt(AnyCodingKey("public-key-bits"))
        pem = container.lossyString(AnyCodingKey("pem"))
    }
}

/// A certificate chain and private key to upload, as PEM text.
public struct CustomCertificateDraft: Equatable, Sendable {
    public var certificates = ""
    /// Empty keeps the key already on the node, e.g. when renewing a certificate for the same key.
    public var key = ""

    public init() {}

    public var problems: [String: String] {
        var problems: [String: String] = [:]
        if !certificates.contains("-----BEGIN CERTIFICATE-----") {
            problems["certificates"] = String(localized: "Paste the certificate in PEM format, starting with -----BEGIN CERTIFICATE-----.")
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, !(key.hasPrefix("-----BEGIN") && key.contains("PRIVATE KEY-----")) {
            problems["key"] = String(localized: "Paste the private key in PEM format, starting with -----BEGIN PRIVATE KEY-----.")
        }
        return problems
    }

    var parameters: APIParameters {
        var parameters: APIParameters = ["certificates": .string(certificates.trimmingCharacters(in: .whitespacesAndNewlines))]
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { parameters["key"] = .string(key) }
        // Replaces an existing custom or ACME certificate, and makes pveproxy serve the new one right away.
        parameters["force"] = true
        parameters["restart"] = true
        return parameters
    }
}

extension PVE {
    public static func certificates(node: String) -> APIRequest<[NodeCertificate]> {
        APIRequest(.get, "/nodes/\(node)/certificates/info")
    }

    /// Uploads a custom certificate and restarts pveproxy. Returns the new certificate.
    public static func uploadCertificate(node: String, _ draft: CustomCertificateDraft) -> APIRequest<NodeCertificate> {
        APIRequest(.post, "/nodes/\(node)/certificates/custom", parameters: draft.parameters)
    }

    /// Removes the custom certificate and restarts pveproxy, which goes back to `pve-ssl.pem`.
    public static func deleteCustomCertificate(node: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/nodes/\(node)/certificates/custom", parameters: ["restart": true])
    }
}
