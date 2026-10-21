import Foundation
import ProxmoxCore
import PVEKit

/// Pixels of the remote screen, 32 bits per pixel in BGRA byte order (little-endian XRGB).
public struct Framebuffer: Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var pixels: [UInt8]

    public static let bytesPerPixel = 4

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * Self.bytesPerPixel)
    }

    public var bytesPerRow: Int { width * Self.bytesPerPixel }

    mutating func resize(width: Int, height: Int) {
        self = Framebuffer(width: width, height: height)
    }

    /// Copies rows of raw pixels into a rectangle, clipping to the screen.
    mutating func write(_ source: [UInt8], x: Int, y: Int, width rectWidth: Int, height rectHeight: Int) {
        guard x < width, y < height else { return }
        let copyWidth = min(rectWidth, width - x) * Self.bytesPerPixel
        let rows = min(rectHeight, height - y)
        let rowStride = bytesPerRow
        source.withUnsafeBufferPointer { sourceBuffer in
            pixels.withUnsafeMutableBufferPointer { target in
                for row in 0..<rows {
                    let sourceOffset = row * rectWidth * Self.bytesPerPixel
                    let targetOffset = (y + row) * rowStride + x * Self.bytesPerPixel
                    UnsafeMutableRawPointer(target.baseAddress! + targetOffset)
                        .copyMemory(from: sourceBuffer.baseAddress! + sourceOffset, byteCount: copyWidth)
                }
            }
        }
    }

    /// CopyRect: moves a rectangle within the screen. Handles overlapping areas.
    mutating func copy(fromX sourceX: Int, fromY sourceY: Int, toX x: Int, toY y: Int, width rectWidth: Int, height rectHeight: Int) {
        guard sourceX + rectWidth <= width, sourceY + rectHeight <= height, x + rectWidth <= width, y + rectHeight <= height else { return }
        let rowBytes = rectWidth * Self.bytesPerPixel
        let rowStride = bytesPerRow
        let rows = Array(y < sourceY ? Array(0..<rectHeight) : Array((0..<rectHeight).reversed()))
        pixels.withUnsafeMutableBufferPointer { buffer in
            for row in rows {
                let from = (sourceY + row) * rowStride + sourceX * Self.bytesPerPixel
                let to = (y + row) * rowStride + x * Self.bytesPerPixel
                UnsafeMutableRawPointer(buffer.baseAddress! + to).copyMemory(from: buffer.baseAddress! + from, byteCount: rowBytes)
            }
        }
    }
}

/// X11 keysyms used by VNC key events.
public enum KeySym {
    public static let backspace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let returnKey: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let home: UInt32 = 0xFF50
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let insert: UInt32 = 0xFF63
    public static let delete: UInt32 = 0xFFFF
    public static let shift: UInt32 = 0xFFE1
    public static let control: UInt32 = 0xFFE3
    public static let alt: UInt32 = 0xFFE9
    public static let superKey: UInt32 = 0xFFEB

    /// F1 to F12.
    public static func function(_ number: Int) -> UInt32 { 0xFFBE + UInt32(number - 1) }

    /// Keysym for a typed character.
    public static func character(_ scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x0A, 0x0D: returnKey
        case 0x09: tab
        case 0x08, 0x7F: backspace
        case 0x1B: escape
        case 0x20...0xFF: scalar.value
        default: 0x0100_0000 + scalar.value
        }
    }

    /// Characters that need Shift on a US keyboard layout, which QEMU uses unless the VM says otherwise.
    public static func needsShift(_ scalar: Unicode.Scalar) -> Bool {
        if ("A"..."Z").contains(scalar) { return true }
        return "~!@#$%^&*()_+{}|:\"<>?".unicodeScalars.contains(scalar)
    }
}

