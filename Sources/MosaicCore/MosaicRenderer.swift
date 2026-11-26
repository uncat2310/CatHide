import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MosaicRenderError: LocalizedError {
    case invalidImageFile
    case failedToEncodeImage

    public var errorDescription: String? {
        switch self {
        case .invalidImageFile:
            "无法读取该图片文件，请确认文件未损坏且为常见图片格式。"
        case .failedToEncodeImage:
            "无法导出处理后的图片。"
        }
    }
}

private final class SendableCIContext: @unchecked Sendable {
    let context: CIContext

    init() {
        self.context = CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .outputColorSpace: CGColorSpaceCreateDeviceRGB()
        ])
    }
}

public enum MosaicRenderer {
    private static let sharedCIContext = SendableCIContext()

    private static var ciContext: CIContext {
        sharedCIContext.context
    }

    private static var srgbColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func makeRGBAContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: srgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    public static func loadOrientedImage(from url: URL) throws -> CGImage {
        guard let ciImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              let rendered = renderNormalizedCGImage(from: ciImage) else {
            throw MosaicRenderError.invalidImageFile
        }
        return rendered
    }

    public static func loadOrientedImage(from data: Data) -> CGImage? {
        guard let ciImage = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        return renderNormalizedCGImage(from: ciImage)
    }

    private static func renderNormalizedCGImage(from ciImage: CIImage) -> CGImage? {
        let extent = ciImage.extent.integral
        guard !extent.isEmpty, extent.width > 0, extent.height > 0 else {
            return nil
        }
        return ciContext.createCGImage(ciImage, from: extent, format: .RGBA8, colorSpace: srgbColorSpace)
    }

