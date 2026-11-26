import CoreGraphics
import ImageIO
@testable import MosaicCore
import UniformTypeIdentifiers
import XCTest

final class MosaicCoreTests: XCTestCase {
    private func makeAlternatingTestImage(width: Int = 200, height: Int = 200) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let isRed = (x + y).isMultiple(of: 2)
                pixels[offset] = isRed ? 255 : 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = isRed ? 0 : 255
                pixels[offset + 3] = 255
            }
        }

        let data = Data(pixels)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }

    private func pixelRGBA(of image: CGImage, x: Int, yFromBottom: Int) throws -> (UInt8, UInt8, UInt8, UInt8) {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: width * height * 4)

        let ctx = try XCTUnwrap(
            CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let rowFromTop = height - 1 - yFromBottom
        let offset = (rowFromTop * width + x) * 4
        return (buffer[offset], buffer[offset + 1], buffer[offset + 2], buffer[offset + 3])
    }

    func testMosaicStrokeAltersOnlyPaintedRegion() throws {
        let original = try makeAlternatingTestImage(width: 200, height: 200)
        let stroke = MosaicStroke(
            tool: .mosaic,
            diameter: 44,
            points: [CGPoint(x: 35, y: 100), CGPoint(x: 65, y: 100)]
        )

        let rendered = try XCTUnwrap(
            MosaicRenderer.renderFinalImage(original: original, strokes: [stroke], granularity: .coarse)
        )

        XCTAssertEqual(rendered.width, original.width)
        XCTAssertEqual(rendered.height, original.height)

        let painted = try pixelRGBA(of: rendered, x: 50, yFromBottom: 100)
        XCTAssertGreaterThan(painted.0, 40, "Expected red component in blended mosaic pixel")
        XCTAssertGreaterThan(painted.2, 40, "Expected blue component in blended mosaic pixel")

        let origUntouched = try pixelRGBA(of: original, x: 165, yFromBottom: 100)
        let renderedUntouched = try pixelRGBA(of: rendered, x: 165, yFromBottom: 100)
        XCTAssertEqual(renderedUntouched.0, origUntouched.0)
        XCTAssertEqual(renderedUntouched.1, origUntouched.1)
        XCTAssertEqual(renderedUntouched.2, origUntouched.2)
        XCTAssertEqual(renderedUntouched.3, origUntouched.3)
    }

    func testEraserRestoresOriginalPixels() throws {
        let original = try makeAlternatingTestImage(width: 200, height: 200)
        let mosaicStroke = MosaicStroke(
            tool: .mosaic,
            diameter: 50,
            points: [CGPoint(x: 80, y: 100), CGPoint(x: 120, y: 100)]
        )
        let eraserStroke = MosaicStroke(
            tool: .eraser,
            diameter: 40,
            points: [CGPoint(x: 90, y: 100), CGPoint(x: 110, y: 100)]
        )

        let rendered = try XCTUnwrap(
            MosaicRenderer.renderFinalImage(
                original: original,
                strokes: [mosaicStroke, eraserStroke],
                granularity: .medium
            )
        )

        let origCenter = try pixelRGBA(of: original, x: 100, yFromBottom: 100)
        let erasedCenter = try pixelRGBA(of: rendered, x: 100, yFromBottom: 100)
        XCTAssertEqual(erasedCenter.0, origCenter.0)
        XCTAssertEqual(erasedCenter.1, origCenter.1)
        XCTAssertEqual(erasedCenter.2, origCenter.2)
        XCTAssertEqual(erasedCenter.3, origCenter.3)
    }

    @MainActor
    func testUndoRedoAndClearStateTransitions() throws {
        let original = try makeAlternatingTestImage(width: 120, height: 120)
        let state = MosaicDocumentState()
        state.loadImage(original, fileName: "sample.png")

        let initialRev = state.maskRevision
        XCTAssertTrue(state.hasImage)
        XCTAssertFalse(state.canUndo)
        XCTAssertFalse(state.canRedo)

        state.commitStroke(MosaicStroke(tool: .mosaic, diameter: 20, points: [CGPoint(x: 30, y: 30)]))
        XCTAssertTrue(state.canUndo)
        XCTAssertFalse(state.canRedo)
        XCTAssertEqual(state.strokes.count, 1)

        state.undo()
        XCTAssertFalse(state.canUndo)
        XCTAssertTrue(state.canRedo)
        XCTAssertEqual(state.maskRevision, initialRev + 1)

        state.redo()
        XCTAssertTrue(state.canUndo)
        XCTAssertFalse(state.canRedo)
        XCTAssertEqual(state.maskRevision, initialRev + 2)

        state.clearAll()
        XCTAssertTrue(state.strokes.isEmpty)
        XCTAssertTrue(state.redoStack.isEmpty)
        XCTAssertEqual(state.maskRevision, initialRev + 3)
    }

    func testPNGAndJPEGEncodingPreservesDimensions() throws {
        let original = try makeAlternatingTestImage(width: 160, height: 100)
        let pngData = try XCTUnwrap(MosaicRenderer.encodeImage(original, format: .png))
        let jpgData = try XCTUnwrap(MosaicRenderer.encodeImage(original, format: .jpeg))

        XCTAssertFalse(pngData.isEmpty)
        XCTAssertFalse(jpgData.isEmpty)

        let decodedPNG = try XCTUnwrap(MosaicRenderer.loadOrientedImage(from: pngData))
        let decodedJPG = try XCTUnwrap(MosaicRenderer.loadOrientedImage(from: jpgData))
        XCTAssertEqual(decodedPNG.width, 160)
        XCTAssertEqual(decodedPNG.height, 100)
        XCTAssertEqual(decodedJPG.width, 160)
        XCTAssertEqual(decodedJPG.height, 100)
    }

    func testPreviewDownscalesWhileFinalRenderKeepsFullResolution() throws {
        let large = try makeAlternatingTestImage(width: 3000, height: 1500)
        let preview = MosaicRenderer.makePreviewImage(from: large, maxDimension: 2048)

        XCTAssertEqual(preview.image.width, 2048)
        XCTAssertEqual(preview.image.height, 1024)
        XCTAssertLessThan(preview.scale, 1.0)

        let stroke = MosaicStroke(tool: .mosaic, diameter: 80, points: [CGPoint(x: 500, y: 500)])
        let final = try XCTUnwrap(
            MosaicRenderer.renderFinalImage(original: large, strokes: [stroke], granularity: .medium)
        )
        XCTAssertEqual(final.width, 3000)
        XCTAssertEqual(final.height, 1500)
    }

    func testSinglePointDotStrokeAppliesMosaic() throws {
        let original = try makeAlternatingTestImage(width: 160, height: 160)
        let dotStroke = MosaicStroke(
            tool: .mosaic,
            diameter: 32,
            points: [CGPoint(x: 80, y: 80)]
        )

        let rendered = try XCTUnwrap(
            MosaicRenderer.renderFinalImage(original: original, strokes: [dotStroke], granularity: .coarse)
        )

        let center = try pixelRGBA(of: rendered, x: 80, yFromBottom: 80)
        XCTAssertGreaterThan(center.0, 40)
        XCTAssertGreaterThan(center.2, 40)

        let cornerOrig = try pixelRGBA(of: original, x: 10, yFromBottom: 10)
        let cornerRendered = try pixelRGBA(of: rendered, x: 10, yFromBottom: 10)
        XCTAssertEqual(cornerRendered.0, cornerOrig.0)
        XCTAssertEqual(cornerRendered.2, cornerOrig.2)
    }

    func testGranularityBlockSizesAreOrdered() {
        let fine = MosaicGranularity.fine.blockSize(forPixelDimensions: 1920, height: 1080)
        let medium = MosaicGranularity.medium.blockSize(forPixelDimensions: 1920, height: 1080)
        let coarse = MosaicGranularity.coarse.blockSize(forPixelDimensions: 1920, height: 1080)

        XCTAssertLessThan(fine, medium)
        XCTAssertLessThan(medium, coarse)
    }

    func testClampPanOffsetCentersSmallerImageAndBoundsLargerImage() {
        let viewport = CGSize(width: 800, height: 600)

        let smallOffset = CanvasNavigationMath.clampPanOffset(
            CGSize(width: 140, height: -220),
            imageSize: CGSize(width: 400, height: 500),
            viewportSize: viewport
        )
        XCTAssertEqual(smallOffset, .zero)

        let largeOffset = CanvasNavigationMath.clampPanOffset(
            CGSize(width: 900, height: -900),
            imageSize: CGSize(width: 1200, height: 1000),
            viewportSize: viewport,
            edgePadding: 24
        )
        XCTAssertEqual(largeOffset.width, 224, accuracy: 0.01)
        XCTAssertEqual(largeOffset.height, -224, accuracy: 0.01)
    }

    func testArrowPanDeltaDirectionsAndFineStep() {
        let viewport = CGSize(width: 1000, height: 800)
        let left = CanvasNavigationMath.arrowPanDelta(keyCode: 123, viewportSize: viewport, isFine: false)
        let right = CanvasNavigationMath.arrowPanDelta(keyCode: 124, viewportSize: viewport, isFine: false)
        let down = CanvasNavigationMath.arrowPanDelta(keyCode: 125, viewportSize: viewport, isFine: false)
        let up = CanvasNavigationMath.arrowPanDelta(keyCode: 126, viewportSize: viewport, isFine: false)
        let fineLeft = CanvasNavigationMath.arrowPanDelta(keyCode: 123, viewportSize: viewport, isFine: true)

        XCTAssertGreaterThan(left?.width ?? 0, 0)
        XCTAssertLessThan(right?.width ?? 0, 0)
        XCTAssertGreaterThan(down?.height ?? 0, 0)
        XCTAssertLessThan(up?.height ?? 0, 0)
        XCTAssertEqual(fineLeft?.width, 18)
        XCTAssertNil(CanvasNavigationMath.arrowPanDelta(keyCode: 49, viewportSize: viewport, isFine: false))
    }

    func testSemanticVersionComparisonAndUnconfiguredUpdateCheck() async {
        let v100 = SemanticVersion("1.0.0")
        let v101 = SemanticVersion("v1.0.1")
        let v120 = SemanticVersion("1.2")
        let v200 = SemanticVersion("2.0.0-beta.1")

        XCTAssertNotNil(v100)
        XCTAssertNotNil(v101)
        XCTAssertNotNil(v120)
        XCTAssertNotNil(v200)
        if let v100, let v101, let v120, let v200 {
            XCTAssertLessThan(v100, v101)
            XCTAssertLessThan(v101, v120)
            XCTAssertLessThan(v120, v200)
        }

        let result = await UpdateChecker.checkForUpdates(currentVersion: "1.0.0", githubRepo: "")
        XCTAssertEqual(result, .notConfigured(currentVersion: "1.0.0"))
    }

    func testMouseWheelWithMOSZoomsInWindowsDirectionWithoutCommand() {
        let zoomIn = CanvasNavigationMath.classifyScrollWheel(
            deltaX: 0,
            deltaY: 24,
            hasPreciseDeltas: true,
            isTrackpadGesture: false,
            isCommandPressed: false
        )
        let zoomOut = CanvasNavigationMath.classifyScrollWheel(
            deltaX: 0,
            deltaY: -24,
            hasPreciseDeltas: true,
            isTrackpadGesture: false,
            isCommandPressed: false
        )

        guard case .zoom(let inFactor) = zoomIn,
              case .zoom(let outFactor) = zoomOut else {
            return XCTFail("Expected zoom actions for MOS mouse wheel")
        }
        XCTAssertGreaterThan(inFactor, 1.0)
        XCTAssertLessThan(outFactor, 1.0)
    }

    func testRawMouseWheelRespectsSystemAndMOSDirection() {
        let positiveUp = CanvasNavigationMath.classifyScrollWheel(
            deltaX: 0,
            deltaY: 2,
            hasPreciseDeltas: false,
            isTrackpadGesture: false,
            isCommandPressed: false
        )
        let negativeDown = CanvasNavigationMath.classifyScrollWheel(
            deltaX: 0,
            deltaY: -2,
            hasPreciseDeltas: false,
            isTrackpadGesture: false,
            isCommandPressed: false
        )

        guard case .zoom(let f1) = positiveUp,
              case .zoom(let f2) = negativeDown else {
            return XCTFail("Expected zoom actions for raw mouse wheel")
        }
        XCTAssertGreaterThan(f1, 1.0)
        XCTAssertLessThan(f2, 1.0)
    }

    func testTrackpadScrollPansAndCommandScrollZooms() {
        let pan = CanvasNavigationMath.classifyScrollWheel(
            deltaX: 12,
            deltaY: -8,
            hasPreciseDeltas: true,
            isTrackpadGesture: true,
            isCommandPressed: false
        )
        XCTAssertEqual(pan, .pan(delta: CGSize(width: 12, height: 8)))

        let cmdZoom = CanvasNavigationMath.classifyScrollWheel(
            deltaX: 0,
            deltaY: 16,
            hasPreciseDeltas: true,
            isTrackpadGesture: true,
            isCommandPressed: true
        )
        guard case .zoom(let factor) = cmdZoom else {
            return XCTFail("Expected zoom action for Command + trackpad scroll")
        }
        XCTAssertGreaterThan(factor, 1.0)
    }

    func testCollectImageURLsFindsAndSortsDirectoryImages() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatHideQueueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let img = try makeAlternatingTestImage(width: 40, height: 40)
        let pngData = try XCTUnwrap(MosaicRenderer.encodeImage(img, format: .png))

        for name in ["img_10.png", "img_2.png", "img_1.png"] {
            try pngData.write(to: tempDir.appendingPathComponent(name))
        }
        try Data("not an image".utf8).write(to: tempDir.appendingPathComponent("notes.txt"))

        let collected = MosaicRenderer.collectImageURLs(from: [tempDir])
        XCTAssertEqual(collected.map(\.lastPathComponent), ["img_1.png", "img_2.png", "img_10.png"])
    }

    @MainActor
    func testMultiImageQueuePreservesEditsAndAutoAdvancesOnExport() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatHideExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let img1 = try makeAlternatingTestImage(width: 100, height: 100)
        let img2 = try makeAlternatingTestImage(width: 120, height: 120)
        let state = MosaicDocumentState()
        state.loadQueue([
            MosaicQueueItem(fileName: "a.png", inMemoryImage: img1),
            MosaicQueueItem(fileName: "b.png", inMemoryImage: img2)
        ])

        XCTAssertTrue(state.isMultiImageMode)
        XCTAssertEqual(state.currentIndex, 0)

        state.commitStroke(MosaicStroke(tool: .mosaic, diameter: 20, points: [CGPoint(x: 40, y: 40)]))
        state.selectNext()
        XCTAssertEqual(state.currentIndex, 1)
        XCTAssertTrue(state.strokes.isEmpty)

        state.selectPrevious()
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertEqual(state.strokes.count, 1)

        try state.exportImage(to: tempDir.appendingPathComponent("a_cathide.png"))
        XCTAssertTrue(state.queue[0].isExported)
        XCTAssertEqual(state.currentIndex, 1)
    }

    @MainActor
    func testBatchExportWritesOnlyModifiedImages() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatHideBatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let img1 = try makeAlternatingTestImage(width: 100, height: 100)
        let img2 = try makeAlternatingTestImage(width: 100, height: 100)
        let img3 = try makeAlternatingTestImage(width: 100, height: 100)

        let state = MosaicDocumentState()
        state.loadQueue([
            MosaicQueueItem(fileName: "one.png", inMemoryImage: img1),
            MosaicQueueItem(fileName: "two.png", inMemoryImage: img2),
            MosaicQueueItem(fileName: "three.png", inMemoryImage: img3)
        ])

        state.commitStroke(MosaicStroke(tool: .mosaic, diameter: 20, points: [CGPoint(x: 50, y: 50)]))
        state.selectItem(at: 2)
        state.commitStroke(MosaicStroke(tool: .mosaic, diameter: 20, points: [CGPoint(x: 30, y: 30)]))

        let count = try state.batchExportModified(to: tempDir, format: .png)
        XCTAssertEqual(count, 2)
        XCTAssertTrue(state.queue[0].isExported)
        XCTAssertFalse(state.queue[1].isExported)
        XCTAssertTrue(state.queue[2].isExported)

        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
        XCTAssertEqual(files, ["one_cathide.png", "three_cathide.png"])
    }

    @MainActor
    func testCloseAllImagesResetsToHomeState() throws {
        let img1 = try makeAlternatingTestImage(width: 100, height: 100)
        let img2 = try makeAlternatingTestImage(width: 120, height: 120)

        let state = MosaicDocumentState()
        state.tool = .eraser
        state.brushSize = 64
        state.loadQueue([
            MosaicQueueItem(fileName: "a.png", inMemoryImage: img1),
            MosaicQueueItem(fileName: "b.png", inMemoryImage: img2)
        ])
        state.commitStroke(MosaicStroke(tool: .mosaic, diameter: 20, points: [CGPoint(x: 20, y: 20)]))
        let revBeforeClose = state.maskRevision

        state.closeAllImages()

        XCTAssertFalse(state.hasImage)
        XCTAssertFalse(state.isMultiImageMode)
        XCTAssertTrue(state.queue.isEmpty)
        XCTAssertTrue(state.strokes.isEmpty)
        XCTAssertEqual(state.fileName, "猫猫藏藏")
        XCTAssertEqual(state.maskRevision, revBeforeClose + 1)
        XCTAssertEqual(state.tool, .eraser)
        XCTAssertEqual(state.brushSize, 64)
    }

    @MainActor
    func testRenameCurrentImageUpdatesQueueAndExportNames() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatHideRenameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let img = try makeAlternatingTestImage(width: 80, height: 80)
        let sourceURL = tempDir.appendingPathComponent("orig_01.png")
        let state = MosaicDocumentState()
        state.loadQueue([
            MosaicQueueItem(sourceURL: sourceURL, fileName: "orig_01.png", inMemoryImage: img)
        ])

        XCTAssertEqual(state.currentFileStem, "orig_01")
        XCTAssertTrue(state.renameCurrentImage(to: "  cat:hero/clean  "))
        XCTAssertEqual(state.fileName, "cat-hero-clean.png")
        XCTAssertEqual(state.sourceURL, sourceURL)
        XCTAssertEqual(state.suggestedExportFileName(format: .png), "cat-hero-clean.png")

        state.commitStroke(MosaicStroke(tool: .mosaic, diameter: 20, points: [CGPoint(x: 40, y: 40)]))
        let exported = try state.batchExportModified(to: tempDir, format: .png)
        XCTAssertEqual(exported, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("cat-hero-clean.png").path))
    }

    func testAppAppearanceCasesAndRawValues() {
        XCTAssertEqual(AppAppearance.allCases, [.system, .light, .dark])
        XCTAssertEqual(AppAppearance(rawValue: "light"), .light)
        XCTAssertEqual(AppAppearance(rawValue: "dark"), .dark)
        XCTAssertEqual(AppAppearance(rawValue: "system"), .system)
        XCTAssertEqual(AppAppearance.system.next, .light)
        XCTAssertEqual(AppAppearance.light.next, .dark)
        XCTAssertEqual(AppAppearance.dark.next, .system)
    }

    func testDockCardTransformWaveAndBounds() {
        let peak = CanvasNavigationMath.dockCardTransform(
            distance: 0,
            influenceRadius: 108,
            maxScale: 1.22,
            maxLift: 8
        )
        XCTAssertEqual(peak.scale, 1.22, accuracy: 0.0001)
        XCTAssertEqual(peak.liftY, -8, accuracy: 0.0001)

        let neighbor = CanvasNavigationMath.dockCardTransform(
            distance: 54,
            influenceRadius: 108,
            maxScale: 1.22,
            maxLift: 8
        )
        XCTAssertEqual(neighbor.scale, 1.11, accuracy: 0.0001)
        XCTAssertEqual(neighbor.liftY, -4, accuracy: 0.0001)
        XCTAssertGreaterThan(peak.scale, neighbor.scale)
        XCTAssertLessThan(peak.liftY, neighbor.liftY)

        let farEdge = CanvasNavigationMath.dockCardTransform(
            distance: -108,
            influenceRadius: 108,
            maxScale: 1.22,
            maxLift: 8
        )
        XCTAssertEqual(farEdge, .identity)

        let beyond = CanvasNavigationMath.dockCardTransform(
            distance: 150,
            influenceRadius: 108,
            maxScale: 1.22,
            maxLift: 8
        )
        XCTAssertEqual(beyond, .identity)
    }

    func testFilmstripIndexMappingAndClamping() {
        XCTAssertNil(CanvasNavigationMath.filmstripIndex(forContentX: 20, itemCount: 0))

        // Tile 0 center at 8 + 27 = 35; step = 54 + 10 = 64
        XCTAssertEqual(CanvasNavigationMath.filmstripIndex(forContentX: -20, itemCount: 3), 0)
        XCTAssertEqual(CanvasNavigationMath.filmstripIndex(forContentX: 35, itemCount: 3), 0)
        XCTAssertEqual(CanvasNavigationMath.filmstripIndex(forContentX: 66, itemCount: 3), 0)
        XCTAssertEqual(CanvasNavigationMath.filmstripIndex(forContentX: 67, itemCount: 3), 1)
        XCTAssertEqual(CanvasNavigationMath.filmstripIndex(forContentX: 99, itemCount: 3), 1)
        XCTAssertEqual(CanvasNavigationMath.filmstripIndex(forContentX: 163, itemCount: 3), 2)
        XCTAssertEqual(CanvasNavigationMath.filmstripIndex(forContentX: 999, itemCount: 3), 2)
    }

    @MainActor
    func testSetBrushSizeFromInputClampsAndRejectsInvalidText() {
        XCTAssertEqual(MosaicGranularity.allCases.map(\.title), ["小", "中", "大"])

        let state = MosaicDocumentState()
        XCTAssertFalse(state.isEditingTextInput)

        state.isEditingBrushSize = true
        XCTAssertTrue(state.isEditingTextInput)
        state.isEditingBrushSize = false
        state.isRenamingTitle = true
        XCTAssertTrue(state.isEditingTextInput)
        state.isRenamingTitle = false
        XCTAssertFalse(state.isEditingTextInput)

        XCTAssertTrue(state.setBrushSize(fromInput: "72"))
        XCTAssertEqual(state.brushSize, 72)

        XCTAssertTrue(state.setBrushSize(fromInput: " 49.6 "))
        XCTAssertEqual(state.brushSize, 50)

        XCTAssertTrue(state.setBrushSize(fromInput: "2"))
        XCTAssertEqual(state.brushSize, MosaicDocumentState.minBrushSize)

        XCTAssertTrue(state.setBrushSize(fromInput: "999"))
        XCTAssertEqual(state.brushSize, MosaicDocumentState.maxBrushSize)

        XCTAssertFalse(state.setBrushSize(fromInput: ""))
        XCTAssertEqual(state.brushSize, MosaicDocumentState.maxBrushSize)

        XCTAssertFalse(state.setBrushSize(fromInput: "abc"))
        XCTAssertEqual(state.brushSize, MosaicDocumentState.maxBrushSize)
    }

    @MainActor
    func testPreparedImageCacheReusesAndUpdatesOnGranularityChange() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatHideCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let urls: [URL] = try (1...3).map { idx in
            let img = try makeAlternatingTestImage(width: 60 + idx * 10, height: 60 + idx * 10)
            let data = try XCTUnwrap(MosaicRenderer.encodeImage(img, format: .png))
            let url = tempDir.appendingPathComponent("cache_\(idx).png")
            try data.write(to: url)
            return url
        }

        let state = MosaicDocumentState()
        state.loadImages(from: urls)
        XCTAssertEqual(state.queue.count, 3)

        state.selectItem(at: 1)
        let firstPreview = state.previewOriginalImage
        XCTAssertNotNil(firstPreview)
        XCTAssertNotNil(state.previewMosaicImage)

        state.selectItem(at: 2)
        state.selectItem(at: 1)
        XCTAssertTrue(state.previewOriginalImage === firstPreview)

        state.setGranularity(.coarse)
        let coarseMosaic = state.previewMosaicImage
        XCTAssertEqual(state.granularity, .coarse)
        XCTAssertNotNil(coarseMosaic)

        state.selectItem(at: 2)
        XCTAssertEqual(state.granularity, .medium)

        state.selectItem(at: 1)
        XCTAssertEqual(state.granularity, .coarse)
        XCTAssertTrue(state.previewMosaicImage === coarseMosaic)
        XCTAssertNotNil(state.originalImage)
    }

    func testZoomScaleForDragSensitivityAndClamping() {
        let unchanged = CanvasNavigationMath.zoomScaleForDrag(baseScale: 1.0, translationX: 0)
        XCTAssertEqual(unchanged, 1.0, accuracy: 0.0001)

        let zoomedIn = CanvasNavigationMath.zoomScaleForDrag(baseScale: 1.0, translationX: 50)
        XCTAssertGreaterThan(zoomedIn, 1.0)
        XCTAssertLessThanOrEqual(zoomedIn, 8.0)

        let zoomedOut = CanvasNavigationMath.zoomScaleForDrag(baseScale: 1.0, translationX: -50)
        XCTAssertLessThan(zoomedOut, 1.0)
        XCTAssertGreaterThanOrEqual(zoomedOut, 0.1)

        let clampedMax = CanvasNavigationMath.zoomScaleForDrag(baseScale: 2.0, translationX: 2000)
        XCTAssertEqual(clampedMax, 8.0, accuracy: 0.0001)

        let clampedMin = CanvasNavigationMath.zoomScaleForDrag(baseScale: 0.5, translationX: -2000)
        XCTAssertEqual(clampedMin, 0.1, accuracy: 0.0001)
    }

    @MainActor
    func testShortcutStorePersistenceConflictAndReset() throws {
        let suiteName = "CatHideShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ShortcutStore(defaults: defaults)
        XCTAssertFalse(store.hasCustomShortcuts)
        XCTAssertEqual(store.combo(for: .toolMosaic).displayString, "B")
        XCTAssertEqual(store.combo(for: .exportCurrent).displayString, "⌘S")
        XCTAssertEqual(store.combo(for: .redo).displayString, "⇧⌘Z")
        XCTAssertTrue(store.combo(for: .toolMosaic).isSingleKeyWithoutModifier)
        XCTAssertFalse(store.combo(for: .openImage).isSingleKeyWithoutModifier)

        // Conflict with exportCurrent (⌘S) when setting toolMosaic -> rejected
        let conflict = store.setCombo(ShortcutCombo(key: "s", modifiers: .command), for: .toolMosaic)
        XCTAssertEqual(conflict, .exportCurrent)
        XCTAssertEqual(store.combo(for: .toolMosaic), AppShortcutAction.toolMosaic.defaultCombo)

        // Non-conflicting custom shortcut persists across reload
        let customCombo = ShortcutCombo(key: "m", modifiers: [.command, .option])
        XCTAssertNil(store.setCombo(customCombo, for: .toolMosaic))
        XCTAssertTrue(store.hasCustomShortcuts)
        XCTAssertEqual(store.combo(for: .toolMosaic), customCombo)
        XCTAssertEqual(customCombo.displayString, "⌥⌘M")

        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertEqual(reloaded.combo(for: .toolMosaic), customCombo)
        XCTAssertTrue(reloaded.hasCustomShortcuts)

        // Single action reset
        reloaded.reset(.toolMosaic)
        XCTAssertEqual(reloaded.combo(for: .toolMosaic), AppShortcutAction.toolMosaic.defaultCombo)
        XCTAssertFalse(reloaded.hasCustomShortcuts)

        // Reset all
        XCTAssertNil(reloaded.setCombo(ShortcutCombo(key: "k"), for: .toolEraser))
        XCTAssertTrue(reloaded.hasCustomShortcuts)
        reloaded.resetAll()
        XCTAssertFalse(reloaded.hasCustomShortcuts)
        XCTAssertEqual(reloaded.combo(for: .toolEraser), AppShortcutAction.toolEraser.defaultCombo)
    }

    func testResolvedImageFileNamePrefersRealNameAndCleanFallback() {
        XCTAssertEqual(
            MosaicRenderer.resolvedImageFileName(
                suggestedName: "photo_01",
                fileURL: URL(fileURLWithPath: "/tmp/tmp123.jpg")
            ),
            "photo_01.jpg"
        )
        XCTAssertEqual(
            MosaicRenderer.resolvedImageFileName(
                suggestedName: "photo_01.png",
                fileURL: nil
            ),
            "photo_01.png"
        )
        XCTAssertEqual(
            MosaicRenderer.resolvedImageFileName(
                suggestedName: nil,
                fileURL: URL(fileURLWithPath: "/tmp/cat.webp")
            ),
            "cat.webp"
        )
        XCTAssertEqual(
            MosaicRenderer.resolvedImageFileName(
                suggestedName: "  ",
                fileURL: nil,
                preferredExtension: "png"
            ),
            "未命名.png"
        )
    }

    func testBlurAndSolidEffectStylesAlterMaskedRegion() throws {
        let original = try makeAlternatingTestImage(width: 120, height: 120)
        let stroke = MosaicStroke(tool: .mosaic, diameter: 28, points: [CGPoint(x: 60, y: 60)])

        let blurred = try XCTUnwrap(
            MosaicRenderer.renderFinalImage(
                original: original,
                strokes: [stroke],
                granularity: .medium,
                style: .blur
            )
        )
        let expectedUntouched = try pixelRGBA(of: original, x: 5, yFromBottom: 5)
        let untouchedBlur = try pixelRGBA(of: blurred, x: 5, yFromBottom: 5)
        let maskedBlur = try pixelRGBA(of: blurred, x: 60, yFromBottom: 60)
        XCTAssertEqual(untouchedBlur.0, expectedUntouched.0)
        XCTAssertEqual(untouchedBlur.1, expectedUntouched.1)
        XCTAssertEqual(untouchedBlur.2, expectedUntouched.2)
        XCTAssertNotEqual(maskedBlur.0, 255)
        XCTAssertNotEqual(maskedBlur.2, 255)

        let solidBlack = try XCTUnwrap(
            MosaicRenderer.renderFinalImage(
                original: original,
                strokes: [stroke],
                granularity: .fine,
                style: .solid
            )
        )
        let centerBlack = try pixelRGBA(of: solidBlack, x: 60, yFromBottom: 60)
        XCTAssertLessThan(centerBlack.0, 35)
        XCTAssertLessThan(centerBlack.1, 35)
        XCTAssertLessThan(centerBlack.2, 35)
    }

    func testRectangleStrokeFillsRectAndEraserRestores() throws {
        let original = try makeAlternatingTestImage(width: 120, height: 120)
        let rectStroke = MosaicStroke(tool: .rectangle, rect: CGRect(x: 20, y: 20, width: 50, height: 50))
        let eraserStroke = MosaicStroke(tool: .eraser, diameter: 24, points: [CGPoint(x: 45, y: 45)])

        let masked = try XCTUnwrap(
            MosaicRenderer.renderFinalImage(
                original: original,
                strokes: [rectStroke, eraserStroke],
                granularity: .coarse,
                style: .solid
            )
        )
        // Corner of rect stays masked (solid white ~240)
        let cornerPx = try pixelRGBA(of: masked, x: 24, yFromBottom: 24)
        XCTAssertGreaterThan(cornerPx.0, 215)
        XCTAssertGreaterThan(cornerPx.1, 215)
        XCTAssertGreaterThan(cornerPx.2, 215)

        // Erased center restores alternating checkerboard pixel (255,0,0) or (0,0,255)
        let erasedPx = try pixelRGBA(of: masked, x: 45, yFromBottom: 45)
        XCTAssertEqual(erasedPx.1, 0)

        // Outside rect stays original
        let outsidePx = try pixelRGBA(of: masked, x: 100, yFromBottom: 100)
        XCTAssertEqual(outsidePx.1, 0)
    }

    func testCropAndRotationMathPreservesCoordinatesAndOutputSize() throws {
        let original = try makeAlternatingTestImage(width: 200, height: 100)
        let rotatedPoint = CanvasNavigationMath.rotatePointClockwise(
            CGPoint(x: 20, y: 10),
            originalWidth: 200,
            originalHeight: 100
        )
        XCTAssertEqual(rotatedPoint.x, 10, accuracy: 0.001)
        XCTAssertEqual(rotatedPoint.y, 180, accuracy: 0.001)

        let rotatedImage = MosaicRenderer.rotateImage(original, quarterTurns: 1)
        XCTAssertEqual(rotatedImage.width, 100)
        XCTAssertEqual(rotatedImage.height, 200)

        let crop = NormalizedCropRect(x: 0.2, y: 0.25, width: 0.5, height: 0.5)
        let cropped = try XCTUnwrap(
            MosaicRenderer.renderFinalImage(
                original: rotatedImage,
                strokes: [],
                granularity: .medium,
                style: .mosaic,
                cropRect: crop
            )
        )
        XCTAssertEqual(cropped.width, 50)
        XCTAssertEqual(cropped.height, 100)
    }

    func testEncodeImageStripsEXIFByDefaultAndCanPreserve() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatHideEXIFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let img = try makeAlternatingTestImage(width: 80, height: 80)
        let sourceURL = tempDir.appendingPathComponent("with_exif.jpg")

        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(sourceURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let exifProps: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "SecretDevice"] as CFDictionary,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLatitude: 37.33,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSLongitude: 122.01
            ] as CFDictionary
        ]
        CGImageDestinationAddImage(dest, img, exifProps as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let strippedData = try XCTUnwrap(
            MosaicRenderer.encodeImage(img, format: .jpeg, stripMetadata: true, sourceMetadataURL: sourceURL)
        )
        let strippedSrc = try XCTUnwrap(CGImageSourceCreateWithData(strippedData as CFData, nil))
        let strippedProps = (CGImageSourceCopyPropertiesAtIndex(strippedSrc, 0, nil) as? [CFString: Any]) ?? [:]
        XCTAssertNil(strippedProps[kCGImagePropertyGPSDictionary])
        XCTAssertNil((strippedProps[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])

        let preservedData = try XCTUnwrap(
            MosaicRenderer.encodeImage(img, format: .jpeg, stripMetadata: false, sourceMetadataURL: sourceURL)
        )
        let preservedSrc = try XCTUnwrap(CGImageSourceCreateWithData(preservedData as CFData, nil))
        let preservedProps = (CGImageSourceCopyPropertiesAtIndex(preservedSrc, 0, nil) as? [CFString: Any]) ?? [:]
        XCTAssertNotNil(preservedProps[kCGImagePropertyGPSDictionary])
        let preservedExif = preservedProps[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(preservedExif?[kCGImagePropertyExifUserComment] as? String, "SecretDevice")
    }

    @MainActor
    func testQueueRemoveAppendAndUnsavedTracking() throws {
        let img1 = try makeAlternatingTestImage(width: 80, height: 80)
        let img2 = try makeAlternatingTestImage(width: 90, height: 90)
        let img3 = try makeAlternatingTestImage(width: 100, height: 100)

        let state = MosaicDocumentState()
        state.loadQueue([
            MosaicQueueItem(fileName: "1.png", inMemoryImage: img1),
            MosaicQueueItem(fileName: "2.png", inMemoryImage: img2)
        ])
        XCTAssertFalse(state.hasUnsavedChanges)

        state.commitStroke(MosaicStroke(tool: .rectangle, rect: CGRect(x: 10, y: 10, width: 20, height: 20)))
        XCTAssertEqual(state.unsavedCount, 1)
        XCTAssertTrue(state.hasUnsavedChanges)

        state.appendQueueItems([MosaicQueueItem(fileName: "3.png", inMemoryImage: img3)])
        XCTAssertEqual(state.queue.count, 3)
        XCTAssertEqual(state.currentIndex, 2)
        XCTAssertEqual(state.unsavedCount, 1)

        state.removeItem(at: 0)
        XCTAssertEqual(state.queue.count, 2)
        XCTAssertEqual(state.currentIndex, 1)
        XCTAssertFalse(state.hasUnsavedChanges)
    }
}
