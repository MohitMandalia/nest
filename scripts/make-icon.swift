import AppKit
import Foundation

// Package the generated transparent brand artwork into standard macOS icon sizes.
// The source PNG stays unchanged; this adds the app-icon tile and downsamples it.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let artwork = root.appendingPathComponent("Sources/Nest/Resources/NestLogo.png")
guard let logo = NSImage(contentsOf: artwork) else { fatalError("Missing Nest logo: \(artwork.path)") }
let iconset = root.appendingPathComponent(".build/Nest.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon bitmap") }
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        graphics.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 38, y: 38, width: 948, height: 948), xRadius: 215, yRadius: 215)
        NSColor(calibratedRed: 1, green: 0.98, blue: 0.94, alpha: 1).setFill()
        tile.fill()
        NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.31, alpha: 0.10).setStroke()
        tile.lineWidth = 1
        tile.stroke()
        logo.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        if pixels == 1024 {
            try png.write(to: root.appendingPathComponent("Resources/Brand/NestIcon-1024.png"))
        }
    }
}
