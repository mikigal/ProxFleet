// Keeps the top-left width x height pixels of a PNG: swift crop.swift <in> <out> <width> <height>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 5, let width = Int(args[3]), let height = Int(args[4]),
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write("usage: swift crop.swift <in> <out> <width> <height>\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(destination, cropped, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
