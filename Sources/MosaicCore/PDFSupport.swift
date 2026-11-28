import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum PDFOpenError: LocalizedError {
    case unreadable(String)
    case empty(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "无法打开 PDF「\(name)」，文件可能已损坏。"
        case .empty(let name): "PDF「\(name)」没有任何页面。"
        }
    }
}

/// Open PDFs (unlocked), shared by the editor, the preloader and export. PDFKit is not
/// thread-safe, so every page access goes through one lock.
public final class PDFDocumentStore: @unchecked Sendable {
    public static let shared = PDFDocumentStore()

    private let lock = NSLock()
    private var documents: [UUID: PDFDocument] = [:]

    /// Pages are rendered at about 200 dpi, capped so huge pages stay manageable.
    public static let renderDPI: CGFloat = 200
    public static let maxRenderPixels: CGFloat = 3200

    public func register(_ document: PDFDocument) -> UUID {
        let id = UUID()
        lock.withLock { documents[id] = document }
        return id
    }

    public func remove(_ id: UUID) {
        lock.withLock { _ = documents.removeValue(forKey: id) }
    }

    /// Keep only the documents still in the list.
    public func retain(only ids: Set<UUID>) {
        lock.withLock { documents = documents.filter { ids.contains($0.key) } }
    }

    /// Page size in points as shown (crop box, rotation applied).
    public static func displaySize(of page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    /// Pixel size a page renders at. Export uses the same size, so strokes line up.
    public static func pixelSize(forPageSize size: CGSize) -> (width: Int, height: Int) {
        let longest = max(1, max(size.width, size.height))
        let scale = min(renderDPI / 72, maxRenderPixels / longest)
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    /// The page as an opaque image (white paper).
    public func renderPage(documentID: UUID, index: Int) -> CGImage? {
        lock.withLock {
            guard let doc = documents[documentID], let page = doc.page(at: index) else { return nil }
            let size = Self.displaySize(of: page)
            let (pw, ph) = Self.pixelSize(forPageSize: size)
            guard let ctx = CGContext(
                data: nil,
                width: pw,
                height: ph,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: CGFloat(pw) / size.width, y: CGFloat(ph) / size.height)
            // PDFKit moves the crop box to the origin and applies the page's rotation itself.
            page.draw(with: .cropBox, to: ctx)
            return ctx.makeImage()
        }
    }

    public func thumbnail(documentID: UUID, index: Int, maxPixelSize: CGFloat = 140) -> CGImage? {
        lock.withLock {
            guard let doc = documents[documentID], let page = doc.page(at: index) else { return nil }
            let image = page.thumbnail(of: NSSize(width: maxPixelSize, height: maxPixelSize), for: .cropBox)
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
    }
}

public enum PDFSupport {
    public static func isPDF(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf)
        }
        return url.pathExtension.lowercased() == "pdf"
    }

    /// Opens a PDF and turns its pages into list items. `askPassword(fileName, wrongBefore)`
    /// returns nil when the user cancels; then the file is skipped (nil result, no error).
    @MainActor
    public static func openPages(
        url: URL,
        granularity: MosaicGranularity,
        effectStyle: MosaicEffectStyle,
        askPassword: (String, Bool) -> String?
    ) throws -> [MosaicQueueItem]? {
        let name = url.lastPathComponent
        guard let doc = PDFDocument(url: url) else { throw PDFOpenError.unreadable(name) }
        if doc.isLocked {
            var wrong = false
            while doc.isLocked {
                guard let password = askPassword(name, wrong) else { return nil }
                if !doc.unlock(withPassword: password) { wrong = true }
            }
        }
        guard doc.pageCount > 0 else { throw PDFOpenError.empty(name) }
        let id = PDFDocumentStore.shared.register(doc)
        return (0..<doc.pageCount).compactMap { index in
            guard let page = doc.page(at: index) else { return nil }
            return MosaicQueueItem(
                sourceURL: url,
                fileName: name,
                granularity: granularity,
                effectStyle: effectStyle,
                pdfPage: PDFPageRef(
                    documentID: id,
                    url: url,
                    pageIndex: index,
                    pageCount: doc.pageCount,
                    pageSize: PDFDocumentStore.displaySize(of: page)
                )
            )
        }
    }

    /// Writes pages that are only pictures, each at its original size in points. Nothing of the
    /// original text survives, so masked words cannot be selected or searched for.
    public static func writeImagePDF(pages: [(image: CGImage, size: CGSize)], to url: URL, jpegQuality: CGFloat = 0.9) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).pdf")
        var firstBox = CGRect(origin: .zero, size: pages.first?.size ?? CGSize(width: 595, height: 842))
        let info: [CFString: Any] = [kCGPDFContextCreator: "猫猫藏藏 CatHide"]
        guard let ctx = CGContext(temp as CFURL, mediaBox: &firstBox, info as CFDictionary) else {
            throw MosaicRenderError.failedToEncodeImage
        }
        for page in pages {
            var box = CGRect(origin: .zero, size: page.size)
            ctx.beginPage(mediaBox: &box)
            // JPEG data is embedded as is (DCT), which keeps scans and photos small.
            let embedded = jpegImage(page.image, quality: jpegQuality) ?? page.image
            ctx.interpolationQuality = .high
            ctx.draw(embedded, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }

    private static func jpegImage(_ image: CGImage, quality: CGFloat) -> CGImage? {
        guard let data = MosaicRenderer.encodeImage(image, format: .jpeg, jpegQuality: quality, stripMetadata: true),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
