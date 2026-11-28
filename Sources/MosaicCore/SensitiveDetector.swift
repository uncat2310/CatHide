import CoreGraphics
import CoreText
import Foundation
import NaturalLanguage
import Vision

/// What 自动识别 found, for the user to confirm. `rect`: original image pixels with the origin
/// at the BOTTOM-left (the same space as strokes).
public struct PrivacySuggestion: Identifiable, Sendable, Equatable {
    public let id: Int
    public let kind: PrivacyKind
    /// What was read there (shown as the box's tooltip).
    public let text: String
    public let rect: CGRect

    public init(id: Int, kind: PrivacyKind, text: String, rect: CGRect) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rect = rect
    }

    /// Rectangle stroke covering the suggestion (`rect` already includes the margin).
    public func stroke(imageWidth: Int, imageHeight: Int, style: MosaicEffectStyle, granularity: MosaicGranularity, group: Int) -> MosaicStroke {
        MosaicStroke(
            tool: .rectangle,
            rect: rect.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)),
            effectStyle: style,
            granularity: granularity,
            group: group
        )
    }
}

public enum SensitiveDetector {
    private static let warmUpOnce = WarmUp()

    private final class WarmUp: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        func run() {
            let first: Bool = lock.withLock {
                defer { started = true }
                return !started
            }
            guard first else { return }
            Task.detached(priority: .utility) {
                _ = try? SensitiveDetector.detect(in: SensitiveDetector.warmUpImage())
            }
        }
    }

    /// Vision loads its Chinese text model on first use, which takes several seconds. Doing that in
    /// the background as soon as a file is opened makes the first 自动识别 as quick as the rest.
    public static func warmUp() {
        warmUpOnce.run()
    }

    static func warmUpImage() -> CGImage {
        let w = 360, h = 80
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("PingFang SC" as CFString, 30, nil)
        let text = NSAttributedString(string: "电话 Test 123", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: 16, y: 26)
        CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        return ctx.makeImage()!
    }

    /// Reads the image with Vision (text in Chinese + English, QR codes and barcodes) and returns
    /// what looks sensitive, in reading order.
    public static func detect(in image: CGImage) throws -> [PrivacySuggestion] {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        var lines: [RecognizedTextLine] = []
        var codes: [SensitiveFinding] = []

        // Long screenshots and tall pages: Vision works on a scaled-down copy, so read them in
        // overlapping tiles about 1.5× as tall as wide (dedupe drops the repeats).
        for tile in tiles(width: w, height: h) {
            guard let cropped = image.cropping(to: tile) else { continue }
            let (tileLines, tileCodes) = try recognize(cropped)
            // Tile rects are top-left based; tile.origin is in CGImage (top-left) space too.
            for line in tileLines {
                lines.append(RecognizedTextLine(
                    text: line.text,
                    glyphs: line.glyphs.map { $0?.offsetBy(dx: tile.minX, dy: tile.minY) }
                ))
            }
            codes += tileCodes.map {
                SensitiveFinding(kind: .code, text: $0.text, rect: $0.rect.offsetBy(dx: tile.minX, dy: tile.minY))
            }
        }

        var found = SensitiveRules.findings(in: lines)
        found += personalNames(in: lines, excluding: found)
        found += codes
        let kept = SensitiveRules.dedupe(found)
        let boxes = paddedBoxes(kept, imageSize: CGSize(width: w, height: h))
        return kept.enumerated().map { idx, f in
            // Flip to the bottom-left origin used by strokes.
            let r = boxes[idx]
            return PrivacySuggestion(
                id: idx,
                kind: f.kind,
                text: f.text,
                rect: CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
            )
        }
    }

    /// Each finding with a small margin, so the mask covers the letters completely. Where lines sit
    /// close together, neighbouring boxes meet halfway between the lines instead of overlapping.
    static func paddedBoxes(_ found: [SensitiveFinding], imageSize: CGSize) -> [CGRect] {
        let bounds = CGRect(origin: .zero, size: imageSize)
        var boxes = found.map { f -> CGRect in
            let pad = f.kind == .code ? 2 : max(2, f.rect.height * 0.15)
            return f.rect.insetBy(dx: -pad, dy: -pad).intersection(bounds)
        }
        for i in boxes.indices {
            for j in boxes.indices where i != j {
                let a = found[i].rect
                let b = found[j].rect
                // Only a box above another one (top-left origin: smaller y is higher up).
                guard a.midY < b.midY,
                      min(boxes[i].maxX, boxes[j].maxX) > max(boxes[i].minX, boxes[j].minX),
                      boxes[i].maxY > boxes[j].minY,
                      b.midY - a.midY > min(a.height, b.height) * 0.5 else { continue }
                let cut = (a.maxY + b.minY) / 2
                boxes[i].size.height = max(1, min(boxes[i].maxY, cut - 1) - boxes[i].minY)
                let newMinY = max(boxes[j].minY, cut + 1)
                boxes[j] = CGRect(x: boxes[j].minX, y: newMinY, width: boxes[j].width, height: max(1, boxes[j].maxY - newMinY))
            }
        }
        return boxes
    }

    static func tiles(width w: CGFloat, height h: CGFloat) -> [CGRect] {
        func spans(_ long: CGFloat, _ short: CGFloat) -> [(CGFloat, CGFloat)] {
            let size = (short * 1.5).rounded()
            guard long > size * 1.2 else { return [(0, long)] }
            let step = (size * 0.85).rounded()
            var out: [(CGFloat, CGFloat)] = []
            var start: CGFloat = 0
            while true {
                let end = min(long, start + size)
                out.append((max(0, end - size), end))
                if end >= long { break }
                start += step
            }
            return out
        }
        if h >= w {
            return spans(h, w).map { CGRect(x: 0, y: $0.0, width: w, height: $0.1 - $0.0) }
        }
        return spans(w, h).map { CGRect(x: $0.0, y: 0, width: $0.1 - $0.0, height: h) }
    }

    private static func recognize(_ image: CGImage) throws -> ([RecognizedTextLine], [SensitiveFinding]) {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        /// Vision's normalised, bottom-left rect → pixels, top-left origin.
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
        }

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.recognitionLanguages = ["zh-Hans", "en-US"]
        // Correction "fixes" numbers and ids into words; the rules want what is printed.
        text.usesLanguageCorrection = false
        // Small print on large pages (the default skips text under ~1/32 of the height).
        text.minimumTextHeight = 0.006
        text.revision = VNRecognizeTextRequestRevision3

        let barcodes = VNDetectBarcodesRequest()

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([text, barcodes])

        var lines: [RecognizedTextLine] = []
        for obs in text.results ?? [] {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let s = candidate.string
            let lineBox = px(obs.boundingBox)
            lines.append(RecognizedTextLine(text: s, glyphs: glyphBoxes(s, lineBox: lineBox) { range in
                (try? candidate.boundingBox(for: range)).map { px($0.boundingBox) }
            }))
        }

        let codes = (barcodes.results ?? []).map { obs in
            SensitiveFinding(kind: .code, text: obs.symbology == .qr ? "二维码" : "条形码", rect: px(obs.boundingBox))
        }
        return (lines, codes)
    }

    /// A box for every UTF-16 unit. Vision often gives a whole word (or, for Chinese, a whole run)
    /// the same box; such runs are split evenly between their characters, as on Windows.
    static func glyphBoxes(_ s: String, lineBox: CGRect, box: (Range<String.Index>) -> CGRect?) -> [CGRect?] {
        var perChar: [(range: Range<String.Index>, rect: CGRect?)] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(after: idx)
            let ch = s[idx]
            let r: CGRect? = ch.isWhitespace ? nil : (box(idx..<next) ?? nil)
            perChar.append((idx..<next, r.flatMap { $0.isNull || $0.width <= 0 ? nil : $0 }))
            idx = next
        }
        // Group runs of (nearly) identical boxes and split them evenly.
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 1 && abs(a.maxX - b.maxX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.maxY - b.maxY) < 1
        }
        var resolved = [CGRect?](repeating: nil, count: perChar.count)
        var i = 0
        while i < perChar.count {
            guard let r = perChar[i].rect else { i += 1; continue }
            var j = i + 1
            while j < perChar.count, let rj = perChar[j].rect, same(r, rj) { j += 1 }
            let n = CGFloat(j - i)
            for k in i..<j {
                let f = CGFloat(k - i)
                resolved[k] = CGRect(x: r.minX + r.width * f / n, y: r.minY, width: r.width / n, height: r.height)
            }
            i = j
        }
        // Characters Vision gave no box: proportional slice of the line.
        let total = max(1, perChar.count)
        var out: [CGRect?] = []
        out.reserveCapacity((s as NSString).length)
        for (k, item) in perChar.enumerated() {
            let units = s[item.range].utf16.count
            var r = resolved[k]
            if r == nil, !s[item.range].allSatisfy(\.isWhitespace) {
                r = CGRect(
                    x: lineBox.minX + lineBox.width * CGFloat(k) / CGFloat(total),
                    y: lineBox.minY,
                    width: lineBox.width / CGFloat(total),
                    height: lineBox.height
                )
            }
            out.append(r)
            for _ in 1..<max(1, units) { out.append(nil) }
        }
        return out
    }

    /// People's names in running text that no label points at, from Apple's NaturalLanguage tagger.
    private static func personalNames(in lines: [RecognizedTextLine], excluding found: [SensitiveFinding]) -> [SensitiveFinding] {
        var out: [SensitiveFinding] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        for line in lines {
            let text = line.text
            guard (text as NSString).length >= 2 else { continue }
            tagger.string = text
            tagger.enumerateTags(
                in: text.startIndex..<text.endIndex,
                unit: .word,
                scheme: .nameType,
                options: [.omitWhitespace, .omitPunctuation, .joinNames]
            ) { tag, range in
                guard tag == .personalName else { return true }
                let name = String(text[range])
                let isCJK = name.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }
                // The tagger guesses freely in Chinese running text ("签字笔"); keep only what has
                // the shape of a name: a common surname + one or two characters, or two+ Latin words.
                guard !SensitiveRules.notNames.contains(name),
                      isCJK ? SensitiveRules.looksLikeChineseName(name) : name.contains(" ") && name.count <= 40
                else { return true }
                let ns = NSRange(range, in: text)
                guard let rect = SensitiveRules.union(line.glyphs, ns.location, ns.location + ns.length) else { return true }
                if !found.contains(where: { !$0.rect.intersection(rect).isNull }) {
                    out.append(SensitiveFinding(kind: .name, text: name, rect: rect))
                }
                return true
            }
        }
        return out
    }
}
