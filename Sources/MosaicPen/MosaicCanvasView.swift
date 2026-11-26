import AppKit
import CoreGraphics
import MosaicCore
import SwiftUI

struct MosaicCanvasView: NSViewRepresentable {
    var state: MosaicDocumentState
    @Binding var currentFitScale: CGFloat

    @MainActor
    final class Coordinator {
        var onFitScaleChanged: (CGFloat) -> Void

        init(onFitScaleChanged: @escaping (CGFloat) -> Void) {
            self.onFitScaleChanged = onFitScaleChanged
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator { fitScale in
            DispatchQueue.main.async {
                if abs(currentFitScale - fitScale) > 0.001 {
                    currentFitScale = fitScale
                }
            }
        }
    }

    func makeNSView(context: Context) -> CanvasInteractiveView {
        let view = CanvasInteractiveView(state: state)
        view.onFitScaleChanged = context.coordinator.onFitScaleChanged
        return view
    }

    func updateNSView(_ nsView: CanvasInteractiveView, context: Context) {
        nsView.state = state
        nsView.onFitScaleChanged = context.coordinator.onFitScaleChanged
        nsView.syncStateIfNeeded()
    }
}

@MainActor
final class CanvasInteractiveView: NSView {
    private enum CursorKind {
        case arrow
        case crosshair
        case openHand
        case closedHand
    }

    var state: MosaicDocumentState
    var onFitScaleChanged: ((CGFloat) -> Void)?

    private var previewMaskContext: CGContext?
    private var cachedMaskImage: CGImage?
    private var lastImageIdentifier: ObjectIdentifier?
    private var lastPreviewMosaicIdentifier: ObjectIdentifier?
    private var lastMaskRevision: Int = -1
    private var lastZoomMode: ZoomMode = .fit
    private var lastTool: MosaicTool = .mosaic
    private var lastBrushSize: CGFloat = 36
    private var lastMultiImageMode: Bool = false
    private var lastIsCropping: Bool = false
    private var lastCropRect: NormalizedCropRect = .full
    private var lastDraftCropRect: NormalizedCropRect = .full
    private var lastIsComparingOriginal: Bool = false

    private var activeStroke: MosaicStroke?
    private var activeSelectionStartPixel: CGPoint?
    private var activeSelectionRectPixel: CGRect?
    private var activeCropHandle: CropDragHandle?
    private var cropDragStartLocation: CGPoint = .zero
    private var cropDragStartRect: NormalizedCropRect = .full
    private var hoverPoint: CGPoint?
    private var previousHoverPoint: CGPoint?
    private var isSpacePressed = false
    private var isPanning = false
    private var panDragLastLocation: CGPoint = .zero
    private var panOffset: CGSize = .zero
    private var trackingAreaRef: NSTrackingArea?
    private var currentCursorKind: CursorKind = .arrow

    private static let checkerboardColor: NSColor = {
        let tileSize: CGFloat = 16
        let half = tileSize / 2
        let image = NSImage(size: NSSize(width: tileSize, height: tileSize))
        image.lockFocus()
        NSColor(white: 0.94, alpha: 1.0).setFill()
        NSRect(x: 0, y: 0, width: tileSize, height: tileSize).fill()
        NSColor(white: 0.86, alpha: 1.0).setFill()
        NSRect(x: 0, y: 0, width: half, height: half).fill()
        NSRect(x: half, y: half, width: half, height: half).fill()
        image.unlockFocus()
        return NSColor(patternImage: image)
    }()

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    init(state: MosaicDocumentState) {
        self.state = state
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if state.zoomMode != .fit, let original = state.originalImage {
            let scale = effectiveDisplayScale()
            let visible = activeVisiblePixelRect(for: original)
            panOffset = clampedPanOffset(
                panOffset,
                imageSize: CGSize(width: visible.width * scale, height: visible.height * scale)
            )
        }
        reportFitScale()
    }

