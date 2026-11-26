import AppKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let outputDir = args.first ?? "AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: outputDir)
try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let scriptURL = URL(fileURLWithPath: #filePath)
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let defaultSourcePath = projectRoot.appendingPathComponent("Resources/AppIconSource.png").path
let sourceImagePath = args.count > 1 ? args[1] : defaultSourcePath

guard let sourceImage = NSImage(contentsOfFile: sourceImagePath),
      let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Error: failed to load icon artwork at \(sourceImagePath)\n", stderr)
    exit(1)
}

func renderIcon(pixelSize: Int, artwork: CGImage) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixelSize)
    let margin = s * 0.08
    let bodyRect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let cornerRadius = bodyRect.width * 0.225

    // Standard macOS Dock squircle shadow
    let outerShadow = NSShadow()
    outerShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    outerShadow.shadowBlurRadius = s * 0.04
    outerShadow.shadowOffset = NSSize(width: 0, height: -s * 0.014)

    let bgPath = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSGraphicsContext.saveGraphicsState()
    outerShadow.set()
    NSColor.white.setFill()
    bgPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Clip to macOS squircle and draw artwork aspect-filled cleanly
    NSGraphicsContext.saveGraphicsState()
    bgPath.addClip()

    let imgW = CGFloat(artwork.width)
    let imgH = CGFloat(artwork.height)
    let scale = max(bodyRect.width / imgW, bodyRect.height / imgH)
    let drawW = imgW * scale
    let drawH = imgH * scale
    let drawRect = CGRect(
        x: bodyRect.midX - drawW / 2.0,
        y: bodyRect.midY - drawH / 2.0,
        width: drawW,
        height: drawH
    )

    if let cgContext = NSGraphicsContext.current?.cgContext {
        cgContext.interpolationQuality = .high
        cgContext.draw(artwork, in: drawRect)
    }

    NSGraphicsContext.restoreGraphicsState()

    // Subtle hairline inner edge for light/dark wallpaper contrast
    NSColor.black.withAlphaComponent(0.07).setStroke()
    let borderPath = NSBezierPath(
        roundedRect: bodyRect.insetBy(dx: max(0.5, s * 0.003), dy: max(0.5, s * 0.003)),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    )
    borderPath.lineWidth = max(1, s * 0.008)
    borderPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in specs {
    let rep = renderIcon(pixelSize: size, artwork: sourceCGImage)
    let data = rep.representation(using: .png, properties: [:])!
    let path = (outputDir as NSString).appendingPathComponent(filename)
    try data.write(to: URL(fileURLWithPath: path))
}
print("Generated iconset at \(outputDir) from \(sourceImagePath)")
