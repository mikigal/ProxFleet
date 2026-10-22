import Foundation
import ProxmoxCore
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Decodes the JPEG rectangles of the Tight encoding into the framebuffer's pixel layout.
enum JPEGDecoder {
    /// B, G, R, X bytes, `width × height` pixels.
    static func bgrx(_ data: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(Data(data) as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProxmoxError.invalidResponse("corrupt JPEG in a VNC update")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ProxmoxError.invalidResponse("cannot draw a JPEG from a VNC update") }
        return pixels
        #else
        throw ProxmoxError.invalidResponse("JPEG is not supported on this platform")
        #endif
    }
}
