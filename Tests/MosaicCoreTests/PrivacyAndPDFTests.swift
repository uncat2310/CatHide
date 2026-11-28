import AppKit
import CoreGraphics
import CoreText
@testable import MosaicCore
import PDFKit
import XCTest

final class SensitiveRulesTests: XCTestCase {
    /// A line whose characters sit 10px apart (top-left origin), spaces without a box.
    private func line(_ text: String, y: CGFloat = 0, x: CGFloat = 0) -> RecognizedTextLine {
        var glyphs: [CGRect?] = []
        var i = 0
        for unit in text.utf16 {
            glyphs.append(unit == 0x20 ? nil : CGRect(x: x + CGFloat(i) * 10, y: y, width: 10, height: 20))
            i += 1
        }
        return RecognizedTextLine(text: text, glyphs: glyphs)
    }

    private func kinds(_ text: String) -> [(PrivacyKind, String)] {
        SensitiveRules.matchLine(line(text)).map { ($0.kind, $0.text) }
    }

    func testPhonesEmailsAndIDs() {
        XCTAssertTrue(kinds("电话：13912345678").contains { $0 == (.phone, "13912345678") })
        XCTAssertTrue(kinds("Call +65 9123 4567 now").contains { $0.0 == .phone })
        XCTAssertTrue(kinds("邮箱 demo.user@example.com").contains { $0 == (.email, "demo.user@example.com") })
        XCTAssertTrue(kinds("身份证号 110101199003071234").contains { $0.0 == .id })
        XCTAssertTrue(kinds("NRIC S1234567D").contains { $0.0 == .id })
    }

    func testCardsNeedLuhn() {
        XCTAssertTrue(kinds("4111 1111 1111 1111").contains { $0.0 == .card })
        XCTAssertFalse(kinds("4111 1111 1111 1112").contains { $0.0 == .card })
    }

    func testNamesAndAddresses() {
        XCTAssertTrue(kinds("收件人：林小满").contains { $0 == (.name, "林小满") })
        XCTAssertTrue(kinds("王先生你好").contains { $0.0 == .name && $0.1 == "王先生" })
        XCTAssertTrue(kinds("Dear John Smith,").contains { $0 == (.name, "John Smith") })
        XCTAssertTrue(kinds("地址：广东省深圳市南山区示例路188号").contains { $0.0 == .address })
        XCTAssertTrue(kinds("Blk 123 Ang Mo Kio Ave 3 #12-34").contains { $0.0 == .address })
        XCTAssertTrue(kinds("林小满").contains { $0 == (.name, "林小满") })
        XCTAssertFalse(kinds("黄色").contains { $0.0 == .name })
    }

    func testMatchCoversOnlyTheValue() throws {
        let found = try XCTUnwrap(SensitiveRules.matchLine(line("姓名：张三")).first)
        // "姓名：" is 3 characters → the name starts at x = 30.
        XCTAssertEqual(found.rect.minX, 30, accuracy: 0.1)
        XCTAssertEqual(found.rect.width, 20, accuracy: 0.1)
    }

    func testFormCellsAndColumns() {
        let label = line("姓名", y: 0, x: 0)
        let value = line("李四", y: 0, x: 80)
        XCTAssertEqual(SensitiveRules.matchAcrossLines([label, value]).map(\.text), ["李四"])

        let header = line("姓名", y: 0, x: 0)
        let rows = [line("张三", y: 30), line("王小明", y: 60)]
        XCTAssertEqual(Set(SensitiveRules.matchAcrossLines([header] + rows).map(\.text)), ["张三", "王小明"])
    }

    func testDedupeDropsInnerBoxes() {
        let big = SensitiveFinding(kind: .address, text: "a", rect: CGRect(x: 0, y: 0, width: 100, height: 20))
        let inner = SensitiveFinding(kind: .number, text: "b", rect: CGRect(x: 10, y: 2, width: 20, height: 16))
        XCTAssertEqual(SensitiveRules.dedupe([inner, big]).count, 1)
    }

    func testFamilyTablesAndHistory() {
        let row = kinds("父亲江敏和19680822群众湖南平江中学教师")
        XCTAssertTrue(row.contains { $0 == (.name, "江敏和") }, "\(row)")
        XCTAssertTrue(row.contains { $0 == (.birth, "19680822") }, "\(row)")
        XCTAssertTrue(kinds("继母：江春玉 19700224").contains { $0 == (.name, "江春玉") })
        // School and work periods are not numbers to hide.
        XCTAssertTrue(kinds("200609-201208 湖南省岳阳市平江县中学 毕业").filter { $0.0 == .number }.isEmpty)
        // "父亲高兴地说" is a sentence, not a name.
        XCTAssertFalse(kinds("父亲高兴地说").contains { $0.0 == .name })
        // A label inside a sentence without a colon is not a name.
        XCTAssertFalse(kinds("请自备黑色墨水签字笔参加笔试").contains { $0.0 == .name })
    }

