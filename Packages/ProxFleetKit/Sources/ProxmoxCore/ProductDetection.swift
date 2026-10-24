import Foundation

/// Response of `GET /ping`, which only Proxmox Backup Server has.
public struct PingResponse: Decodable, Sendable, Equatable {
    public var pong: Bool

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        pong = container.lossyBool(AnyCodingKey("pong")) ?? false
    }
}

extension ProxmoxAccess {
    /// Answered without authentication by Proxmox Backup Server. Proxmox VE has no such call.
    public static func ping() -> APIRequest<PingResponse> {
        APIRequest(.get, "/ping")
    }
}

extension ProxmoxSession {
    /// Tells which product answers at the session's address, without signing in: Proxmox Backup Server answers
    /// `GET /ping` for anyone, while Proxmox VE refuses every request without a ticket. Other failures, such as an
    /// untrusted certificate or an unreachable host, are thrown as they are.
    public func detectProduct() async throws -> ProxmoxProduct {
        do {
            return try await sendUnauthenticated(ProxmoxAccess.ping()).pong ? .backupServer : .virtualEnvironment
        } catch ProxmoxError.unauthorized {
            return .virtualEnvironment
        }
    }
}
