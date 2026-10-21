import CoreGraphics
import CoreText
import Foundation
import ProxmoxCore

/// A console started with `termproxy` or `vncproxy`, waiting for its WebSocket.
struct DemoConsoleRequest: Sendable {
    enum Kind: Sendable { case terminal, vnc }

    var kind: Kind
    var hostname: String
    var osName: String
    var isContainer: Bool
    var vmid = 0
    var isWindows = false
}

/// One direction of an in-memory WebSocket.
actor DemoMessageQueue {
    private var messages: [WebSocketMessage] = []
    private var waiter: CheckedContinuation<WebSocketMessage, any Error>?
    private var isClosed = false

    func push(_ message: WebSocketMessage) {
        guard !isClosed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            messages.append(message)
        }
    }

    func pop() async throws -> WebSocketMessage {
        if !messages.isEmpty { return messages.removeFirst() }
        if isClosed { throw ProxmoxError.transport("The console connection closed.") }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        isClosed = true
        waiter?.resume(throwing: ProxmoxError.transport("The console connection closed."))
        waiter = nil
    }
}

/// A WebSocket whose other end is a demo console session in the same process.
final class DemoWebSocket: WebSocketConnection {
    /// Server to client.
    let incoming = DemoMessageQueue()
    /// Client to server.
    let outgoing = DemoMessageQueue()

    func send(_ message: WebSocketMessage) async throws {
        await outgoing.push(message)
    }

    func receive() async throws -> WebSocketMessage {
        try await incoming.pop()
    }

    func close() {
        let incoming = incoming
        let outgoing = outgoing
        Task {
            await incoming.close()
            await outgoing.close()
        }
    }
}

enum DemoConsoleServer {
    static func start(_ request: DemoConsoleRequest) -> DemoWebSocket {
        let socket = DemoWebSocket()
        switch request.kind {
        case .terminal:
            Task { await DemoTerminalSession(request, socket: socket).run() }
        case .vnc:
            Task { await DemoVNCSession(request, socket: socket).run() }
        }
        return socket
    }
}

// MARK: - Terminal

/// Speaks the `termproxy` protocol: a `user:ticket` line answered with `OK`, then framed input.
private actor DemoTerminalSession {
    private var shell: DemoShell
    private let socket: DemoWebSocket

    init(_ request: DemoConsoleRequest, socket: DemoWebSocket) {
        shell = DemoShell(hostname: request.hostname, osName: request.osName, isContainer: request.isContainer, vmid: request.vmid, requiresLogin: false)
        self.socket = socket
    }

    func run() async {
        do {
            _ = try await socket.outgoing.pop() // user:ticket
            await socket.incoming.push(.data(Data(("OK" + shell.greeting()).utf8)))
            while true {
                let frame = String(decoding: try await socket.outgoing.pop().bytes, as: UTF8.self)
                guard frame.hasPrefix("0:"), let separator = frame.dropFirst(2).firstIndex(of: ":") else { continue }
                // The frame holds text; non-UTF-8 bytes arrive as Latin-1 characters.
                let bytes = frame[frame.index(after: separator)...].unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
                let output = shell.input(bytes)
                if !output.text.isEmpty { await socket.incoming.push(.data(Data(output.text.utf8))) }
                if output.closes {
                    socket.close()
                    return
                }
            }
        } catch {
            socket.close()
        }
    }
}

// MARK: - VNC