    func testTaggerNamesNeedASurname() {
        XCTAssertTrue(SensitiveRules.looksLikeChineseName("林小满"))
        XCTAssertTrue(SensitiveRules.looksLikeChineseName("欧阳娜娜"))
        XCTAssertFalse(SensitiveRules.looksLikeChineseName("签字笔"))
        XCTAssertFalse(SensitiveRules.looksLikeChineseName("黄色"))
    }

    func testWarmUpTakesTheColdStart() throws {
        let t0 = Date()
        _ = try SensitiveDetector.detect(in: SensitiveDetector.warmUpImage())
        let cold = Date().timeIntervalSince(t0)
        let page = makeTextImage(["收件人：林小满", "手机：13912345678"])
        let t1 = Date()
        _ = try SensitiveDetector.detect(in: page)
        let warm = Date().timeIntervalSince(t1)
        print("warm-up (cold model) \(cold)s, first real detect after it \(warm)s")
        XCTAssertLessThan(warm, 2)
    }

    func testTilesCoverLongImages() {
        let tiles = SensitiveDetector.tiles(width: 1000, height: 6000)
        XCTAssertGreaterThan(tiles.count, 3)
        XCTAssertEqual(tiles.first?.minY, 0)
        XCTAssertEqual(tiles.last?.maxY, 6000)
        XCTAssertEqual(SensitiveDetector.tiles(width: 800, height: 600).count, 1)
    }
}

/// Draws lines of text on white, like a screenshot or a scanned form.
func makeTextImage(_ lines: [String], width: Int = 1400, lineHeight: CGFloat = 70) -> CGImage {
    let height = Int(lineHeight * CGFloat(lines.count + 1))
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawText(lines, in: ctx, height: CGFloat(height), lineHeight: lineHeight, fontSize: 34)
    return ctx.makeImage()!
}

func drawText(_ lines: [String], in ctx: CGContext, height: CGFloat, lineHeight: CGFloat, fontSize: CGFloat, x: CGFloat = 40) {
    let font = CTFontCreateWithName("PingFang SC" as CFString, fontSize, nil)
    for (i, text) in lines.enumerated() {
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let ctLine = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: x, y: height - lineHeight * CGFloat(i + 1))
        CTLineDraw(ctLine, ctx)
    }
}

final class SensitiveDetectorTests: XCTestCase {
    func testFindsTextOnAnImage() throws {
        let image = makeTextImage([
            "收件人：林小满",
            "手机：13912345678",
            "地址：广东省深圳市南山区示例路188号",
            "Email: demo.user@example.com",
            "今天天气很好，我们去公园散步。",
        ])
        let found = try SensitiveDetector.detect(in: image)
        let kinds = Set(found.map(\.kind))
        print("detected:", found.map { "\($0.kind.rawValue)=\($0.text) \($0.rect.integral)" })
        XCTAssertTrue(kinds.isSuperset(of: [.name, .phone, .address, .email]), "\(found)")
        // Nothing from the harmless last line (bottom of the image, y < 140 in bottom-left space).
        XCTAssertFalse(found.contains { $0.rect.maxY < 120 })
        // The phone box covers the number, not the label (label is ~3 chars × 34pt from x=40).
        let phone = try XCTUnwrap(found.first { $0.kind == .phone })
        XCTAssertGreaterThan(phone.rect.minX, 110)
    }
}