    public static func normalizeImage(_ nsImage: NSImage) -> CGImage? {
        var sourceCGImage: CGImage?

        if let bestRep = nsImage.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) }),
           let repCG = bestRep.cgImage {
            sourceCGImage = repCG
        } else if let directCG = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            sourceCGImage = directCG
        }

        if let cgImage = sourceCGImage {
            let width = cgImage.width
            let height = cgImage.height
            guard let ctx = makeRGBAContext(width: width, height: height) else {
                return cgImage
            }
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage() ?? cgImage
        }

        let width = max(1, Int(nsImage.size.width.rounded()))
        let height = max(1, Int(nsImage.size.height.rounded()))
        guard let ctx = makeRGBAContext(width: width, height: height) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        nsImage.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    public static func makePreviewImage(from image: CGImage, maxDimension: CGFloat = 2048) -> (image: CGImage, scale: CGFloat) {
        let maxSide = max(image.width, image.height)
        guard maxSide > Int(maxDimension), maxDimension > 0 else {
            return (image, 1.0)
        }
        let scale = maxDimension / CGFloat(maxSide)
        let targetWidth = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard let ctx = makeRGBAContext(width: targetWidth, height: targetHeight) else {
            return (image, 1.0)
        }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = ctx.makeImage() else {
            return (image, 1.0)
        }
        return (scaled, CGFloat(targetWidth) / CGFloat(image.width))
    }

    public static func makeMosaicImage(from image: CGImage, blockSize: CGFloat) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        let extent = ciImage.extent
        guard !extent.isEmpty else { return nil }

        guard let filter = CIFilter(name: "CIPixellate") else {
            return nil
        }
        filter.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(2.0, blockSize), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)

        guard let output = filter.outputImage?.cropped(to: extent) else {
            return nil
        }
        return ciContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: srgbColorSpace)
    }

    public static func makeBlurImage(from image: CGImage, radius: CGFloat) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        let extent = ciImage.extent
        guard !extent.isEmpty else { return nil }

        guard let filter = CIFilter(name: "CIGaussianBlur") else {
            return nil
        }
        filter.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(1.5, radius), forKey: kCIInputRadiusKey)

        guard let output = filter.outputImage?.cropped(to: extent) else {
            return nil
        }
        return ciContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: srgbColorSpace)
    }

    public static func makeSolidImage(width: Int, height: Int, granularity: MosaicGranularity) -> CGImage? {
        guard let ctx = makeRGBAContext(width: width, height: height) else {
            return nil
        }
        let grayValue: CGFloat = switch granularity {
        case .fine: 0.08
        case .medium: 0.52
        case .coarse: 0.94
        }
        ctx.setFillColor(CGColor(red: grayValue, green: grayValue, blue: grayValue, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    public static func makeEffectImage(
        from image: CGImage,
        style: MosaicEffectStyle,
        granularity: MosaicGranularity,
        originalWidth: Int,
        originalHeight: Int,
        previewScale: CGFloat = 1.0
    ) -> CGImage? {
        switch style {
        case .mosaic:
            let blockSize = granularity.blockSize(forPixelDimensions: originalWidth, height: originalHeight)
            return makeMosaicImage(from: image, blockSize: max(2.0, blockSize * previewScale))
        case .blur:
            let radius = granularity.blurRadius(forPixelDimensions: originalWidth, height: originalHeight)
            return makeBlurImage(from: image, radius: max(1.5, radius * previewScale))
        case .solid:
            return makeSolidImage(width: image.width, height: image.height, granularity: granularity)
        }
    }

    public static func rotateImage(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }

        let srcW = image.width
        let srcH = image.height
        let dstW = turns.isMultiple(of: 2) ? srcW : srcH
        let dstH = turns.isMultiple(of: 2) ? srcH : srcW

        guard let ctx = makeRGBAContext(width: dstW, height: dstH) else {
            return image
        }
        ctx.clear(CGRect(x: 0, y: 0, width: dstW, height: dstH))
        ctx.translateBy(x: CGFloat(dstW) * 0.5, y: CGFloat(dstH) * 0.5)
        ctx.rotate(by: -CGFloat(turns) * (.pi * 0.5))
        ctx.draw(
            image,
            in: CGRect(x: -CGFloat(srcW) * 0.5, y: -CGFloat(srcH) * 0.5, width: CGFloat(srcW), height: CGFloat(srcH))
        )
        return ctx.makeImage() ?? image
    }

    public static func cropImage(_ image: CGImage, normalizedCrop: NormalizedCropRect) -> CGImage {
        guard !normalizedCrop.isFull else { return image }
        let cropRect = normalizedCrop.cgImageCroppingRect(width: image.width, height: image.height)
        return image.cropping(to: cropRect) ?? image
    }

    public static func makeMaskContext(width: Int, height: Int) -> CGContext? {
        guard let ctx = makeRGBAContext(width: width, height: height) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    private static func configureStrokeStyle(
        tool: MosaicTool,
        diameter: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) -> CGFloat {
        let scaledDiameter = max(1, diameter * scale)
        switch tool {
        case .mosaic, .rectangle:
            context.setBlendMode(.normal)
            let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.setStrokeColor(white)
            context.setFillColor(white)
        case .eraser:
            context.setBlendMode(.clear)
            let clear = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
            context.setStrokeColor(clear)
            context.setFillColor(clear)
        }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(scaledDiameter)
        return scaledDiameter
    }

    public static func drawSegment(
        from p0: CGPoint,
        to p1: CGPoint,
        tool: MosaicTool,
        diameter: CGFloat,
        into context: CGContext,
        scale: CGFloat
    ) {
        let a = CGPoint(x: p0.x * scale, y: p0.y * scale)
        let b = CGPoint(x: p1.x * scale, y: p1.y * scale)

        context.saveGState()
        let scaledDiameter = configureStrokeStyle(tool: tool, diameter: diameter, scale: scale, in: context)

        if hypot(b.x - a.x, b.y - a.y) < 0.01 {
            let radius = scaledDiameter / 2.0
            context.fillEllipse(in: CGRect(
                x: a.x - radius,
                y: a.y - radius,
                width: scaledDiameter,
                height: scaledDiameter
            ))
        } else {
            context.beginPath()
            context.move(to: a)
            context.addLine(to: b)
            context.strokePath()
        }
        context.restoreGState()
    }

    public static func drawStroke(_ stroke: MosaicStroke, into context: CGContext, scale: CGFloat) {
        if let rect = stroke.rect {
            context.saveGState()
            context.setBlendMode(stroke.tool == .eraser ? .clear : .normal)
            let fillColor = stroke.tool == .eraser
                ? CGColor(red: 0, green: 0, blue: 0, alpha: 0)
                : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.setFillColor(fillColor)
            context.fill(CGRect(
                x: rect.minX * scale,
                y: rect.minY * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ))
            context.restoreGState()
            return
        }

        guard let first = stroke.points.first else { return }

        if stroke.points.count == 1 {
            drawSegment(
                from: first,
                to: first,
                tool: stroke.tool,
                diameter: stroke.diameter,
                into: context,
                scale: scale
            )
            return
        }

        context.saveGState()
        _ = configureStrokeStyle(tool: stroke.tool, diameter: stroke.diameter, scale: scale, in: context)

        context.beginPath()
        context.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
        for point in stroke.points.dropFirst() {
            context.addLine(to: CGPoint(x: point.x * scale, y: point.y * scale))
        }
        context.strokePath()
        context.restoreGState()
    }

    public static func composite(original: CGImage, mosaic: CGImage, mask: CGImage) -> CGImage? {
        let width = original.width
        let height = original.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        guard let ctx = makeRGBAContext(width: width, height: height) else {
            return nil
        }
        ctx.clear(rect)
        ctx.draw(original, in: rect)

        ctx.saveGState()
        ctx.clip(to: rect, mask: mask)
        ctx.draw(mosaic, in: rect)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    public static func renderFinalImage(
        original: CGImage,
        strokes: [MosaicStroke],
        granularity: MosaicGranularity,
        style: MosaicEffectStyle = .mosaic,
        cropRect: NormalizedCropRect = .full
    ) -> CGImage? {
        let maskedImage: CGImage
        if strokes.isEmpty {
            maskedImage = original
        } else {
            guard let effectLayer = makeEffectImage(
                from: original,
                style: style,
                granularity: granularity,
                originalWidth: original.width,
                originalHeight: original.height
            ),
            let maskContext = makeMaskContext(width: original.width, height: original.height) else {
                return nil
            }

            for stroke in strokes {
                drawStroke(stroke, into: maskContext, scale: 1.0)
            }

            guard let maskImage = maskContext.makeImage(),
                  let composited = composite(original: original, mosaic: effectLayer, mask: maskImage) else {
                return nil
            }
            maskedImage = composited
        }

        return cropImage(maskedImage, normalizedCrop: cropRect)
    }

    public static func encodeImage(
        _ image: CGImage,
        format: ExportFormat,
        jpegQuality: CGFloat = 0.92,
        stripMetadata: Bool = true,
        sourceMetadataURL: URL? = nil
    ) -> Data? {
        let data = NSMutableData()
        let utType: UTType = switch format {
        case .png: .png
        case .jpeg: .jpeg
        }

        guard let destination = CGImageDestinationCreateWithData(data, utType.identifier as CFString, 1, nil) else {
            return nil
        }

        var options: [CFString: Any] = [:]
        if format == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }

        if !stripMetadata,
           let sourceMetadataURL,
           let source = CGImageSourceCreateWithURL(sourceMetadataURL as CFURL, nil),
           let rawProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            var filtered = rawProps
            filtered[kCGImagePropertyOrientation] = 1
            filtered.removeValue(forKey: kCGImagePropertyPixelWidth)
            filtered.removeValue(forKey: kCGImagePropertyPixelHeight)
            for (key, value) in filtered {
                options[key] = value
            }
        }

        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    public static func collectImageURLs(from urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var seenPaths = Set<String>()
        var collected: [URL] = []

        func isImageFile(_ url: URL) -> Bool {
            if let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey]),
               values.isRegularFile == true,
               let type = values.contentType {
                return type.conforms(to: .image)
            }
            if let extType = UTType(filenameExtension: url.pathExtension) {
                return extType.conforms(to: .image)
            }
            return false
        }

        func appendIfImage(_ url: URL) {
            let normalized = url.standardizedFileURL
            guard isImageFile(normalized) else { return }
            if seenPaths.insert(normalized.path).inserted {
                collected.append(normalized)
            }
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let children = (try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey, .isHiddenKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )) ?? []
                for child in children {
                    appendIfImage(child)
                }
            } else {
                appendIfImage(url)
            }
        }

        return collected.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    public static func makeThumbnail(from url: URL, maxPixelSize: Int = 140) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public static func makeThumbnail(from image: CGImage, maxPixelSize: Int = 140) -> CGImage? {
        makePreviewImage(from: image, maxDimension: CGFloat(max(32, maxPixelSize))).image
    }

    public static func resolvedImageFileName(
        suggestedName: String?,
        fileURL: URL? = nil,
        preferredExtension: String = "png"
    ) -> String {
        let trimmedExt = preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fallbackExt = trimmedExt.isEmpty ? "png" : trimmedExt

        if let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            let existingExt = (suggested as NSString).pathExtension
            if !existingExt.isEmpty {
                return suggested
            }
            if let urlExt = fileURL?.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines),
               !urlExt.isEmpty {
                return "\(suggested).\(urlExt.lowercased())"
            }
            return "\(suggested).\(fallbackExt)"
        }

        if let urlName = fileURL?.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines),
           !urlName.isEmpty {
            if (urlName as NSString).pathExtension.isEmpty {
                return "\(urlName).\(fallbackExt)"
            }
            return urlName
        }

        return "未命名.\(fallbackExt)"
    }
}
