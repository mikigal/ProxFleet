import CZlib
import Foundation
import ImageIO
@testable import ProxmoxConsole
import ProxmoxCore
import Testing
import UniformTypeIdentifiers

/// A VNC server's side of the socket: answers the handshake, then plays prepared messages.
private final class ScriptedSocket: WebSocketConnection, @unchecked Sendable {
    private var incoming: [[UInt8]] = []
    private var waiters: [CheckedContinuation<WebSocketMessage, any Error>] = []
    private(set) var sent: [[UInt8]] = []
    private let lock = NSLock()

    func push(_ bytes: [UInt8]) {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: .data(Data(bytes)))
        } else {
            incoming.append(bytes)
            lock.unlock()
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        lock.withLock { sent.append(Array(message.bytes)) }
    }

    func receive() async throws -> WebSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !incoming.isEmpty {
                let bytes = incoming.removeFirst()
                lock.unlock()
                continuation.resume(returning: .data(Data(bytes)))
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func close() {}

    var sentMessages: [[UInt8]] { lock.withLock { sent } }
}

/// A zlib stream flushed after each rectangle, as a VNC server sends Tight data.
private final class Deflater {
    private var stream = z_stream()

    init() {
        deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    deinit { deflateEnd(&stream) }

    func compress(_ input: [UInt8]) -> [UInt8] {
        var input = input
        var output = [UInt8](repeating: 0, count: input.count + 1024)
        let produced = input.withUnsafeMutableBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                stream.next_in = inputBuffer.baseAddress
                stream.avail_in = UInt32(inputBuffer.count)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = UInt32(outputBuffer.count)
                deflate(&stream, Z_SYNC_FLUSH)
                return outputBuffer.count - Int(stream.avail_out)
            }
        }
        return Array(output.prefix(produced))
    }
}

