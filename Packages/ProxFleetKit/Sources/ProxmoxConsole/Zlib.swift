import CZlib
import Foundation
import ProxmoxCore

/// A zlib stream that keeps its dictionary between rectangles, as VNC's Tight and ZRLE encodings require.
final class ZlibInflater {
    private var stream = z_stream()
    private var isOpen = false

    deinit {
        if isOpen { inflateEnd(&stream) }
    }

    /// Starts over, when the server says it reset the stream.
    func reset() {
        if isOpen { inflateEnd(&stream) }
        isOpen = false
    }

    /// Inflates the bytes of one rectangle, which the server flushed so that exactly `count` bytes come out.
    func inflate(_ input: [UInt8], count: Int) throws -> [UInt8] {
        if !isOpen {
            stream = z_stream()
            guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw ProxmoxError.invalidResponse("cannot start a zlib stream")
            }
            isOpen = true
        }
        var output = [UInt8](repeating: 0, count: count)
        guard count > 0 else { return output }
        var input = input
        let status: Int32 = input.withUnsafeMutableBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                stream.next_in = inputBuffer.baseAddress
                stream.avail_in = UInt32(inputBuffer.count)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = UInt32(outputBuffer.count)
                var status = Z_OK
                while stream.avail_out > 0 {
                    status = CZlib.inflate(&stream, Z_SYNC_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END else { break }
                    if stream.avail_in == 0 || status == Z_STREAM_END { break }
                }
                return status
            }
        }
        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR, stream.avail_out == 0 else {
            throw ProxmoxError.invalidResponse("corrupt zlib data in a VNC update (\(status))")
        }
        return output
    }
}
