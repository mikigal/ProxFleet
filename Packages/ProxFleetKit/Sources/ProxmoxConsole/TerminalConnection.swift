import Foundation
import ProxmoxCore
import PVEKit

/// A text terminal over Proxmox's `termproxy`, the protocol the web interface's xterm.js console uses.
///
/// After the WebSocket opens, the client sends `user:ticket\n` and the server answers `OK`. Then:
/// input is framed as `0:<byte count>:<bytes>`, a resize as `1:<columns>:<rows>:`, and a keep-alive as `2`.
/// Output arrives as raw terminal bytes.
public final class TerminalConnection: Sendable {
    private let socket: any WebSocketConnection
    /// Terminal output. Finishes when the connection closes, with an error if it failed.
    public let output: AsyncThrowingStream<Data, any Error>
    private let keepAlive: Task<Void, Never>
    private let reader: Task<Void, Never>

    private init(socket: any WebSocketConnection, initialOutput: Data) {
        self.socket = socket
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        output = stream
        if !initialOutput.isEmpty { continuation.yield(initialOutput) }
        reader = Task {
            do {
                while !Task.isCancelled {
                    continuation.yield(try await socket.receive().bytes)
                }
                continuation.finish()
            } catch {
                // Closing the console on purpose is not an error.
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }
        keepAlive = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                try? await socket.send(.text("2"))
            }
        }
    }

    deinit {
        close()
    }

    /// Opens a terminal to a container or a node shell.
    /// - Parameter command: Node shells only: a command the server runs instead of a login shell, such as
    ///   `upgrade` for `apt-get dist-upgrade`, as the web interface's Upgrade button does.
    public static func open(_ target: ConsoleTarget, session: ProxmoxSession, command: String? = nil) async throws -> TerminalConnection {
        var parameters = APIParameters()
        if let command { parameters["cmd"] = .string(command) }
        let (proxy, socket) = try await session.openConsoleSocket(target, endpoint: "termproxy", parameters: parameters)
        try await socket.send(.text("\(proxy.user):\(proxy.ticket)\n"))
        let answer = try await socket.receive().bytes
        guard String(decoding: answer.prefix(2), as: UTF8.self) == "OK" else {
            socket.close()
            throw ProxmoxError.unauthorized("The console did not accept the ticket.")
        }
        // Anything after "OK" in the same frame is already terminal output.
        return TerminalConnection(socket: socket, initialOutput: answer.dropFirst(2))
    }

    public func send(_ input: Data) async throws {
        // The proxy only accepts text frames, like xterm.js sends. Valid UTF-8 input goes as is;
        // anything else is sent byte for byte as Latin-1 characters, which the server decodes back.
        let frame = Self.frame(input: input)
        if let text = String(data: frame, encoding: .utf8) {
            try await socket.send(.text(text))
        } else {
            try await socket.send(.text(String(frame.map { Character(Unicode.Scalar($0)) })))
        }
    }

    public func send(_ text: String) async throws {
        try await send(Data(text.utf8))
    }

    public func resize(columns: Int, rows: Int) async throws {
        try await socket.send(.text(Self.frame(columns: columns, rows: rows)))
    }

    public func close() {
        reader.cancel()
        keepAlive.cancel()
        socket.close()
    }

    static func frame(input: Data) -> Data {
        var data = Data("0:\(input.count):".utf8)
        data.append(input)
        return data
    }

    static func frame(columns: Int, rows: Int) -> String {
        "1:\(columns):\(rows):"
    }
}
