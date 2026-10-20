import Foundation

/// A full authentication ticket. Valid for two hours from `issuedAt`, renewable before that.
public struct AuthTicket: Sendable, Codable, Equatable {
    /// Full user ID including realm, e.g. `root@pam`.
    public var username: String
    public var ticket: String
    public var csrfToken: String
    public var issuedAt: Date
    /// Present when the server is part of a cluster.
    public var clusterName: String?

    public init(username: String, ticket: String, csrfToken: String, issuedAt: Date, clusterName: String? = nil) {
        self.username = username
        self.ticket = ticket
        self.csrfToken = csrfToken
        self.issuedAt = issuedAt
        self.clusterName = clusterName
    }

    public static let lifetime: TimeInterval = 2 * 60 * 60

    public func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince(issuedAt) >= Self.lifetime - 60
    }
}

/// Second factors the server offers after the password was accepted.
public struct SecondFactorChallenge: Sendable, Equatable {
    /// Half-authenticated ticket, sent back together with the second factor.
    public var partialTicket: String
    public var username: String
    public var totp: Bool
    public var recovery: Bool
    public var yubico: Bool
    /// WebAuthn and U2F need a browser bound to the server's domain, so the app cannot complete them.
    public var webAuthn: Bool
    public var u2f: Bool

    public init(partialTicket: String, username: String, totp: Bool = false, recovery: Bool = false, yubico: Bool = false, webAuthn: Bool = false, u2f: Bool = false) {
        self.partialTicket = partialTicket
        self.username = username
        self.totp = totp
        self.recovery = recovery
        self.yubico = yubico
        self.webAuthn = webAuthn
        self.u2f = u2f
    }

    public var supportedMethods: [SecondFactorMethod] {
        var methods: [SecondFactorMethod] = []
        if totp { methods.append(.totp) }
        if yubico { methods.append(.yubico) }
        if recovery { methods.append(.recovery) }
        return methods
    }

    /// Parses the challenge embedded in a partial ticket: `PVE:!tfa!<percent-encoded JSON>:...`.
    /// Returns nil when the ticket is a regular, full ticket.
    static func parse(ticket: String, username: String, product: ProxmoxProduct) -> SecondFactorChallenge? {
        let marker = "\(product.ticketPrefix):!tfa!"
        guard ticket.hasPrefix(marker) else { return nil }
        let encoded = ticket.dropFirst(marker.count).prefix { $0 != ":" }
        var challenge = SecondFactorChallenge(partialTicket: ticket, username: username)
        guard let json = String(encoded).removingPercentEncoding,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return challenge }

        func isOffered(_ value: Any?) -> Bool {
            switch value {
            case nil, is NSNull: false
            case let flag as Bool: flag
            case let number as NSNumber: number.intValue != 0
            case let list as [Any]: !list.isEmpty
            case let text as String: !text.isEmpty
            default: true
            }
        }
        challenge.totp = isOffered(object["totp"])
        challenge.recovery = isOffered(object["recovery"])
        challenge.yubico = isOffered(object["yubico"])
        challenge.webAuthn = isOffered(object["webauthn"])
        challenge.u2f = isOffered(object["u2f"])
        return challenge
    }
}

public enum SecondFactorMethod: String, Sendable, CaseIterable, Identifiable {
    case totp
    case yubico
    case recovery

    public var id: String { rawValue }
}

public enum LoginOutcome: Sendable, Equatable {
    case authenticated(AuthTicket)
    case needsSecondFactor(SecondFactorChallenge)
}

/// Response of `POST /access/ticket`.
struct TicketResponse: Decodable, Sendable {
    var username: String
    var ticket: String
    var csrfToken: String?
    var clusterName: String?

    enum CodingKeys: String, CodingKey {
        case username, ticket
        case csrfToken = "CSRFPreventionToken"
        case clusterName = "clustername"
    }
}

/// An authentication realm such as `pam` or `pve`, from `GET /access/domains`.
public struct Realm: Sendable, Equatable, Identifiable, Decodable {
    public var realm: String
    public var type: String
    public var comment: String?
    public var isDefault: Bool

    public var id: String { realm }

    /// Text shown in the realm picker, matching the web UI.
    public var displayName: String {
        if let comment, !comment.isEmpty { return comment }
        return realm
    }

    public init(realm: String, type: String, comment: String? = nil, isDefault: Bool = false) {
        self.realm = realm
        self.type = type
        self.comment = comment
        self.isDefault = isDefault
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let realm = container.lossyString(AnyCodingKey("realm")) else {
            throw ProxmoxError.invalidResponse("realm without name")
        }
        self.realm = realm
        type = container.lossyString(AnyCodingKey("type")) ?? realm
        comment = container.lossyString(AnyCodingKey("comment"))
        isDefault = container.lossyBool(AnyCodingKey("default")) ?? false
    }
}

/// Endpoints shared by all Proxmox products.
public enum ProxmoxAccess {
    /// Lists login realms. Works without authentication.
    public static func realms() -> APIRequest<[Realm]> {
        APIRequest(.get, "/access/domains")
    }
}