/// A VNC (RFB 3.8) client for the graphical console of a VM, over Proxmox's `vncproxy` WebSocket.
///
/// Supports VNC authentication and the Raw, CopyRect and DesktopSize encodings, which QEMU always offers.
public actor VNCClient {
    public enum Event: Sendable {
        /// The screen changed. Read `framebuffer` for the new pixels.
        case updated
        case resized(width: Int, height: Int)
        case bell
        case clipboard(String)
    }

    public private(set) var framebuffer = Framebuffer(width: 0, height: 0)
    public private(set) var name = ""
    public nonisolated let events: AsyncThrowingStream<Event, any Error>

    private let socket: any WebSocketConnection
    private let continuation: AsyncThrowingStream<Event, any Error>.Continuation
    private var buffer: [UInt8] = []
    private var offset = 0
    private var reader: Task<Void, Never>?

    private enum Encoding: Int32 {
        case raw = 0
        case copyRect = 1
        case desktopSize = -223
    }

    init(socket: any WebSocketConnection) {
        self.socket = socket
        (events, continuation) = AsyncThrowingStream<Event, any Error>.makeStream()
    }

    /// Starts a VNC proxy for the VM, connects and authenticates.
    public static func open(_ guest: GuestReference, session: ProxmoxSession) async throws -> VNCClient {
        let (proxy, socket) = try await session.openConsoleSocket(
            .virtualMachine(guest),
            endpoint: "vncproxy",
            parameters: ["websocket": true, "generate-password": true]
        )
        let client = VNCClient(socket: socket)
        do {
            try await client.handshake(password: proxy.password ?? proxy.ticket)
        } catch {
            socket.close()
            throw error
        }
        await client.startReading()
        return client
    }

    public func close() {
        reader?.cancel()
        socket.close()
        continuation.finish()
    }

    // MARK: - Input

    public func sendKey(_ keysym: UInt32, down: Bool) async {
        var message: [UInt8] = [4, down ? 1 : 0, 0, 0]
        message += Self.bytes(keysym)
        try? await socket.send(.data(Data(message)))
    }

    /// Presses and releases a key, with Shift around it when the character needs it.
    public func type(_ text: String) async {
        for scalar in text.unicodeScalars {
            let shift = KeySym.needsShift(scalar)
            if shift { await sendKey(KeySym.shift, down: true) }
            let keysym = KeySym.character(scalar)
            await sendKey(keysym, down: true)
            await sendKey(keysym, down: false)
            if shift { await sendKey(KeySym.shift, down: false) }
        }
    }

    /// Presses keys together and releases them in reverse order, e.g. Ctrl+Alt+Delete.
    public func sendCombination(_ keysyms: [UInt32]) async {
        for keysym in keysyms { await sendKey(keysym, down: true) }
        for keysym in keysyms.reversed() { await sendKey(keysym, down: false) }
    }

    /// Button mask: bit 0 left, bit 1 middle, bit 2 right, bits 3 and 4 scroll up and down.
    public func sendPointer(x: Int, y: Int, buttons: UInt8) async {
        let clampedX = UInt16(max(0, min(x, framebuffer.width - 1)))
        let clampedY = UInt16(max(0, min(y, framebuffer.height - 1)))
        let message: [UInt8] = [5, buttons, UInt8(clampedX >> 8), UInt8(clampedX & 0xFF), UInt8(clampedY >> 8), UInt8(clampedY & 0xFF)]
        try? await socket.send(.data(Data(message)))
    }

    /// Asks for the whole screen again, e.g. after the view was hidden.
    public func refreshScreen() async {
        try? await requestUpdate(incremental: false)
    }

    // MARK: - Handshake

    private func handshake(password: String) async throws {
        let version = try await read(12)
        guard String(decoding: version, as: UTF8.self).hasPrefix("RFB 003.") else {
            throw ProxmoxError.invalidResponse("not a VNC server")
        }
        try await socket.send(.data(Data("RFB 003.008\n".utf8)))

        let typeCount = Int(try await read(1)[0])
        if typeCount == 0 {
            throw ProxmoxError.api(status: 500, message: try await readReason(), fieldErrors: [:])
        }
        let types = try await read(typeCount)
        if types.contains(2) {
            try await socket.send(.data(Data([2])))
            let challenge = try await read(16)
            try await socket.send(.data(Data(VNCAuthentication.response(challenge: challenge, password: password))))
        } else if types.contains(1) {
            try await socket.send(.data(Data([1])))
        } else {
            throw ProxmoxError.invalidResponse("unsupported VNC security types \(types)")
        }
        if try await readUInt32() != 0 {
            throw ProxmoxError.unauthorized(try await readReason())
        }

        try await socket.send(.data(Data([1]))) // ClientInit, shared session
        let width = Int(try await readUInt16())
        let height = Int(try await readUInt16())
        _ = try await read(16) // server pixel format, replaced below
        let nameLength = Int(try await readUInt32())
        name = String(decoding: try await read(nameLength), as: UTF8.self)
        framebuffer.resize(width: width, height: height)

        // 32 bpp, depth 24, little-endian, true colour, red at bit 16: bytes arrive as B, G, R, X.
        let pixelFormat: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        try await socket.send(.data(Data([0, 0, 0, 0] + pixelFormat)))
        let encodings: [Encoding] = [.copyRect, .raw, .desktopSize]
        var setEncodings: [UInt8] = [2, 0] + Self.bytes(UInt16(encodings.count))
        for encoding in encodings { setEncodings += Self.bytes(UInt32(bitPattern: encoding.rawValue)) }
        try await socket.send(.data(Data(setEncodings)))
        continuation.yield(.resized(width: width, height: height))
        try await requestUpdate(incremental: false)
    }

    private func readReason() async throws -> String {
        let length = Int(try await readUInt32())
        return String(decoding: try await read(length), as: UTF8.self)
    }

    // MARK: - Server messages

    private func startReading() {
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await self?.readMessage()
                }
            } catch {
                await self?.finish(error)
            }
        }
    }

    private func finish(_ error: any Error) {
        if Task.isCancelled {
            continuation.finish()
        } else {
            continuation.finish(throwing: error)
        }
    }

    private func readMessage() async throws {
        switch try await read(1)[0] {
        case 0:
            try await readFramebufferUpdate()
            try await requestUpdate(incremental: true)
        case 1: // SetColourMapEntries, unused with true colour
            _ = try await read(3)
            let count = Int(try await readUInt16())
            _ = try await read(count * 6)
        case 2:
            continuation.yield(.bell)
        case 3:
            _ = try await read(3)
            let length = Int(try await readUInt32())
            continuation.yield(.clipboard(String(decoding: try await read(length), as: UTF8.self)))
        case let type:
            throw ProxmoxError.invalidResponse("unknown VNC message \(type)")
        }
    }

    private func readFramebufferUpdate() async throws {
        _ = try await read(1)
        let count = Int(try await readUInt16())
        for _ in 0..<count {
            let x = Int(try await readUInt16())
            let y = Int(try await readUInt16())
            let width = Int(try await readUInt16())
            let height = Int(try await readUInt16())
            let encoding = Int32(bitPattern: try await readUInt32())
            switch Encoding(rawValue: encoding) {
            case .raw:
                let pixels = try await read(width * height * Framebuffer.bytesPerPixel)
                framebuffer.write(pixels, x: x, y: y, width: width, height: height)
            case .copyRect:
                let sourceX = Int(try await readUInt16())
                let sourceY = Int(try await readUInt16())
                framebuffer.copy(fromX: sourceX, fromY: sourceY, toX: x, toY: y, width: width, height: height)
            case .desktopSize:
                framebuffer.resize(width: width, height: height)
                continuation.yield(.resized(width: width, height: height))
            case nil:
                throw ProxmoxError.invalidResponse("unexpected VNC encoding \(encoding)")
            }
        }
        continuation.yield(.updated)
    }

    private func requestUpdate(incremental: Bool) async throws {
        var message: [UInt8] = [3, incremental ? 1 : 0, 0, 0, 0, 0]
        message += Self.bytes(UInt16(framebuffer.width))
        message += Self.bytes(UInt16(framebuffer.height))
        try await socket.send(.data(Data(message)))
    }

    // MARK: - Reading

    /// Reads exactly `count` bytes, pulling WebSocket messages as needed.
    private func read(_ count: Int) async throws -> [UInt8] {
        while buffer.count - offset < count {
            if offset > 0 && offset == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                offset = 0
            }
            buffer += try await socket.receive().bytes
        }
        let bytes = Array(buffer[offset..<offset + count])
        offset += count
        if offset > 1_048_576 {
            buffer.removeFirst(offset)
            offset = 0
        }
        return bytes
    }

    private func readUInt16() async throws -> UInt16 {
        let bytes = try await read(2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func readUInt32() async throws -> UInt32 {
        let bytes = try await read(4)
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func bytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