    func syncStateIfNeeded() {
        guard let original = state.originalImage,
              let previewOriginal = state.previewOriginalImage else {
            let hadContent = previewMaskContext != nil || lastImageIdentifier != nil
            previewMaskContext = nil
            cachedMaskImage = nil
            activeStroke = nil
            activeSelectionStartPixel = nil
            activeSelectionRectPixel = nil
            activeCropHandle = nil
            lastImageIdentifier = nil
            lastPreviewMosaicIdentifier = nil
            lastMaskRevision = -1
            if hadContent {
                needsDisplay = true
            }
            return
        }

        let currentID = ObjectIdentifier(original)
        let mosaicID = state.previewMosaicImage.map(ObjectIdentifier.init)
        let imageChanged = currentID != lastImageIdentifier
        let revisionChanged = state.maskRevision != lastMaskRevision
        let zoomChanged = state.zoomMode != lastZoomMode
        let mosaicChanged = mosaicID != lastPreviewMosaicIdentifier
        let toolChanged = state.tool != lastTool
        let brushChanged = state.brushSize != lastBrushSize
        let multiImageChanged = state.isMultiImageMode != lastMultiImageMode
        let croppingChanged = state.isCropping != lastIsCropping
        let cropChanged = state.cropRect != lastCropRect
        let draftCropChanged = state.draftCropRect != lastDraftCropRect
        let compareChanged = state.isComparingOriginal != lastIsComparingOriginal

        if croppingChanged || toolChanged || imageChanged {
            activeStroke = nil
            activeSelectionStartPixel = nil
            activeSelectionRectPixel = nil
            activeCropHandle = nil
        }

        let visible = activeVisiblePixelRect(for: original)
        if imageChanged || state.zoomMode == .fit || croppingChanged || cropChanged {
            panOffset = .zero
        } else if zoomChanged || multiImageChanged {
            let scale = effectiveDisplayScale()
            panOffset = clampedPanOffset(
                panOffset,
                imageSize: CGSize(width: visible.width * scale, height: visible.height * scale)
            )
        }

        if imageChanged || revisionChanged || (!state.strokes.isEmpty && previewMaskContext == nil) {
            cachedMaskImage = nil
            if state.strokes.isEmpty {
                previewMaskContext = nil
            } else {
                let ctx = MosaicRenderer.makeMaskContext(
                    width: previewOriginal.width,
                    height: previewOriginal.height
                )
                if let ctx {
                    for stroke in state.strokes {
                        MosaicRenderer.drawStroke(stroke, into: ctx, scale: state.previewScale)
                    }
                }
                previewMaskContext = ctx
                cachedMaskImage = ctx?.makeImage()
            }
            lastImageIdentifier = currentID
            lastMaskRevision = state.maskRevision
        }

        lastPreviewMosaicIdentifier = mosaicID
        lastZoomMode = state.zoomMode
        lastTool = state.tool
        lastBrushSize = state.brushSize
        lastMultiImageMode = state.isMultiImageMode
        lastIsCropping = state.isCropping
        lastCropRect = state.cropRect
        lastDraftCropRect = state.draftCropRect
        lastIsComparingOriginal = state.isComparingOriginal

        if state.isPointerOverFloatingControls {
            clearHoverCursor()
        }

        reportFitScale()

        if imageChanged || revisionChanged || zoomChanged || mosaicChanged || toolChanged
            || brushChanged || multiImageChanged || croppingChanged || cropChanged
            || draftCropChanged || compareChanged {
            needsDisplay = true
        }
    }

    private func isPointerOnCanvas(atWindowPoint windowPoint: CGPoint) -> Bool {
        guard !state.isPointerOverFloatingControls,
              let contentView = window?.contentView else {
            return false
        }
        let hit = contentView.hitTest(windowPoint)
        return hit === self || (hit?.isDescendant(of: self) ?? false)
    }

    private func clearHoverCursor() {
        guard hoverPoint != nil || currentCursorKind != .arrow else { return }
        previousHoverPoint = hoverPoint
        hoverPoint = nil
        updateCursorIfNeeded(for: nil)
        let dirty = brushCursorDirtyRect(at: previousHoverPoint, displayScale: effectiveDisplayScale())
        if !dirty.isNull {
            setNeedsDisplay(dirty)
        }
    }

    private func reportFitScale() {
        onFitScaleChanged?(currentFitDisplayScale())
    }

    private let topOverlayInset: CGFloat = 54
    private var bottomOverlayInset: CGFloat {
        (state.isMultiImageMode && !state.isCropping) ? 162 : 74
    }

    private var openViewportSize: CGSize {
        CGSize(
            width: bounds.width,
            height: max(80, bounds.height - topOverlayInset - bottomOverlayInset)
        )
    }

    private func activeVisiblePixelRect(for original: CGImage) -> CGRect {
        if state.isCropping || state.cropRect.isFull {
            return CGRect(x: 0, y: 0, width: original.width, height: original.height)
        }
        return state.cropRect.pixelRect(width: original.width, height: original.height)
    }

