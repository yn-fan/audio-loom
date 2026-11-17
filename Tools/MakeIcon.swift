import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.setFillColor(CGColor(red: 0.065, green: 0.09, blue: 0.1, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 55, y: 55, width: 914, height: 914),
                              cornerWidth: 210, cornerHeight: 210, transform: nil))
        context.fillPath()
        context.setStrokeColor(CGColor(red: 0.59, green: 0.91, blue: 0.75, alpha: 1))
        context.setLineCap(.round)
        context.setLineWidth(48)
        let heights: [CGFloat] = [95, 205, 350, 480, 320, 190, 100]
        for (index, height) in heights.enumerated() {
            let x = CGFloat(248 + index * 88)
            context.move(to: CGPoint(x: x, y: 512 - height / 2))
            context.addLine(to: CGPoint(x: x, y: 512 + height / 2))
            context.strokePath()
        }
        context.setFillColor(CGColor(red: 1, green: 0.68, blue: 0.58, alpha: 1))
        context.fillEllipse(in: CGRect(x: 752, y: 727, width: 72, height: 72))
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Could not write icon.") }
    }
}
