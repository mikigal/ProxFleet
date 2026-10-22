// Keeps the top-left width x height pixels of a PNG and, given an output size, scales them to it:
//   swift crop.swift <in> <out> <width> <height> [<output width> <output height>]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 5 || args.count == 7, let width = Int(args[3]), let height = Int(args[4]),
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      var result = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write("usage: swift crop.swift <in> <out> <width> <height> [<output width> <output height>]\n".data(using: .utf8)!)
    exit(1)
}
if args.count == 7, let outputWidth = Int(args[5]), let outputHeight = Int(args[6]) {
    // Without an alpha channel, so the App Store accepts the screenshot.
    guard let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: result.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { exit(1) }
    context.interpolationQuality = .high
    context.draw(result, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
    guard let scaled = context.makeImage() else { exit(1) }
    result = scaled
}
CGImageDestinationAddImage(destination, result, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