    private func currentFitDisplayScale() -> CGFloat {
        guard let original = state.originalImage, bounds.width > 0, bounds.height > 0 else {
            return 1.0
        }
        let availW = max(80, openViewportSize.width - 48)
        let availH = max(80, openViewportSize.height - 28)
        let visible = activeVisiblePixelRect(for: original)
        return min(availW / max(1, visible.width), availH / max(1, visible.height), 2.0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func effectiveDisplayScale() -> CGFloat {
        switch state.zoomMode {
        case .fit:
            return currentFitDisplayScale()
        case .custom(let zoom):
            return zoom
        }
    }

    private func clampedPanOffset(_ offset: CGSize, imageSize: CGSize) -> CGSize {
        CanvasNavigationMath.clampPanOffset(offset, imageSize: imageSize, viewportSize: openViewportSize)
    }

    private func currentImageRect() -> CGRect {
        guard let original = state.originalImage else { return .zero }
        let scale = effectiveDisplayScale()
        let visible = activeVisiblePixelRect(for: original)
        let width = visible.width * scale
        let height = visible.height * scale
        let effectivePan = state.zoomMode == .fit
            ? .zero
            : clampedPanOffset(panOffset, imageSize: CGSize(width: width, height: height))
        let originX = (openViewportSize.width - width) / 2.0 + effectivePan.width
        let originY = bottomOverlayInset + (openViewportSize.height - height) / 2.0 + effectivePan.height
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func fullImageDrawRect(visibleImageRect: CGRect, visiblePixelRect: CGRect, scale: CGFloat) -> CGRect {
        guard let original = state.originalImage else { return visibleImageRect }
        return CGRect(
            x: visibleImageRect.minX - visiblePixelRect.minX * scale,
            y: visibleImageRect.minY - visiblePixelRect.minY * scale,
            width: CGFloat(original.width) * scale,
            height: CGFloat(original.height) * scale
        )
    }

    private func viewPointToOriginalPixel(_ point: CGPoint, imageRect: CGRect, displayScale: CGFloat) -> CGPoint {
        guard displayScale > 0, let original = state.originalImage else { return .zero }
        let visible = activeVisiblePixelRect(for: original)
        return CGPoint(
            x: visible.minX + (point.x - imageRect.minX) / displayScale,
            y: visible.minY + (point.y - imageRect.minY) / displayScale
        )
    }

    private func originalPixelToViewPoint(_ pixel: CGPoint, imageRect: CGRect, displayScale: CGFloat) -> CGPoint {
        guard let original = state.originalImage else { return .zero }
        let visible = activeVisiblePixelRect(for: original)
        return CGPoint(
            x: imageRect.minX + (pixel.x - visible.minX) * displayScale,
            y: imageRect.minY + (pixel.y - visible.minY) * displayScale
        )
    }

    private func cropViewRect(from normalized: NormalizedCropRect, imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + normalized.x * imageRect.width,
            y: imageRect.minY + normalized.y * imageRect.height,
            width: normalized.width * imageRect.width,
            height: normalized.height * imageRect.height
        )
    }

    private func cropHandle(at point: CGPoint, in cropRect: CGRect) -> CropDragHandle? {
        let cornerRadius: CGFloat = 12
        let edgePad: CGFloat = 9
        let corners: [(CropDragHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: cropRect.minX, y: cropRect.maxY)),
            (.topRight, CGPoint(x: cropRect.maxX, y: cropRect.maxY)),
            (.bottomLeft, CGPoint(x: cropRect.minX, y: cropRect.minY)),
            (.bottomRight, CGPoint(x: cropRect.maxX, y: cropRect.minY))
        ]
        for (handle, pt) in corners where hypot(point.x - pt.x, point.y - pt.y) <= cornerRadius {
            return handle
        }

        if abs(point.x - cropRect.minX) <= edgePad,
           point.y >= cropRect.minY - edgePad,
           point.y <= cropRect.maxY + edgePad {
            return .left
        }
        if abs(point.x - cropRect.maxX) <= edgePad,
           point.y >= cropRect.minY - edgePad,
           point.y <= cropRect.maxY + edgePad {
            return .right
        }
        if abs(point.y - cropRect.maxY) <= edgePad,
           point.x >= cropRect.minX - edgePad,
           point.x <= cropRect.maxX + edgePad {
            return .top
        }
        if abs(point.y - cropRect.minY) <= edgePad,
           point.x >= cropRect.minX - edgePad,
           point.x <= cropRect.maxX + edgePad {
            return .bottom
        }
        if cropRect.contains(point) {
            return .move
        }
        return nil
    }

    private func brushCursorDirtyRect(at point: CGPoint?, displayScale: CGFloat) -> CGRect {
        guard let point else { return .null }
        let diameter = max(6, state.brushDiameterInOriginalPixels * displayScale)
        let radius = diameter / 2.0 + 4.0
        return CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2.0, height: radius * 2.0)
    }