struct VNCEncodingTests {
    private func connect(width: Int = 16, height: Int = 16) async throws -> (VNCClient, ScriptedSocket) {
        let socket = ScriptedSocket()
        socket.push(Array("RFB 003.008\n".utf8))
        socket.push([1, 1]) // one security type: none
        socket.push([0, 0, 0, 0]) // security result: OK
        socket.push(be16(width) + be16(height) + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 4] + Array("test".utf8))
        let client = VNCClient(socket: socket)
        try await client.handshake(password: "")
        await client.startReading()
        return (client, socket)
    }

    /// Sends one FramebufferUpdate and waits until the client has drawn it.
    private func update(_ client: VNCClient, _ socket: ScriptedSocket, rects: [[UInt8]]) async throws {
        var events = client.events.makeAsyncIterator()
        socket.push([0, 0] + be16(rects.count) + rects.flatMap { $0 })
        while true {
            if case .updated = try #require(try await events.next()) { return }
        }
    }

    private func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int, encoding: Int32, _ body: [UInt8]) -> [UInt8] {
        be16(x) + be16(y) + be16(width) + be16(height) + be32(UInt32(bitPattern: encoding)) + body
    }

    /// B, G, R of a pixel.
    private func pixel(_ framebuffer: Framebuffer, _ x: Int, _ y: Int) -> [UInt8] {
        let index = (y * framebuffer.width + x) * 4
        return Array(framebuffer.pixels[index..<index + 3])
    }

    @Test func asksForTightFirst() async throws {
        let (client, socket) = try await connect()
        let encodings = try #require(socket.sentMessages.first { $0.first == 2 })
        #expect(Array(encodings[4..<8]) == be32(7))
        #expect(encodings.count == 4 + 4 * 10, "four encodings, four pseudo-encodings, compression and JPEG quality")
        await client.close()
    }

    @Test func tightFillAndSmallPalette() async throws {
        let (client, socket) = try await connect()
        // Fill the screen with red, then a 8×2 two-colour palette rectangle sent uncompressed (2 bytes < 12).
        let fill = rect(0, 0, 16, 16, encoding: 7, [0x80, 255, 0, 0])
        let palette = rect(4, 4, 8, 2, encoding: 7, [0x40, 1, 1, 0, 0, 0, 255, 255, 255] + [0b1010_0000, 0b0000_0001])
        try await update(client, socket, rects: [fill, palette])
        let framebuffer = await client.framebuffer
        #expect(pixel(framebuffer, 0, 0) == [0, 0, 255])
        #expect(pixel(framebuffer, 4, 4) == [255, 255, 255])
        #expect(pixel(framebuffer, 5, 4) == [0, 0, 0])
        #expect(pixel(framebuffer, 6, 4) == [255, 255, 255])
        #expect(pixel(framebuffer, 11, 5) == [255, 255, 255])
        #expect(pixel(framebuffer, 10, 5) == [0, 0, 0])
        await client.close()
    }

    @Test func tightZlibStreamsKeepTheirState() async throws {
        let (client, socket) = try await connect()
        let deflater = Deflater()
        // Copy filter on stream 1, twice; the second rectangle only inflates with the first one's dictionary.
        let rgb: [UInt8] = (0..<64).flatMap { index -> [UInt8] in [UInt8(index * 4), 0x40, 0xC0] }
        let first = deflater.compress(rgb)
        let second = deflater.compress(rgb)
        try await update(client, socket, rects: [
            rect(0, 0, 8, 8, encoding: 7, [0x10] + compactLength(first.count) + first),
            rect(8, 8, 8, 8, encoding: 7, [0x10] + compactLength(second.count) + second),
        ])
        let framebuffer = await client.framebuffer
        #expect(pixel(framebuffer, 1, 0) == [0xC0, 0x40, 4])
        #expect(pixel(framebuffer, 15, 15) == [0xC0, 0x40, 252])
        await client.close()
    }

    @Test func tightPaletteWithManyColoursAndGradient() async throws {
        let (client, socket) = try await connect()
        let deflater = Deflater()
        // Palette filter (0x40 | explicit filter), 3 colours, one byte per pixel.
        let indices = (0..<256).map { UInt8($0 % 3) }
        let compressed = deflater.compress(indices)
        let palette: [UInt8] = [2, 255, 0, 0, 0, 255, 0, 0, 0, 255]
        try await update(client, socket, rects: [rect(0, 0, 16, 16, encoding: 7, [0x40, 1] + palette + compactLength(compressed.count) + compressed)])
        var framebuffer = await client.framebuffer
        #expect(pixel(framebuffer, 0, 0) == [0, 0, 255])
        #expect(pixel(framebuffer, 1, 0) == [0, 255, 0])
        #expect(pixel(framebuffer, 2, 0) == [255, 0, 0])

        // Gradient filter: a smooth ramp becomes small differences.
        let ramp: [UInt8] = (0..<4).flatMap { _ in (0..<4).flatMap { column -> [UInt8] in [UInt8(column * 10), 100, 50] } }
        var differences = [UInt8](repeating: 0, count: ramp.count)
        for row in 0..<4 {
            for column in 0..<4 {
                for component in 0..<3 {
                    let index = (row * 4 + column) * 3 + component
                    let left = column > 0 ? Int(ramp[index - 3]) : 0
                    let above = row > 0 ? Int(ramp[index - 12]) : 0
                    let aboveLeft = row > 0 && column > 0 ? Int(ramp[index - 15]) : 0
                    differences[index] = UInt8((Int(ramp[index]) - max(0, min(255, left + above - aboveLeft))) & 0xFF)
                }
            }
        }
        let gradient = deflater.compress(differences)
        try await update(client, socket, rects: [rect(0, 0, 4, 4, encoding: 7, [0x40, 2] + compactLength(gradient.count) + gradient)])
        framebuffer = await client.framebuffer
        #expect(pixel(framebuffer, 3, 3) == [50, 100, 30])
        await client.close()
    }

    @Test func tightJPEG() async throws {
        let (client, socket) = try await connect()
        let jpeg = try makeJPEG(width: 16, height: 16, red: 200, green: 40, blue: 40)
        try await update(client, socket, rects: [rect(0, 0, 16, 16, encoding: 7, [0x90] + compactLength(jpeg.count) + jpeg)])
        let color = pixel(await client.framebuffer, 8, 8)
        #expect(abs(Int(color[2]) - 200) < 12 && abs(Int(color[1]) - 40) < 12 && abs(Int(color[0]) - 40) < 12)
        await client.close()
    }

    @Test func hextileTiles() async throws {
        let (client, socket) = try await connect(width: 20, height: 16)
        // Tile 1 (16×16): background blue, two foreground subrects in white. Tile 2 (4×16): raw green.
        let blue: [UInt8] = [255, 0, 0, 0], white: [UInt8] = [255, 255, 255, 0]
        var tile1: [UInt8] = [2 | 4 | 8]
        tile1 += blue + white + [2, 0x00, 0x00, 0x33, 0x11]
        let green: [UInt8] = [0, 255, 0, 0]
        let tile2: [UInt8] = [1] + Array(repeating: green, count: 4 * 16).flatMap { $0 }
        try await update(client, socket, rects: [rect(0, 0, 20, 16, encoding: 5, tile1 + tile2)])
        let framebuffer = await client.framebuffer
        #expect(pixel(framebuffer, 0, 0) == [255, 255, 255])
        #expect(pixel(framebuffer, 1, 0) == [255, 0, 0])
        #expect(pixel(framebuffer, 4, 4) == [255, 255, 255])
        #expect(pixel(framebuffer, 3, 3) == [255, 255, 255])
        #expect(pixel(framebuffer, 5, 5) == [255, 0, 0])
        #expect(pixel(framebuffer, 18, 9) == [0, 255, 0])
        await client.close()
    }

    @Test func cursorShapeAndExtendedKeys() async throws {
        let (client, socket) = try await connect()
        var events = client.events.makeAsyncIterator()
        // A 2×2 cursor with its hotspot at 1,1: only the top-left pixel is part of the shape.
        let colors: [UInt8] = [10, 20, 30, 0, 1, 1, 1, 0, 2, 2, 2, 0, 3, 3, 3, 0]
        socket.push([0, 0] + be16(2) + rect(1, 1, 2, 2, encoding: -239, colors + [0x80, 0x00]) + rect(0, 0, 0, 0, encoding: -258, []))
        var cursor: VNCCursor?
        while cursor == nil {
            if case .cursor(let shape) = try #require(try await events.next()) { cursor = shape }
        }
        #expect(cursor?.hotspotX == 1 && cursor?.width == 2)
        #expect(Array(cursor!.pixels[0..<4]) == [10, 20, 30, 255])
        #expect(Array(cursor!.pixels[4..<8]) == [0, 0, 0, 0])
        while true { if case .updated = try #require(try await events.next()) { break } }
        #expect(await client.supportsScancodes)

        await client.sendScancode(Scancode.forHIDUsage(0x52)!, keysym: KeySym.up, down: true)
        let message = try #require(socket.sentMessages.last)
        #expect(message == [255, 0, 0, 1] + be32(KeySym.up) + be32(0xC8))
        await client.close()
    }

    @Test func scancodesForHIDUsages() {
        #expect(Scancode.forHIDUsage(0x04) == 0x1E) // A
        #expect(Scancode.forHIDUsage(0x1D) == 0x2C) // Z
        #expect(Scancode.forHIDUsage(0x27) == 0x0B) // 0
        #expect(Scancode.forHIDUsage(0x45) == 0x58) // F12
        #expect(Scancode.forHIDUsage(0xE3) == 0xE05B) // left Windows/Command
        #expect(Scancode.forHIDUsage(0x61) == 0x49) // keypad 9
        #expect(Scancode.forHIDUsage(0xFF) == nil)
        #expect(Scancode.qemuKeycode(0xE053) == 0xD3)
        #expect(Scancode.qemuKeycode(0x1D) == 0x1D)
    }

    // MARK: - Helpers

    private func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    private func be32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

    private func compactLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        if length < 0x4000 { return [UInt8(length & 0x7F | 0x80), UInt8(length >> 7)] }
        return [UInt8(length & 0x7F | 0x80), UInt8(length >> 7 & 0x7F | 0x80), UInt8(length >> 14)]
    }

    private func makeJPEG(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> [UInt8] {
        let pixels = [UInt8](repeating: 0, count: width * height * 4).enumerated().map { index, _ in
            [red, green, blue, 255][index % 4]
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return [UInt8](data as Data)
    }
}
