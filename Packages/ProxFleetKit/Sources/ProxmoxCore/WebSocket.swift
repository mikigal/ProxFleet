import Foundation

public enum WebSocketMessage: Sendable, Equatable {
    case data(Data)
    case text(String)

    /// Payload as bytes, whatever the frame type.
    public var bytes: Data {
        switch self {
        case .data(let data): data
        case .text(let text): Data(text.utf8)
        }
    }
}

/// An open WebSocket, used for consoles.
public protocol WebSocketConnection: AnyObject, Sendable {
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
    func close()
}

/// A transport that can also open WebSockets with the same TLS trust rules as its HTTP requests.
public protocol WebSocketTransport: HTTPTransport {
    func openWebSocket(_ request: HTTPRequest, protocols: [String]) async throws -> any WebSocketConnection
}

extension ProxmoxSession {
    /// Opens an authenticated WebSocket to an API path such as `/nodes/pve/lxc/100/vncwebsocket`.
    public func openWebSocket(path: String, parameters: APIParameters, protocols: [String] = ["binary"]) async throws -> any WebSocketConnection {
        guard let transport = webSocketTransport else {
            throw ProxmoxError.transport("This connection does not support consoles.")
        }
        var request = try buildRequest(APIRequest<Nothing>(.get, path, parameters: parameters), authenticated: true)
        // WebSockets live under the plain JSON API, not the ExtJS one.
        if var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) {
            components.scheme = "wss"
            components.percentEncodedPath = components.percentEncodedPath.replacingOccurrences(of: APIFormat.pathPrefix, with: "/api2/json")
            if let url = components.url { request.url = url }
        }
        request.headers["Accept"] = nil
        return try await transport.openWebSocket(request, protocols: protocols)
    }

    nonisolated var webSocketTransport: (any WebSocketTransport)? {
        transportForWebSockets
    }
}