    private func segmentDirtyRect(
        from p0: CGPoint,
        to p1: CGPoint,
        diameter: CGFloat,
        displayScale: CGFloat,
        imageRect: CGRect
    ) -> CGRect {
        let v0 = originalPixelToViewPoint(p0, imageRect: imageRect, displayScale: displayScale)
        let v1 = originalPixelToViewPoint(p1, imageRect: imageRect, displayScale: displayScale)
        let pad = max(6, (diameter * displayScale) / 2.0 + 6.0)
        let minX = min(v0.x, v1.x) - pad
        let minY = min(v0.y, v1.y) - pad
        let maxX = max(v0.x, v1.x) + pad
        let maxY = max(v0.y, v1.y) + pad
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func zoom(to targetScale: CGFloat, around anchorInView: CGPoint) {
        guard let original = state.originalImage else { return }
        let oldScale = effectiveDisplayScale()
        let oldRect = currentImageRect()
        let visible = activeVisiblePixelRect(for: original)
        let newScale = min(8.0, max(0.1, targetScale))

        let pixel = viewPointToOriginalPixel(anchorInView, imageRect: oldRect, displayScale: oldScale)
        let relPixelX = pixel.x - visible.minX
        let relPixelY = pixel.y - visible.minY
        let newWidth = visible.width * newScale
        let newHeight = visible.height * newScale

        let rawPan = CGSize(
            width: anchorInView.x - relPixelX * newScale - (openViewportSize.width - newWidth) / 2.0,
            height: anchorInView.y - relPixelY * newScale - (bottomOverlayInset + (openViewportSize.height - newHeight) / 2.0)
        )

        panOffset = clampedPanOffset(rawPan, imageSize: CGSize(width: newWidth, height: newHeight))
        state.zoomMode = .custom(newScale)
        lastZoomMode = state.zoomMode
        needsDisplay = true
    }

    private func beginPan(at location: CGPoint) {
        isPanning = true
        panDragLastLocation = location
        updateCursorIfNeeded(for: location)
    }

    private func continuePan(to location: CGPoint) {
        let dx = location.x - panDragLastLocation.x
        let dy = location.y - panDragLastLocation.y
        panDragLastLocation = location

        if state.zoomMode == .fit {
            state.zoomMode = .custom(currentFitDisplayScale())
            lastZoomMode = state.zoomMode
        }
        let rect = currentImageRect()
        let nextOffset = clampedPanOffset(
            CGSize(width: panOffset.width + dx, height: panOffset.height + dy),
            imageSize: rect.size
        )
        if nextOffset != panOffset {
            panOffset = nextOffset
            needsDisplay = true
        }
    }

    private func endPan(at location: CGPoint) {
        isPanning = false
        updateCursorIfNeeded(for: location)
    }

    private func desiredCursorKind(at location: CGPoint?) -> CursorKind {
        if isPanning || activeCropHandle == .move {
            return .closedHand
        }
        if isSpacePressed {
            return .openHand
        }
        if state.isCropping, let location {
            let imageRect = currentImageRect()
            let cropRect = cropViewRect(from: state.draftCropRect, imageRect: imageRect)
            if let handle = cropHandle(at: location, in: cropRect) {
                return handle == .move ? .openHand : .crosshair
            }
            return .arrow
        }
        if let location, bounds.contains(location), currentImageRect().contains(location) {
            return .crosshair
        }
        return .arrow
    }

    private func applyCursor(_ kind: CursorKind) {
        switch kind {
        case .arrow: NSCursor.arrow.set()
        case .crosshair: NSCursor.crosshair.set()
        case .openHand: NSCursor.openHand.set()
        case .closedHand: NSCursor.closedHand.set()
        }
    }

    private func updateCursorIfNeeded(for location: CGPoint?) {
        let next = desiredCursorKind(at: location)
        guard next != currentCursorKind else { return }
        currentCursorKind = next
        applyCursor(next)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let clipRect = dirtyRect.intersection(bounds)
        guard !clipRect.isEmpty else { return }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let matColor = isDark
            ? NSColor(srgbRed: 0.105, green: 0.105, blue: 0.115, alpha: 1.0)
            : NSColor(srgbRed: 0.965, green: 0.967, blue: 0.976, alpha: 1.0)
        matColor.setFill()
        clipRect.fill()

        guard let original = state.originalImage,
              let previewOriginal = state.previewOriginalImage else {
            return
        }

        let imageRect = currentImageRect()
        guard !imageRect.isEmpty else { return }
        let displayScale = effectiveDisplayScale()
        let visiblePixels = activeVisiblePixelRect(for: original)
        let fullDrawRect = fullImageDrawRect(
            visibleImageRect: imageRect,
            visiblePixelRect: visiblePixels,
            scale: displayScale
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath.clip(clipRect)

        // Soft Preview-style drop shadow
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: imageRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Checkerboard background for images with alpha
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageRect).addClip()
        Self.checkerboardColor.setFill()
        imageRect.intersection(clipRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Draw base image and masked effect overlay clipped to active crop rect
        if let cgContext = NSGraphicsContext.current?.cgContext {
            cgContext.saveGState()
            cgContext.clip(to: imageRect.intersection(clipRect))
            cgContext.interpolationQuality = .high
            cgContext.draw(previewOriginal, in: fullDrawRect)

            if !state.isComparingOriginal,
               let mask = cachedMaskImage,
               let previewMosaic = state.previewMosaicImage {
                cgContext.saveGState()
                cgContext.clip(to: fullDrawRect, mask: mask)
                cgContext.draw(previewMosaic, in: fullDrawRect)
                cgContext.restoreGState()
            }
            cgContext.restoreGState()
        }

        // Subtle crisp border around visible image
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        let borderPath = NSBezierPath(rect: imageRect.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 1
        borderPath.stroke()

        if state.isCropping {
            drawCropOverlay(in: imageRect)
        } else if let selectionRectPixel = activeSelectionRectPixel {
            drawSelectionOverlay(pixelRect: selectionRectPixel, imageRect: imageRect, displayScale: displayScale)
        } else if state.tool != .rectangle,
                  !state.isComparingOriginal,
                  !state.isPointerOverFloatingControls,
                  let hoverPoint,
                  !isSpacePressed,
                  !isPanning,
                  bounds.contains(hoverPoint),
                  imageRect.insetBy(dx: -2, dy: -2).contains(hoverPoint) {
            drawBrushCursor(at: hoverPoint, displayScale: displayScale)
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSelectionOverlay(pixelRect: CGRect, imageRect: CGRect, displayScale: CGFloat) {
        let p0 = originalPixelToViewPoint(CGPoint(x: pixelRect.minX, y: pixelRect.minY), imageRect: imageRect, displayScale: displayScale)
        let p1 = originalPixelToViewPoint(CGPoint(x: pixelRect.maxX, y: pixelRect.maxY), imageRect: imageRect, displayScale: displayScale)
        let viewRect = CGRect(
            x: min(p0.x, p1.x),
            y: min(p0.y, p1.y),
            width: abs(p1.x - p0.x),
            height: abs(p1.y - p0.y)
        )
        guard !viewRect.isEmpty else { return }

        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(rect: viewRect).fill()

        let outer = NSBezierPath(rect: viewRect)
        outer.lineWidth = 2.0
        NSColor.white.withAlphaComponent(0.95).setStroke()
        outer.stroke()

        let inner = NSBezierPath(rect: viewRect)
        inner.lineWidth = 1.2
        inner.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        inner.stroke()
    }

    private func drawCropOverlay(in imageRect: CGRect) {
        let cropBox = cropViewRect(from: state.draftCropRect, imageRect: imageRect)

        // Dim outside areas inside imageRect
        let maskPath = NSBezierPath(rect: imageRect)
        maskPath.appendRect(cropBox)
        maskPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.52).setFill()
        maskPath.fill()

        // Rule of thirds grid
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let gridPath = NSBezierPath()
        gridPath.lineWidth = 0.75
        for i in 1...2 {
            let f = CGFloat(i) / 3.0
            let gx = cropBox.minX + cropBox.width * f
            gridPath.move(to: CGPoint(x: gx, y: cropBox.minY))
            gridPath.line(to: CGPoint(x: gx, y: cropBox.maxY))
            let gy = cropBox.minY + cropBox.height * f
            gridPath.move(to: CGPoint(x: cropBox.minX, y: gy))
            gridPath.line(to: CGPoint(x: cropBox.maxX, y: gy))
        }
        gridPath.stroke()

        // Crop border
        NSColor.white.withAlphaComponent(0.96).setStroke()
        let border = NSBezierPath(rect: cropBox.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        border.stroke()

        // Corner L handles & mid-edge bars
        let cornerLen: CGFloat = min(18, min(cropBox.width, cropBox.height) * 0.28)
        let handlePath = NSBezierPath()
        handlePath.lineWidth = 3.0
        handlePath.lineCapStyle = .round

        // Bottom-left
        handlePath.move(to: CGPoint(x: cropBox.minX, y: cropBox.minY + cornerLen))
        handlePath.line(to: CGPoint(x: cropBox.minX, y: cropBox.minY))
        handlePath.line(to: CGPoint(x: cropBox.minX + cornerLen, y: cropBox.minY))
        // Bottom-right
        handlePath.move(to: CGPoint(x: cropBox.maxX - cornerLen, y: cropBox.minY))
        handlePath.line(to: CGPoint(x: cropBox.maxX, y: cropBox.minY))
        handlePath.line(to: CGPoint(x: cropBox.maxX, y: cropBox.minY + cornerLen))
        // Top-left
        handlePath.move(to: CGPoint(x: cropBox.minX, y: cropBox.maxY - cornerLen))
        handlePath.line(to: CGPoint(x: cropBox.minX, y: cropBox.maxY))
        handlePath.line(to: CGPoint(x: cropBox.minX + cornerLen, y: cropBox.maxY))
        // Top-right
        handlePath.move(to: CGPoint(x: cropBox.maxX - cornerLen, y: cropBox.maxY))
        handlePath.line(to: CGPoint(x: cropBox.maxX, y: cropBox.maxY))
        handlePath.line(to: CGPoint(x: cropBox.maxX, y: cropBox.maxY - cornerLen))

        // Mid-edge grips
        let edgeLen: CGFloat = min(14, min(cropBox.width, cropBox.height) * 0.22)
        handlePath.move(to: CGPoint(x: cropBox.midX - edgeLen * 0.5, y: cropBox.maxY))
        handlePath.line(to: CGPoint(x: cropBox.midX + edgeLen * 0.5, y: cropBox.maxY))
        handlePath.move(to: CGPoint(x: cropBox.midX - edgeLen * 0.5, y: cropBox.minY))
        handlePath.line(to: CGPoint(x: cropBox.midX + edgeLen * 0.5, y: cropBox.minY))
        handlePath.move(to: CGPoint(x: cropBox.minX, y: cropBox.midY - edgeLen * 0.5))
        handlePath.line(to: CGPoint(x: cropBox.minX, y: cropBox.midY + edgeLen * 0.5))
        handlePath.move(to: CGPoint(x: cropBox.maxX, y: cropBox.midY - edgeLen * 0.5))
        handlePath.line(to: CGPoint(x: cropBox.maxX, y: cropBox.midY + edgeLen * 0.5))

        NSColor.white.setStroke()
        handlePath.stroke()
    }

    private func drawBrushCursor(at center: CGPoint, displayScale: CGFloat) {
        let diameter = max(6, state.brushDiameterInOriginalPixels * displayScale)
        let circleRect = CGRect(
            x: center.x - diameter / 2.0,
            y: center.y - diameter / 2.0,
            width: diameter,
            height: diameter
        )

        let outerPath = NSBezierPath(ovalIn: circleRect)
        outerPath.lineWidth = 2.0
        if state.tool == .eraser {
            outerPath.setLineDash([4, 3], count: 2, phase: 0)
        }
        NSColor.white.withAlphaComponent(0.92).setStroke()
        outerPath.stroke()

        let innerPath = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.75, dy: 0.75))
        innerPath.lineWidth = 1.0
        if state.tool == .eraser {
            innerPath.setLineDash([4, 3], count: 2, phase: 0)
        }
        NSColor.black.withAlphaComponent(0.75).setStroke()
        innerPath.stroke()
    }

    // MARK: - Pointer & Gesture Events

    override func cursorUpdate(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let next = desiredCursorKind(at: location)
        currentCursorKind = next
        applyCursor(next)
    }

    private func handlePointerMove(atWindowPoint windowPoint: CGPoint) {
        guard isPointerOnCanvas(atWindowPoint: windowPoint) else {
            clearHoverCursor()
            return
        }
        let location = convert(windowPoint, from: nil)
        previousHoverPoint = hoverPoint
        hoverPoint = location
        updateCursorIfNeeded(for: location)
        let scale = effectiveDisplayScale()
        let dirty = brushCursorDirtyRect(at: previousHoverPoint, displayScale: scale)
            .union(brushCursorDirtyRect(at: hoverPoint, displayScale: scale))
        if !dirty.isNull {
            setNeedsDisplay(dirty)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        handlePointerMove(atWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        clearHoverCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        handlePointerMove(atWindowPoint: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if state.isFilmstripExpandedWhileZoomed {
            state.isFilmstripExpandedWhileZoomed = false
        }
        let location = convert(event.locationInWindow, from: nil)
        previousHoverPoint = hoverPoint
        hoverPoint = location

        if isSpacePressed {
            beginPan(at: location)
            return
        }

        guard let original = state.originalImage else { return }
        let rect = currentImageRect()
        let displayScale = effectiveDisplayScale()

        if state.isCropping {
            let cropBox = cropViewRect(from: state.draftCropRect, imageRect: rect)
            if let handle = cropHandle(at: location, in: cropBox) {
                activeCropHandle = handle
                cropDragStartLocation = location
                cropDragStartRect = state.draftCropRect
                updateCursorIfNeeded(for: location)
            }
            return
        }

        if state.tool == .rectangle {
            guard rect.insetBy(dx: -4, dy: -4).contains(location) else { return }
            let rawPixel = viewPointToOriginalPixel(location, imageRect: rect, displayScale: displayScale)
            let visible = activeVisiblePixelRect(for: original)
            let clampedStart = CGPoint(
                x: max(visible.minX, min(visible.maxX, rawPixel.x)),
                y: max(visible.minY, min(visible.maxY, rawPixel.y))
            )
            activeSelectionStartPixel = clampedStart
            activeSelectionRectPixel = CGRect(origin: clampedStart, size: .zero)
            needsDisplay = true
            return
        }

        let brushRadiusView = max(4, (state.brushDiameterInOriginalPixels * displayScale) / 2.0)

        guard rect.insetBy(dx: -brushRadiusView, dy: -brushRadiusView).contains(location) else {
            return
        }

        let pixelPoint = viewPointToOriginalPixel(location, imageRect: rect, displayScale: displayScale)
        let stroke = MosaicStroke(
            tool: state.tool,
            diameter: state.brushDiameterInOriginalPixels,
            points: [pixelPoint]
        )
        activeStroke = stroke

        if let previewMaskContext = ensurePreviewMaskContext() {
            cachedMaskImage = nil
            MosaicRenderer.drawSegment(
                from: pixelPoint,
                to: pixelPoint,
                tool: stroke.tool,
                diameter: stroke.diameter,
                into: previewMaskContext,
                scale: state.previewScale
            )
            cachedMaskImage = previewMaskContext.makeImage()
            let dirty = segmentDirtyRect(
                from: pixelPoint,
                to: pixelPoint,
                diameter: stroke.diameter,
                displayScale: displayScale,
                imageRect: rect
            ).union(brushCursorDirtyRect(at: hoverPoint, displayScale: displayScale))
            setNeedsDisplay(dirty)
        }
    }

    private func ensurePreviewMaskContext() -> CGContext? {
        if let existing = previewMaskContext {
            return existing
        }
        guard let previewOriginal = state.previewOriginalImage else { return nil }
        let ctx = MosaicRenderer.makeMaskContext(
            width: previewOriginal.width,
            height: previewOriginal.height
        )
        previewMaskContext = ctx
        return ctx
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        previousHoverPoint = hoverPoint
        hoverPoint = location

        if isPanning {
            continuePan(to: location)
            return
        }

        if state.isCropping, let handle = activeCropHandle, let original = state.originalImage {
            let imageRect = currentImageRect()
            guard imageRect.width > 0, imageRect.height > 0 else { return }
            let deltaNorm = CGSize(
                width: (location.x - cropDragStartLocation.x) / imageRect.width,
                height: (location.y - cropDragStartLocation.y) / imageRect.height
            )
            let ratio = state.cropAspectPreset.targetAspectRatio(
                originalWidth: original.width,
                originalHeight: original.height
            )
            state.draftCropRect = CanvasNavigationMath.adjustedCropRect(
                from: cropDragStartRect,
                handle: handle,
                deltaNormalized: deltaNorm,
                aspectRatio: ratio,
                imageWidth: CGFloat(original.width),
                imageHeight: CGFloat(original.height)
            )
            needsDisplay = true
            return
        }

        if let startPixel = activeSelectionStartPixel, let original = state.originalImage {
            let rect = currentImageRect()
            let displayScale = effectiveDisplayScale()
            let rawPixel = viewPointToOriginalPixel(location, imageRect: rect, displayScale: displayScale)
            let visible = activeVisiblePixelRect(for: original)
            let clamped = CGPoint(
                x: max(visible.minX, min(visible.maxX, rawPixel.x)),
                y: max(visible.minY, min(visible.maxY, rawPixel.y))
            )
            activeSelectionRectPixel = CGRect(
                x: min(startPixel.x, clamped.x),
                y: min(startPixel.y, clamped.y),
                width: abs(clamped.x - startPixel.x),
                height: abs(clamped.y - startPixel.y)
            )
            needsDisplay = true
            return
        }

        guard var stroke = activeStroke, let previousPoint = stroke.points.last else { return }
        let rect = currentImageRect()
        let displayScale = effectiveDisplayScale()
        let pixelPoint = viewPointToOriginalPixel(location, imageRect: rect, displayScale: displayScale)

        let minDistance = 0.5 / max(0.1, displayScale)
        if hypot(pixelPoint.x - previousPoint.x, pixelPoint.y - previousPoint.y) < minDistance {
            let cursorDirty = brushCursorDirtyRect(at: previousHoverPoint, displayScale: displayScale)
                .union(brushCursorDirtyRect(at: hoverPoint, displayScale: displayScale))
            if !cursorDirty.isNull {
                setNeedsDisplay(cursorDirty)
            }
            return
        }

        stroke.points.append(pixelPoint)
        activeStroke = stroke

        if let previewMaskContext = ensurePreviewMaskContext() {
            cachedMaskImage = nil
            MosaicRenderer.drawSegment(
                from: previousPoint,
                to: pixelPoint,
                tool: stroke.tool,
                diameter: stroke.diameter,
                into: previewMaskContext,
                scale: state.previewScale
            )
            cachedMaskImage = previewMaskContext.makeImage()
        }

        let dirty = segmentDirtyRect(
            from: previousPoint,
            to: pixelPoint,
            diameter: stroke.diameter,
            displayScale: displayScale,
            imageRect: rect
        )
        .union(brushCursorDirtyRect(at: previousHoverPoint, displayScale: displayScale))
        .union(brushCursorDirtyRect(at: hoverPoint, displayScale: displayScale))
        setNeedsDisplay(dirty)
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            endPan(at: convert(event.locationInWindow, from: nil))
            return
        }

        if activeCropHandle != nil {
            activeCropHandle = nil
            updateCursorIfNeeded(for: convert(event.locationInWindow, from: nil))
            return
        }

        if activeSelectionStartPixel != nil {
            let finalRect = activeSelectionRectPixel
            activeSelectionStartPixel = nil
            activeSelectionRectPixel = nil
            if let finalRect, finalRect.width >= 2, finalRect.height >= 2 {
                let stroke = MosaicStroke(tool: .rectangle, rect: finalRect)
                if let ctx = ensurePreviewMaskContext() {
                    cachedMaskImage = nil
                    MosaicRenderer.drawStroke(stroke, into: ctx, scale: state.previewScale)
                    cachedMaskImage = ctx.makeImage()
                }
                state.commitStroke(stroke)
            }
            needsDisplay = true
            return
        }

        if let stroke = activeStroke {
            activeStroke = nil
            state.commitStroke(stroke)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard state.hasImage else { return }
        let location = convert(event.locationInWindow, from: nil)
        hoverPoint = location
        beginPan(at: location)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isPanning else { return }
        let location = convert(event.locationInWindow, from: nil)
        hoverPoint = location
        continuePan(to: location)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isPanning else { return }
        endPan(at: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard state.hasImage, event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        hoverPoint = location
        beginPan(at: location)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard isPanning, event.buttonNumber == 2 else {
            super.otherMouseDragged(with: event)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        hoverPoint = location
        continuePan(to: location)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard isPanning, event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        endPan(at: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        guard state.hasImage else { return }
        let anchor = convert(event.locationInWindow, from: nil)
        zoom(to: effectiveDisplayScale() * exp(event.magnification), around: anchor)
    }

    private func applyPanDelta(_ delta: CGSize) {
        let rect = currentImageRect()
        let nextOffset = clampedPanOffset(
            CGSize(width: panOffset.width + delta.width, height: panOffset.height + delta.height),
            imageSize: rect.size
        )
        if nextOffset != panOffset {
            panOffset = nextOffset
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard state.hasImage else {
            super.scrollWheel(with: event)
            return
        }

        if state.isPointerOverFloatingControls {
            super.scrollWheel(with: event)
            return
        }

        let anchor = convert(event.locationInWindow, from: nil)
        if isPointerOnCanvas(atWindowPoint: event.locationInWindow) {
            hoverPoint = anchor
        }

        let isTrackpadGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let action = CanvasNavigationMath.classifyScrollWheel(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            isTrackpadGesture: isTrackpadGesture,
            isCommandPressed: event.modifierFlags.contains(.command)
        )

        switch action {
        case .zoom(let factor):
            zoom(to: effectiveDisplayScale() * factor, around: anchor)
        case .pan(let delta):
            applyPanDelta(delta)
        case .ignore:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        if state.isCropping {
            if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                state.applyCrop()
                return
            }
            if event.keyCode == 53 { // Escape
                state.cancelCrop()
                return
            }
        }

        if state.hasImage, !state.isEditingTextInput, !state.isCropping, event.keyCode == 42 { // Backslash hold to compare
            if !event.isARepeat {
                state.isComparingOriginal = true
            }
            return
        }

        if event.keyCode == 49 { // Spacebar
            if !isSpacePressed {
                isSpacePressed = true
                updateCursorIfNeeded(for: hoverPoint)
                let dirty = brushCursorDirtyRect(at: hoverPoint, displayScale: effectiveDisplayScale())
                if !dirty.isNull {
                    setNeedsDisplay(dirty)
                }
            }
            return
        }

        if state.hasImage,
           let delta = CanvasNavigationMath.arrowPanDelta(
               keyCode: event.keyCode,
               viewportSize: openViewportSize,
               isFine: event.modifierFlags.contains(.shift)
           ) {
            applyPanDelta(delta)
            return
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 42 {
            state.isComparingOriginal = false
            return
        }
        if event.keyCode == 49 {
            isSpacePressed = false
            isPanning = false
            updateCursorIfNeeded(for: hoverPoint)
            let dirty = brushCursorDirtyRect(at: hoverPoint, displayScale: effectiveDisplayScale())
            if !dirty.isNull {
                setNeedsDisplay(dirty)
            }
            return
        }
        super.keyUp(with: event)
    }
}
