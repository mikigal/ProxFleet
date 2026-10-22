import Foundation
import ProxmoxCore
import PVEKit

/// What a console connects to.
public enum ConsoleTarget: Sendable, Hashable {
    /// Text terminal of a container (`pct enter`).
    case container(GuestReference)
    /// Graphical console of a VM.
    case virtualMachine(GuestReference)
    /// Shell on a node.
    case node(String)
    /// A serial port of a VM (`serial0`…`serial3`), as the web interface's xterm.js console shows it.
    case serial(GuestReference, port: String)

    /// Base path of the proxy endpoints, e.g. `/nodes/pve/lxc/200`.
    var path: String {
        switch self {
        case .container(let guest), .virtualMachine(let guest), .serial(let guest, _): guest.path
        case .node(let node): "/nodes/\(node)"
        }
    }
}

/// Response of `termproxy` and `vncproxy`: a one-time port and ticket for the WebSocket.
public struct ConsoleProxy: Decodable, Sendable, Equatable {
    public var port: Int
    public var ticket: String
    public var user: String
    /// VNC password when requested with `generate-password`.
    public var password: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let port = container.lossyInt(AnyCodingKey("port")), let ticket = container.lossyString(AnyCodingKey("ticket")) else {
            throw ProxmoxError.invalidResponse("console proxy without port or ticket")
        }
        self.port = port
        self.ticket = ticket
        user = container.lossyString(AnyCodingKey("user")) ?? ""
        password = container.lossyString(AnyCodingKey("password"))
    }
}

extension ProxmoxSession {
    /// Starts a console proxy on the node and opens the WebSocket to it.
    func openConsoleSocket(_ target: ConsoleTarget, endpoint: String, parameters: APIParameters) async throws -> (ConsoleProxy, any WebSocketConnection) {
        let proxy = try await send(APIRequest<ConsoleProxy>(.post, target.path + "/" + endpoint, parameters: parameters))
        let socket = try await openWebSocket(
            path: target.path + "/vncwebsocket",
            parameters: ["port": .int(proxy.port), "vncticket": .string(proxy.ticket)]
        )
        return (proxy, socket)
    }
}