/// An RFB 3.8 server showing a text console drawn with Core Text, the way a VM's VGA console looks.
private actor DemoVNCSession {
    private let socket: DemoWebSocket
    private let request: DemoConsoleRequest
    private var shell: DemoShell
    private var screen = DemoTextScreen(columns: 64, rows: 24)
    private var buffer: [UInt8] = []
    private var isDirty = true
    private var wantsUpdate = false
    private var controlDown = false
    private var message: String?

    static let cellWidth = 8
    static let cellHeight = 16
    private var width: Int { screen.columns * Self.cellWidth }
    private var height: Int { screen.rows * Self.cellHeight }

    init(_ request: DemoConsoleRequest, socket: DemoWebSocket) {
        self.request = request
        self.socket = socket
        shell = DemoShell(hostname: request.hostname, osName: request.osName, isContainer: false, vmid: request.vmid, requiresLogin: true)
    }

    func run() async {
        do {
            try await handshake()
            screen.write(request.isWindows ? "" : shell.greeting())
            while true {
                try await readMessage()
                if wantsUpdate, isDirty {
                    wantsUpdate = false
                    isDirty = false
                    await sendScreen()
                }
            }
        } catch {
            socket.close()
        }
    }

    private func handshake() async throws {
        await send(Array("RFB 003.008\n".utf8))
        _ = try await read(12)
        await send([1, 2]) // one security type: VNC authentication
        _ = try await read(1)
        await send((0..<16).map { _ in UInt8.random(in: 0...255) })
        _ = try await read(16) // any password is fine in the demo
        await send([0, 0, 0, 0])
        _ = try await read(1) // ClientInit
        let name = Array(request.hostname.utf8)
        let pixelFormat: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        await send(Self.bytes(UInt16(width)) + Self.bytes(UInt16(height)) + pixelFormat + Self.bytes(UInt32(name.count)) + name)
    }

    private func readMessage() async throws {
        switch try await read(1)[0] {
        case 0: _ = try await read(19) // SetPixelFormat; the client always asks for the format offered
        case 2:
            _ = try await read(1)
            let count = Int(try await readUInt16())
            _ = try await read(count * 4)
        case 3:
            let incremental = try await read(9)[0] == 1
            wantsUpdate = true
            if !incremental { isDirty = true }
        case 4:
            let fields = try await read(7)
            let keysym = fields[3...6].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            key(keysym, down: fields[0] == 1)
        case 5: _ = try await read(5)
        case 6:
            _ = try await read(3)
            _ = try await read(Int(try await readUInt32()))
        case let type:
            throw ProxmoxError.invalidResponse("unknown VNC client message \(type)")
        }
    }

    private func key(_ keysym: UInt32, down: Bool) {
        if keysym == 0xFFE3 || keysym == 0xFFE4 {
            controlDown = down
            return
        }
        guard down else { return }
        if request.isWindows {
            message = "This desktop is part of the ProxFleet demo and cannot be unlocked."
            isDirty = true
            return
        }
        let byte: UInt8?
        switch keysym {
        case 0xFF0D, 0xFF8D: byte = 0x0D
        case 0xFF08: byte = 0x7F
        case 0xFF09: byte = 0x09
        case 0x20...0x7E:
            let ascii = UInt8(keysym)
            byte = controlDown && ascii >= 0x40 ? ascii & 0x1F : ascii
        default: byte = nil
        }
        guard let byte else { return }
        let output = shell.input([byte])
        screen.write(output.text)
        if output.closes {
            shell = DemoShell(hostname: request.hostname, osName: request.osName, isContainer: false, vmid: request.vmid, requiresLogin: true)
            screen.write(shell.greeting())
        }
        isDirty = true
    }

    private func sendScreen() async {
        let pixels = request.isWindows ? renderLockScreen() : screen.render(cellWidth: Self.cellWidth, cellHeight: Self.cellHeight)
        var update: [UInt8] = [0, 0, 0, 1]
        update += [0, 0, 0, 0] + Self.bytes(UInt16(width)) + Self.bytes(UInt16(height)) + [0, 0, 0, 0]
        update += pixels
        await send(update)
    }

    private func renderLockScreen() -> [UInt8] {
        var lines = Array(repeating: "", count: 9) + ["Windows 11", "", "Press Ctrl+Alt+Delete to unlock."]
        if let message { lines += ["", message] }
        return DemoTextScreen.render(lines: lines, columns: screen.columns, rows: screen.rows, cellWidth: Self.cellWidth, cellHeight: Self.cellHeight, background: (0.0, 0.33, 0.62), centered: true)
    }

    // MARK: Bytes

    private func send(_ bytes: [UInt8]) async {
        await socket.incoming.push(.data(Data(bytes)))
    }

    private func read(_ count: Int) async throws -> [UInt8] {
        while buffer.count < count {
            buffer += try await socket.outgoing.pop().bytes
        }
        let bytes = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        return bytes
    }

    private func readUInt16() async throws -> UInt16 {
        let bytes = try await read(2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func readUInt32() async throws -> UInt32 {
        try await read(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func bytes(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

/// A grid of characters fed with terminal output. Understands line breaks, backspace and clearing the screen;
/// other escape sequences, such as colours, are dropped.
struct DemoTextScreen {
    let columns: Int
    let rows: Int
    private var lines: [[Character]]
    private var row = 0
    private var column = 0
    private var escape: [Character]?

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        lines = Array(repeating: Array(repeating: " ", count: columns), count: rows)
    }

    mutating func write(_ text: String) {
        for character in text {
            if var sequence = escape {
                sequence.append(character)
                if sequence.count > 1, let scalar = character.unicodeScalars.first, (0x40...0x7E).contains(scalar.value) {
                    if String(sequence) == "[2J" { clear() }
                    if String(sequence) == "[H" { row = 0; column = 0 }
                    escape = nil
                } else {
                    escape = sequence
                }
                continue
            }
            switch character {
            case "\u{1B}": escape = []
            case "\r": column = 0
            case "\n", "\r\n": newLine()
            case "\u{8}": column = max(0, column - 1)
            case "\t": column = min(columns - 1, (column / 8 + 1) * 8)
            default:
                if column >= columns { column = 0; newLine() }
                lines[row][column] = character
                column += 1
            }
            if character == "\r\n" { column = 0 }
        }
    }

    private mutating func newLine() {
        if row == rows - 1 {
            lines.removeFirst()
            lines.append(Array(repeating: " ", count: columns))
        } else {
            row += 1
        }
    }

    private mutating func clear() {
        lines = Array(repeating: Array(repeating: " ", count: columns), count: rows)
        row = 0
        column = 0
    }

    func render(cellWidth: Int, cellHeight: Int) -> [UInt8] {
        var text = lines.map { String($0) }
        // Block cursor.
        if row < rows, column < columns {
            var cursorLine = lines[row]
            cursorLine[column] = "_"
            text[row] = String(cursorLine)
        }
        return Self.render(lines: text, columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight, background: (0, 0, 0), centered: false)
    }

    /// Draws lines of text into 32-bit pixels stored as B, G, R, X, the format the VNC client asks for.
    static func render(lines: [String], columns: Int, rows: Int, cellWidth: Int, cellHeight: Int, background: (Double, Double, Double), centered: Bool) -> [UInt8] {
        let width = columns * cellWidth
        let height = rows * cellHeight
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            context.setFillColor(CGColor(red: background.0, green: background.1, blue: background.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Menlo" as CFString, CGFloat(cellHeight) * 0.8, nil)
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1),
            ]
            for (index, line) in lines.prefix(rows).enumerated() {
                let trimmed = centered ? line.trimmingCharacters(in: .whitespaces) : line
                guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let attributed = CFAttributedStringCreate(nil, trimmed as CFString, attributes as CFDictionary)!
                let ctLine = CTLineCreateWithAttributedString(attributed)
                let x = centered ? (Double(width) - CTLineGetTypographicBounds(ctLine, nil, nil, nil)) / 2 : 0
                context.textPosition = CGPoint(x: x, y: Double(height - (index + 1) * cellHeight) + Double(cellHeight) * 0.25)
                CTLineDraw(ctLine, context)
            }
        }
        return pixels
    }
}