final class PDFSupportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cathide-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A text PDF: A4 pages, the last one landscape.
    static func writeTextPDF(to url: URL, pages: Int) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for p in 0..<pages {
            var pageBox = p == pages - 1 ? CGRect(x: 0, y: 0, width: 842, height: 595) : box
            ctx.beginPage(mediaBox: &pageBox)
            drawText([
                "第 \(p + 1) 页",
                "姓名：张三",
                "电话：13912345678",
                "邮箱 page\(p + 1)@example.com",
            ], in: ctx, height: pageBox.height, lineHeight: 30, fontSize: 14, x: 60)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    @MainActor
    func testOpenRenderDetectAndExport() async throws {
        let url = dir.appendingPathComponent("测试.pdf")
        Self.writeTextPDF(to: url, pages: 3)

        let state = MosaicDocumentState()
        state.loadImages(from: [url])
        XCTAssertEqual(state.queue.count, 3)
        XCTAssertEqual(state.pageNumber?.total, 3)
        XCTAssertEqual(state.effectStyle, .blur)
        let first = try XCTUnwrap(state.originalImage)
        // 200 dpi: 595pt → 1653px.
        XCTAssertEqual(first.width, 1653)

        let t1 = Date()
        await state.startAutoDetect()
        print("first page detect took", Date().timeIntervalSince(t1))
        let session = try XCTUnwrap(state.suggestions)
        XCTAssertTrue(Set(session.list.map(\.kind)).isSuperset(of: [.name, .phone, .email]), "\(session.list)")
        // Skip every email here: whole-document apply must skip emails on the other pages too.
        state.toggleSuggestions(session.ids(of: .email), on: false)
        let picked = try XCTUnwrap(state.suggestions).pickedCount
        XCTAssertEqual(picked, session.list.count - session.ids(of: .email).count)
        let t0 = Date()
        await state.applySuggestions()
        print("whole-document apply took", Date().timeIntervalSince(t0))
        XCTAssertNil(state.suggestions)
        XCTAssertEqual(state.strokes.count, picked)
        XCTAssertTrue(state.queue[1].strokes.count >= 2, "\(state.queue[1].strokes.count)")
        XCTAssertTrue(state.queue[2].hasEdits)

        // One undo removes the whole apply on this page.
        state.undo()
        XCTAssertTrue(state.strokes.isEmpty)
        state.redo()
        XCTAssertEqual(state.strokes.count, picked)

        // Pager and on-demand pages.
        state.selectNextPage()
        XCTAssertEqual(state.pageNumber?.current, 2)
        state.selectNextPage()
        XCTAssertEqual(state.originalImage?.width, PDFDocumentStore.pixelSize(forPageSize: CGSize(width: 842, height: 595)).width)

        let out = dir.appendingPathComponent("out.pdf")
        try state.exportImage(to: out)
        let exported = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(exported.pageCount, 3)
        XCTAssertEqual(exported.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 595, height: 842))
        XCTAssertEqual(exported.page(at: 2)?.bounds(for: .mediaBox).size, CGSize(width: 842, height: 595))
        // Image-only: no text left in the file.
        XCTAssertEqual((exported.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertTrue(state.queue.allSatisfy(\.isExported))

        // And OCR of the exported page no longer finds the phone number.
        let page2 = try XCTUnwrap(PDFDocumentStore.shared.renderPage(
            documentID: PDFDocumentStore.shared.register(exported), index: 1))
        let again = try SensitiveDetector.detect(in: page2)
        XCTAssertFalse(again.contains { $0.kind == .phone }, "\(again)")
        XCTAssertTrue(again.contains { $0.kind == .email }, "emails were skipped: \(again)")
    }

    @MainActor
    func testPasswordProtectedPDF() throws {
        let plain = dir.appendingPathComponent("plain.pdf")
        Self.writeTextPDF(to: plain, pages: 2)
        let doc = try XCTUnwrap(PDFDocument(url: plain))
        let locked = dir.appendingPathComponent("locked.pdf")
        XCTAssertTrue(doc.write(to: locked, withOptions: [.userPasswordOption: "cathide-test", .ownerPasswordOption: "cathide-owner"]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: locked)).isLocked)

        let state = MosaicDocumentState()
        var asked: [Bool] = []
        state.pdfPasswordProvider = { _, wrong in
            asked.append(wrong)
            return asked.count == 1 ? "wrong" : "cathide-test"
        }
        state.loadImages(from: [locked])
        XCTAssertEqual(asked, [false, true])
        XCTAssertEqual(state.queue.count, 2)
        XCTAssertNotNil(state.originalImage)

        let cancelled = MosaicDocumentState()
        cancelled.pdfPasswordProvider = { _, _ in nil }
        cancelled.loadImages(from: [locked])
        XCTAssertTrue(cancelled.queue.isEmpty)
    }

    @MainActor
    func testBatchExportWritesOnePDFPerDocument() throws {
        let a = dir.appendingPathComponent("a.pdf")
        Self.writeTextPDF(to: a, pages: 2)
        let state = MosaicDocumentState()
        state.loadImages(from: [a])
        state.commitStroke(MosaicStroke(tool: .rectangle, rect: CGRect(x: 10, y: 10, width: 100, height: 100)))
        XCTAssertEqual(state.batchExportCount, 1)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        XCTAssertEqual(try state.batchExportModified(to: outDir), 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: outDir.path)
        XCTAssertEqual(files, ["a_cathide.pdf"])
        XCTAssertEqual(PDFDocument(url: outDir.appendingPathComponent("a_cathide.pdf"))?.pageCount, 2)
    }

    @MainActor
    func testRotatedPageRendersUpright() throws {
        let plain = dir.appendingPathComponent("plain.pdf")
        Self.writeTextPDF(to: plain, pages: 2)
        let doc = try XCTUnwrap(PDFDocument(url: plain))
        doc.page(at: 0)?.rotation = 90
        let rotated = dir.appendingPathComponent("rotated.pdf")
        XCTAssertTrue(doc.write(to: rotated))

        let state = MosaicDocumentState()
        state.loadImages(from: [rotated])
        let image = try XCTUnwrap(state.originalImage)
        XCTAssertGreaterThan(image.width, image.height)
        XCTAssertEqual(state.currentPDFPage?.pageSize, CGSize(width: 842, height: 595))
        // Rotated 90° clockwise the text reads top-to-bottom, so OCR of an upright render
        // must not find the line; rotate the render back and it reads again.
        if let out = ProcessInfo.processInfo.environment["CATHIDE_DUMP"],
           let data = MosaicRenderer.encodeImage(image, format: .png) {
            try data.write(to: URL(fileURLWithPath: out))
        }
        let back = MosaicRenderer.rotateImage(image, quarterTurns: 3)
        let found = try SensitiveDetector.detect(in: back)
        XCTAssertTrue(found.contains { $0.kind == .phone }, "\(found)")
    }
}
