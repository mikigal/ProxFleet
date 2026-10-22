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
        guard x < width, y < height, rectWidth > 0, source.count >= rectWidth * rectHeight * Self.bytesPerPixel else { return }
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

    /// Fills a rectangle with one colour, given as B, G, R, X bytes.
    mutating func fill(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, color: (UInt8, UInt8, UInt8, UInt8)) {
        guard x < width, y < height else { return }
        let columns = min(rectWidth, width - x)
        let rows = min(rectHeight, height - y)
        let rowStride = bytesPerRow
        pixels.withUnsafeMutableBufferPointer { target in
            for row in 0..<rows {
                var offset = (y + row) * rowStride + x * Self.bytesPerPixel
                for _ in 0..<columns {
                    target[offset] = color.0
                    target[offset + 1] = color.1
                    target[offset + 2] = color.2
                    target[offset + 3] = color.3
                    offset += Self.bytesPerPixel
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

/// The mouse pointer's shape, sent by the server so the client can draw it without waiting for screen updates.
public struct VNCCursor: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// The point of the image that is the pointer's position.
    public var hotspotX: Int
    public var hotspotY: Int
    /// Premultiplied B, G, R, A bytes; transparent outside the shape.
    public var pixels: [UInt8]
}

/// X11 keysyms used by VNC key events.
public enum KeySym {
    public static let backspace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let returnKey: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let printScreen: UInt32 = 0xFF61
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
/// Asks for the Tight encoding, which compresses flat screen areas such as windows and text well, with Hextile,
/// CopyRect and Raw as fallbacks. Also takes the pointer's shape from the server, and QEMU's extended key events,
/// which send keys as physical scancodes.
public actor VNCClient {
    public enum Event: Sendable {
        /// The screen changed. Read `framebuffer` for the new pixels.
        case updated
        case resized(width: Int, height: Int)
        case cursor(VNCCursor)
        case bell
        case clipboard(String)
    }

    /// How much the server compresses the screen.
    public enum Quality: String, Sendable, CaseIterable {
        /// Lossless: text and lines stay sharp.
        case best
        /// Photos and gradients as good JPEG.
        case balanced
        /// Strong JPEG and zlib compression, for slow or metered connections.
        case dataSaver

        /// JPEG quality 0–9, nil for lossless.
        var jpegQuality: Int32? {
            switch self {
            case .best: nil
            case .balanced: 7
            case .dataSaver: 3
            }
        }

        /// zlib effort 0–9.
        var compressionLevel: Int32 {
            switch self {
            case .best: 6
            case .balanced: 6
            case .dataSaver: 9
            }
        }
    }

    public private(set) var framebuffer = Framebuffer(width: 0, height: 0)
    public private(set) var name = ""
    /// The server takes QEMU's extended key events, so `sendScancode` reaches the guest as physical keys.
    public private(set) var supportsScancodes = false
    /// Bytes received since connecting, for the connection's data use.
    public private(set) var receivedBytes = 0
    public nonisolated let events: AsyncThrowingStream<Event, any Error>

    private let socket: any WebSocketConnection
    private let continuation: AsyncThrowingStream<Event, any Error>.Continuation
    private var buffer: [UInt8] = []
    private var offset = 0
    private var reader: Task<Void, Never>?
    private var quality: Quality
    /// Tight's four zlib streams, which keep their state from one rectangle to the next.
    private let tightStreams = (0..<4).map { _ in ZlibInflater() }
    /// The encodings to ask for, best first; tests compare them.
    var preferredEncodings: [Encoding] = [.tight, .hextile, .copyRect, .raw]
    /// Rectangles received, by encoding, and Tight rectangles by compression type (8 fill, 9 JPEG, else basic).
    private(set) var rectangleCounts: [Int32: Int] = [:]
    private(set) var tightCompressionCounts: [UInt8: Int] = [:]

    enum Encoding: Int32 {
        case raw = 0
        case copyRect = 1
        case hextile = 5
        case tight = 7
        case desktopSize = -223
        case lastRect = -224
        case cursor = -239
        case qemuExtendedKeyEvent = -258
    }

    init(socket: any WebSocketConnection, quality: Quality = .balanced) {
        self.socket = socket
        self.quality = quality
        (events, continuation) = AsyncThrowingStream<Event, any Error>.makeStream()
    }

    /// Starts a VNC proxy for the VM, connects and authenticates.
    public static func open(_ guest: GuestReference, session: ProxmoxSession, quality: Quality = .balanced) async throws -> VNCClient {
        try await open(guest, session: session, quality: quality, encodings: nil)
    }

    static func open(_ guest: GuestReference, session: ProxmoxSession, quality: Quality, encodings: [Encoding]?) async throws -> VNCClient {
        let (proxy, socket) = try await session.openConsoleSocket(
            .virtualMachine(guest),
            endpoint: "vncproxy",
            parameters: ["websocket": true, "generate-password": true]
        )
        let client = VNCClient(socket: socket, quality: quality)
        if let encodings { await client.setPreferredEncodings(encodings) }
        do {
            try await client.handshake(password: proxy.password ?? proxy.ticket)
        } catch {
            socket.close()
            throw error
        }
        await client.startReading()
        return client
    }

    private func setPreferredEncodings(_ encodings: [Encoding]) {
        preferredEncodings = encodings
    }

    public func close() {
        reader?.cancel()
        socket.close()
        continuation.finish()
    }

    /// Changes the compression; the server applies it to the next updates.
    public func setQuality(_ quality: Quality) async {
        guard quality != self.quality else { return }
        self.quality = quality
        try? await sendEncodings()
    }

    // MARK: - Input

    public func sendKey(_ keysym: UInt32, down: Bool) async {
        var message: [UInt8] = [4, down ? 1 : 0, 0, 0]
        message += Self.bytes(keysym)
        try? await socket.send(.data(Data(message)))
    }

    /// A physical key, when `supportsScancodes`; otherwise the keysym, if any.
    public func sendScancode(_ scancode: UInt16, keysym: UInt32, down: Bool) async {
        guard supportsScancodes else {
            if keysym != 0 { await sendKey(keysym, down: down) }
            return
        }
        var message: [UInt8] = [255, 0] + Self.bytes(UInt16(down ? 1 : 0))
        message += Self.bytes(keysym)
        message += Self.bytes(Scancode.qemuKeycode(scancode))
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

    func handshake(password: String) async throws {
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
        try await sendEncodings()
        continuation.yield(.resized(width: width, height: height))
        try await requestUpdate(incremental: false)
    }

    /// The server uses the first encoding of the list it supports; pseudo-encodings announce features.
    private func sendEncodings() async throws {
        var encodings: [Int32] = preferredEncodings.map(\.rawValue)
        encodings += [Encoding.desktopSize, .lastRect, .cursor, .qemuExtendedKeyEvent].map(\.rawValue)
        encodings.append(-256 + quality.compressionLevel)
        if let jpeg = quality.jpegQuality { encodings.append(-32 + jpeg) }
        var message: [UInt8] = [2, 0] + Self.bytes(UInt16(encodings.count))
        for encoding in encodings { message += Self.bytes(UInt32(bitPattern: encoding)) }
        try await socket.send(.data(Data(message)))
    }

    private func readReason() async throws -> String {
        let length = Int(try await readUInt32())
        return String(decoding: try await read(length), as: UTF8.self)
    }

    // MARK: - Server messages

    func startReading() {
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
        rects: for _ in 0..<count {
            let x = Int(try await readUInt16())
            let y = Int(try await readUInt16())
            let width = Int(try await readUInt16())
            let height = Int(try await readUInt16())
            let encoding = Int32(bitPattern: try await readUInt32())
            rectangleCounts[encoding, default: 0] += 1
            switch Encoding(rawValue: encoding) {
            case .raw:
                let pixels = try await read(width * height * Framebuffer.bytesPerPixel)
                framebuffer.write(pixels, x: x, y: y, width: width, height: height)
            case .copyRect:
                let sourceX = Int(try await readUInt16())
                let sourceY = Int(try await readUInt16())
                framebuffer.copy(fromX: sourceX, fromY: sourceY, toX: x, toY: y, width: width, height: height)
            case .hextile:
                try await readHextile(x: x, y: y, width: width, height: height)
            case .tight:
                try await readTight(x: x, y: y, width: width, height: height)
            case .desktopSize:
                framebuffer.resize(width: width, height: height)
                continuation.yield(.resized(width: width, height: height))
            case .lastRect:
                break rects
            case .cursor:
                try await readCursor(hotspotX: x, hotspotY: y, width: width, height: height)
            case .qemuExtendedKeyEvent:
                supportsScancodes = true
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

    // MARK: - Encodings

    /// 16×16 tiles, each raw or a background with filled subrectangles.
    private func readHextile(x: Int, y: Int, width: Int, height: Int) async throws {
        let size = Framebuffer.bytesPerPixel
        var background: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        var foreground: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        for tileY in stride(from: y, to: y + height, by: 16) {
            for tileX in stride(from: x, to: x + width, by: 16) {
                let tileWidth = min(16, x + width - tileX)
                let tileHeight = min(16, y + height - tileY)
                let flags = try await read(1)[0]
                if flags & 1 != 0 {
                    framebuffer.write(try await read(tileWidth * tileHeight * size), x: tileX, y: tileY, width: tileWidth, height: tileHeight)
                    continue
                }
                if flags & 2 != 0 { background = Self.color(try await read(size)) }
                framebuffer.fill(x: tileX, y: tileY, width: tileWidth, height: tileHeight, color: background)
                if flags & 4 != 0 { foreground = Self.color(try await read(size)) }
                guard flags & 8 != 0 else { continue }
                let subrects = Int(try await read(1)[0])
                let coloured = flags & 16 != 0
                let data = try await read(subrects * (coloured ? size + 2 : 2))
                var index = 0
                for _ in 0..<subrects {
                    var color = foreground
                    if coloured {
                        color = Self.color(Array(data[index..<index + size]))
                        index += size
                    }
                    let position = data[index], dimensions = data[index + 1]
                    index += 2
                    framebuffer.fill(x: tileX + Int(position >> 4), y: tileY + Int(position & 15),
                                     width: Int(dimensions >> 4) + 1, height: Int(dimensions & 15) + 1, color: color)
                }
            }
        }
    }

    /// Tight: a solid fill, JPEG, or pixels that may be zlib-compressed and go through a palette or gradient filter.
    /// With this pixel format, a Tight pixel is three bytes: red, green, blue.
    private func readTight(x: Int, y: Int, width: Int, height: Int) async throws {
        let control = try await read(1)[0]
        tightCompressionCounts[control >> 4 >= 8 ? control >> 4 : 0, default: 0] += 1
        for stream in 0..<4 where control & (1 << stream) != 0 {
            tightStreams[stream].reset()
        }
        switch control >> 4 {
        case 8: // fill
            let rgb = try await read(3)
            framebuffer.fill(x: x, y: y, width: width, height: height, color: (rgb[2], rgb[1], rgb[0], 0))
        case 9: // JPEG
            let data = try await read(try await readCompactLength())
            framebuffer.write(try JPEGDecoder.bgrx(data, width: width, height: height), x: x, y: y, width: width, height: height)
        case let type where type & 8 == 0:
            let stream = Int(type & 3)
            let filter = type & 4 != 0 ? try await read(1)[0] : 0
            switch filter {
            case 0: // copy
                let rgb = try await readTightData(stream: stream, count: width * height * 3)
                framebuffer.write(Self.bgrx(fromRGB: rgb), x: x, y: y, width: width, height: height)
            case 1: // palette
                let colors = Int(try await read(1)[0]) + 1
                let palette = try await read(colors * 3)
                let rowBytes = colors == 2 ? (width + 7) / 8 : width
                let indices = try await readTightData(stream: stream, count: rowBytes * height)
                framebuffer.write(Self.bgrx(palette: palette, indices: indices, colors: colors, width: width, height: height), x: x, y: y, width: width, height: height)
            case 2: // gradient
                let data = try await readTightData(stream: stream, count: width * height * 3)
                framebuffer.write(Self.bgrx(fromRGB: Self.ungradient(data, width: width, height: height)), x: x, y: y, width: width, height: height)
            default:
                throw ProxmoxError.invalidResponse("unknown Tight filter \(filter)")
            }
        default:
            throw ProxmoxError.invalidResponse("unsupported Tight compression \(control >> 4)")
        }
    }

    /// Up to 11 bytes come uncompressed; more come as a length and zlib data of one of the four streams.
    private func readTightData(stream: Int, count: Int) async throws -> [UInt8] {
        if count < 12 { return try await read(count) }
        let compressed = try await read(try await readCompactLength())
        return try tightStreams[stream].inflate(compressed, count: count)
    }

    /// 1 to 3 bytes of 7 bits each, low bits first; the top bit says another byte follows.
    private func readCompactLength() async throws -> Int {
        var length = 0
        for shift in [0, 7, 14] {
            let byte = Int(try await read(1)[0])
            length |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 || shift == 14 { break }
        }
        return length
    }

    /// The pointer's image and a bit mask of its shape.
    private func readCursor(hotspotX: Int, hotspotY: Int, width: Int, height: Int) async throws {
        let size = Framebuffer.bytesPerPixel
        let colors = try await read(width * height * size)
        let maskRow = (width + 7) / 8
        let mask = try await read(maskRow * height)
        guard width > 0, height > 0 else { return }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width where mask[row * maskRow + column / 8] & (0x80 >> (column % 8)) != 0 {
                let index = (row * width + column) * 4
                pixels[index] = colors[index]
                pixels[index + 1] = colors[index + 1]
                pixels[index + 2] = colors[index + 2]
                pixels[index + 3] = 255
            }
        }
        continuation.yield(.cursor(VNCCursor(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY, pixels: pixels)))
    }

    static func color(_ bytes: [UInt8]) -> (UInt8, UInt8, UInt8, UInt8) {
        (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    static func bgrx(fromRGB rgb: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: rgb.count / 3 * 4)
        var source = 0, target = 0
        while source + 2 < rgb.count {
            output[target] = rgb[source + 2]
            output[target + 1] = rgb[source + 1]
            output[target + 2] = rgb[source]
            source += 3
            target += 4
        }
        return output
    }

    /// Two colours use one bit per pixel, rows padded to whole bytes; more use one byte per pixel.
    static func bgrx(palette: [UInt8], indices: [UInt8], colors: Int, width: Int, height: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height * 4)
        let rowBytes = colors == 2 ? (width + 7) / 8 : width
        for row in 0..<height {
            for column in 0..<width {
                let index = colors == 2
                    ? Int(indices[row * rowBytes + column / 8] >> (7 - UInt8(column % 8)) & 1)
                    : min(Int(indices[row * rowBytes + column]), colors - 1)
                let target = (row * width + column) * 4
                output[target] = palette[index * 3 + 2]
                output[target + 1] = palette[index * 3 + 1]
                output[target + 2] = palette[index * 3]
            }
        }
        return output
    }

    /// Undoes the gradient filter: each component was sent as the difference from left + above − above-left.
    static func ungradient(_ data: [UInt8], width: Int, height: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count)
        for row in 0..<height {
            for column in 0..<width {
                for component in 0..<3 {
                    let index = (row * width + column) * 3 + component
                    let left = column > 0 ? Int(output[index - 3]) : 0
                    let above = row > 0 ? Int(output[index - width * 3]) : 0
                    let aboveLeft = row > 0 && column > 0 ? Int(output[index - width * 3 - 3]) : 0
                    let prediction = max(0, min(255, left + above - aboveLeft))
                    output[index] = UInt8((Int(data[index]) + prediction) & 0xFF)
                }
            }
        }
        return output
    }

    // MARK: - Reading

    /// Reads exactly `count` bytes, pulling WebSocket messages as needed.
    private func read(_ count: Int) async throws -> [UInt8] {
        while buffer.count - offset < count {
            if offset > 0 && offset == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                offset = 0
            }
            let received = try await socket.receive().bytes
            receivedBytes += received.count
            buffer += received
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
