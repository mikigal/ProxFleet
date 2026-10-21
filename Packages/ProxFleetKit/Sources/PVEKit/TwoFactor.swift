import Foundation
import ProxmoxCore

/// A second factor of a user: an authenticator app, recovery keys or a security key.
public struct TwoFactorEntry: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    /// `totp`, `recovery`, `webauthn`, `u2f` or `yubico`.
    public var type: String
    public var description: String
    public var created: Date?
    public var isEnabled: Bool

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = container.lossyString(AnyCodingKey("id")) ?? ""
        type = container.lossyString(AnyCodingKey("type")) ?? ""
        description = container.lossyString(AnyCodingKey("description")) ?? ""
        created = container.lossyInt(AnyCodingKey("created")).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        isEnabled = container.lossyBool(AnyCodingKey("enable")) ?? true
    }

    /// The app can add authenticator apps and recovery keys; security keys need the web interface.
    public var isSecurityKey: Bool { ["webauthn", "u2f", "yubico"].contains(type) }
}

/// The second factors of one user, from `GET /access/tfa`.
public struct UserTwoFactors: Decodable, Sendable, Equatable, Identifiable {
    public var userid: String
    public var entries: [TwoFactorEntry]
    /// Authenticator codes are locked after too many wrong codes, until an admin unlocks them.
    public var isTOTPLocked: Bool
    /// Every second factor is locked until then after too many failed attempts.
    public var lockedUntil: Date?

    public var id: String { userid }

    public func isLocked(at date: Date = Date()) -> Bool {
        isTOTPLocked || (lockedUntil.map { $0 > date } ?? false)
    }

    /// A user can have only one set of recovery keys.
    public var hasRecoveryKeys: Bool { entries.contains { $0.type == "recovery" } }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        userid = container.lossyString(AnyCodingKey("userid")) ?? ""
        entries = (try? container.decodeIfPresent([TwoFactorEntry].self, forKey: AnyCodingKey("entries"))) ?? []
        isTOTPLocked = container.lossyBool(AnyCodingKey("totp-locked")) ?? false
        lockedUntil = container.lossyInt(AnyCodingKey("tfa-locked-until")).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

/// The answer to adding a second factor; recovery keys are only ever shown here.
public struct AddedTwoFactor: Decodable, Sendable, Equatable {
    public var id: String?
    public var recoveryKeys: [String]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = container.lossyString(AnyCodingKey("id"))
        recoveryKeys = (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("recovery"))) ?? []
    }
}

/// A new authenticator secret, created on the device the way the web interface does, and its `otpauth` URI.
public struct TOTPSecret: Sendable, Equatable {
    /// Base32 without padding.
    public var secret: String
    public var issuer: String
    public var account: String
    public static let period = 30
    public static let digits = 6

    public init(secret: String, issuer: String, account: String) {
        self.secret = secret
        self.issuer = issuer
        self.account = account
    }

    /// 160 random bits, the size RFC 4226 recommends.
    public static func random(issuer: String, account: String) -> TOTPSecret {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<20).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return TOTPSecret(secret: base32(bytes), issuer: issuer, account: account)
    }

    /// `otpauth://totp/Proxmox%20-%20pve:root@pam?secret=…&period=30&digits=6&algorithm=SHA1&issuer=…`
    public var uri: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~@"))
        let issuer = issuer.addingPercentEncoding(withAllowedCharacters: allowed) ?? issuer
        let account = account.addingPercentEncoding(withAllowedCharacters: allowed) ?? account
        return "otpauth://totp/\(issuer):\(account)?secret=\(secret)&period=\(Self.period)&digits=\(Self.digits)&algorithm=SHA1&issuer=\(issuer)"
    }

    /// The secret in groups of four, easier to type into an authenticator app.
    public var grouped: String {
        stride(from: 0, to: secret.count, by: 4).map { start in
            let begin = secret.index(secret.startIndex, offsetBy: start)
            return String(secret[begin..<(secret.index(begin, offsetBy: 4, limitedBy: secret.endIndex) ?? secret.endIndex)])
        }.joined(separator: " ")
    }

    static func base32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return output
    }
}

extension PVE {
    /// Every user's second factors the signed-in user may see; just their own without `User.Modify` or `Sys.Audit`.
    public static func twoFactors() -> APIRequest<[UserTwoFactors]> {
        APIRequest(.get, "/access/tfa")
    }

    /// Adds an authenticator app. `code` is its current code, which proves it was set up.
    /// `password` is the signed-in user's own password; root@pam does not need it.
    public static func addTOTP(userid: String, secret: TOTPSecret, code: String, description: String, password: String?) -> APIRequest<AddedTwoFactor> {
        var parameters: APIParameters = [
            "type": "totp", "totp": .string(secret.uri), "value": .string(code.filter { !$0.isWhitespace }),
            "description": .string(description.trimmingCharacters(in: .whitespaces)),
        ]
        if let password, !password.isEmpty { parameters["password"] = .string(password) }
        return APIRequest(.post, "/access/tfa/\(escapePath(userid))", parameters: parameters)
    }

    /// Creates the user's recovery keys; the answer lists them, and they cannot be shown again.
    public static func addRecoveryKeys(userid: String, password: String?) -> APIRequest<AddedTwoFactor> {
        var parameters: APIParameters = ["type": "recovery", "description": "Recovery keys"]
        if let password, !password.isEmpty { parameters["password"] = .string(password) }
        return APIRequest(.post, "/access/tfa/\(escapePath(userid))", parameters: parameters)
    }

    public static func updateTwoFactor(userid: String, id: String, description: String, isEnabled: Bool, password: String?) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["description": .string(description.trimmingCharacters(in: .whitespaces)), "enable": .bool(isEnabled)]
        if let password, !password.isEmpty { parameters["password"] = .string(password) }
        return APIRequest(.put, "/access/tfa/\(escapePath(userid))/\(escapePath(id))", parameters: parameters)
    }

    public static func deleteTwoFactor(userid: String, id: String, password: String?) -> APIRequest<Nothing> {
        var parameters = APIParameters()
        if let password, !password.isEmpty { parameters["password"] = .string(password) }
        return APIRequest(.delete, "/access/tfa/\(escapePath(userid))/\(escapePath(id))", parameters: parameters)
    }

    /// Lifts the lock after too many failed second-factor attempts.
    public static func unlockTwoFactor(userid: String) -> APIRequest<Nothing> {
        APIRequest(.put, "/access/users/\(escapePath(userid))/unlock-tfa")
    }
}
