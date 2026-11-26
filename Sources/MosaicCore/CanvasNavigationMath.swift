import CoreGraphics
import Foundation

public enum ScrollWheelAction: Equatable, Sendable {
    case zoom(scaleFactor: CGFloat)
    case pan(delta: CGSize)
    case ignore
}

public enum CanvasNavigationMath {
    public static func clampPanOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        viewportSize: CGSize,
        edgePadding: CGFloat = 24
    ) -> CGSize {
        let clampedX: CGFloat
        if imageSize.width <= viewportSize.width {
            clampedX = 0
        } else {
            let maxX = (imageSize.width - viewportSize.width) / 2.0 + edgePadding
            clampedX = min(maxX, max(-maxX, offset.width))
        }

        let clampedY: CGFloat
        if imageSize.height <= viewportSize.height {
            clampedY = 0
        } else {
            let maxY = (imageSize.height - viewportSize.height) / 2.0 + edgePadding
            clampedY = min(maxY, max(-maxY, offset.height))
        }

        return CGSize(width: clampedX, height: clampedY)
    }

    public static func arrowPanDelta(
        keyCode: UInt16,
        viewportSize: CGSize,
        isFine: Bool
    ) -> CGSize? {
        let step: CGFloat = isFine
            ? 18
            : max(44, min(viewportSize.width, viewportSize.height) * 0.14)

        switch keyCode {
        case 123: // Left arrow -> reveal left side of image
            return CGSize(width: step, height: 0)
        case 124: // Right arrow -> reveal right side of image
            return CGSize(width: -step, height: 0)
        case 125: // Down arrow -> reveal lower side of image (AppKit bottom-left origin)
            return CGSize(width: 0, height: step)
        case 126: // Up arrow -> reveal upper side of image
            return CGSize(width: 0, height: -step)
        default:
            return nil
        }
    }

    public static func classifyScrollWheel(
        deltaX: CGFloat,
        deltaY: CGFloat,
        hasPreciseDeltas: Bool,
        isTrackpadGesture: Bool,
        isCommandPressed: Bool
    ) -> ScrollWheelAction {
        if !isTrackpadGesture {
            guard deltaY != 0 else { return .ignore }
            if hasPreciseDeltas {
                let clamped = max(-60, min(60, deltaY))
                return .zoom(scaleFactor: exp(clamped * 0.004))
            } else {
                let clamped = max(-10, min(10, deltaY))
                return .zoom(scaleFactor: exp(clamped * 0.08))
            }
        }

        if isCommandPressed {
            guard deltaY != 0 else { return .ignore }
            let clamped = max(-60, min(60, deltaY))
            return .zoom(scaleFactor: exp(clamped * 0.005))
        }

        return .pan(delta: CGSize(width: deltaX, height: -deltaY))
    }
}

public struct DockCardTransform: Equatable, Sendable {
    public let scale: CGFloat
    public let liftY: CGFloat

    public static let identity = DockCardTransform(scale: 1.0, liftY: 0.0)

    public init(scale: CGFloat, liftY: CGFloat) {
        self.scale = scale
        self.liftY = liftY
    }
}

public extension CanvasNavigationMath {
    static func dockCardTransform(
        distance: CGFloat,
        influenceRadius: CGFloat = 108,
        maxScale: CGFloat = 1.24,
        maxLift: CGFloat = 9
    ) -> DockCardTransform {
        guard influenceRadius > 0 else { return .identity }
        let absDist = abs(distance)
        guard absDist < influenceRadius else { return .identity }
        let normalized = absDist / influenceRadius
        let falloff = 0.5 * (1.0 + cos(.pi * normalized))
        return DockCardTransform(
            scale: 1.0 + (maxScale - 1.0) * falloff,
            liftY: -maxLift * falloff
        )
    }

    static func filmstripIndex(
        forContentX x: CGFloat,
        itemCount: Int,
        tileSize: CGFloat = 54,
        spacing: CGFloat = 10,
        leadingPadding: CGFloat = 8
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        let step = tileSize + spacing
        guard step > 0 else { return 0 }
        let adjusted = x - leadingPadding
        let raw = Int(floor((adjusted + spacing * 0.5) / step))
        return max(0, min(itemCount - 1, raw))
    }

    static func zoomScaleForDrag(
        baseScale: CGFloat,
        translationX: CGFloat,
        sensitivity: CGFloat = 0.014,
        minScale: CGFloat = 0.1,
        maxScale: CGFloat = 8.0
    ) -> CGFloat {
        let factor = exp(translationX * sensitivity)
        return min(maxScale, max(minScale, baseScale * factor))
    }
}

public enum CropDragHandle: Equatable, Sendable {
    case move
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case top
    case bottom
    case left
    case right
}

public extension CanvasNavigationMath {
    static func rotatePointClockwise(
        _ point: CGPoint,
        originalWidth: CGFloat,
        originalHeight: CGFloat
    ) -> CGPoint {
        _ = originalHeight
        return CGPoint(x: point.y, y: originalWidth - point.x)
    }

    static func rotateRectClockwise(
        _ rect: CGRect,
        originalWidth: CGFloat,
        originalHeight: CGFloat
    ) -> CGRect {
        let corners = [
            rotatePointClockwise(CGPoint(x: rect.minX, y: rect.minY), originalWidth: originalWidth, originalHeight: originalHeight),
            rotatePointClockwise(CGPoint(x: rect.maxX, y: rect.minY), originalWidth: originalWidth, originalHeight: originalHeight),
            rotatePointClockwise(CGPoint(x: rect.minX, y: rect.maxY), originalWidth: originalWidth, originalHeight: originalHeight),
            rotatePointClockwise(CGPoint(x: rect.maxX, y: rect.maxY), originalWidth: originalWidth, originalHeight: originalHeight)
        ]
        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func rotateNormalizedCropClockwise(_ crop: NormalizedCropRect) -> NormalizedCropRect {
        NormalizedCropRect(
            x: max(0, min(1, crop.y)),
            y: max(0, min(1, 1.0 - crop.x - crop.width)),
            width: max(0.01, min(1, crop.height)),
            height: max(0.01, min(1, crop.width))
        )
    }

    static func fittedCropRect(
        within bounds: NormalizedCropRect,
        aspectRatio: CGFloat,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> NormalizedCropRect {
        guard aspectRatio > 0, imageWidth > 0, imageHeight > 0 else { return bounds }
        let pixelBoundsW = bounds.width * imageWidth
        let pixelBoundsH = bounds.height * imageHeight
        let targetW: CGFloat
        let targetH: CGFloat
        if pixelBoundsW / pixelBoundsH > aspectRatio {
            targetH = pixelBoundsH
            targetW = targetH * aspectRatio
        } else {
            targetW = pixelBoundsW
            targetH = targetW / aspectRatio
        }
        let normW = min(bounds.width, targetW / imageWidth)
        let normH = min(bounds.height, targetH / imageHeight)
        return NormalizedCropRect(
            x: bounds.x + (bounds.width - normW) * 0.5,
            y: bounds.y + (bounds.height - normH) * 0.5,
            width: normW,
            height: normH
        )
    }

    static func adjustedCropRect(
        from start: NormalizedCropRect,
        handle: CropDragHandle,
        deltaNormalized: CGSize,
        aspectRatio: CGFloat?,
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        minSize: CGFloat = 0.06
    ) -> NormalizedCropRect {
        let clampedMin = max(0.02, min(0.5, minSize))

        if handle == .move {
            let nx = max(0, min(1 - start.width, start.x + deltaNormalized.width))
            let ny = max(0, min(1 - start.height, start.y + deltaNormalized.height))
            return NormalizedCropRect(x: nx, y: ny, width: start.width, height: start.height)
        }

        var left = start.x
        var right = start.x + start.width
        var bottom = start.y
        var top = start.y + start.height

        let movesLeft = handle == .left || handle == .topLeft || handle == .bottomLeft
        let movesRight = handle == .right || handle == .topRight || handle == .bottomRight
        let movesBottom = handle == .bottom || handle == .bottomLeft || handle == .bottomRight
        let movesTop = handle == .top || handle == .topLeft || handle == .topRight

        if movesLeft {
            left = max(0, min(right - clampedMin, start.x + deltaNormalized.width))
        }
        if movesRight {
            right = min(1, max(left + clampedMin, start.x + start.width + deltaNormalized.width))
        }
        if movesBottom {
            bottom = max(0, min(top - clampedMin, start.y + deltaNormalized.height))
        }
        if movesTop {
            top = min(1, max(bottom + clampedMin, start.y + start.height + deltaNormalized.height))
        }

        if let aspectRatio, aspectRatio > 0, imageWidth > 0, imageHeight > 0 {
            let normRatio = aspectRatio * (imageHeight / imageWidth)
            var w = right - left
            var h = top - bottom

            if (movesLeft || movesRight) && !(movesTop || movesBottom) {
                h = w / normRatio
                let midY = (bottom + top) * 0.5
                bottom = max(0, min(1 - h, midY - h * 0.5))
                top = bottom + h
                if top > 1 {
                    top = 1
                    h = top - bottom
                    w = h * normRatio
                    if movesLeft { left = right - w } else { right = left + w }
                }
            } else if (movesTop || movesBottom) && !(movesLeft || movesRight) {
                w = h * normRatio
                let midX = (left + right) * 0.5
                left = max(0, min(1 - w, midX - w * 0.5))
                right = left + w
                if right > 1 {
                    right = 1
                    w = right - left
                    h = w / normRatio
                    if movesBottom { bottom = top - h } else { top = bottom + h }
                }
            } else {
                // Corner drag: preserve anchored opposite corner
                let maxW = movesLeft ? right : (1 - left)
                let maxH = movesBottom ? top : (1 - bottom)
                if w / max(0.0001, h) > normRatio {
                    h = w / normRatio
                } else {
                    w = h * normRatio
                }
                if w > maxW {
                    w = maxW
                    h = w / normRatio
                }
                if h > maxH {
                    h = maxH
                    w = h * normRatio
                }
                if w < clampedMin {
                    w = clampedMin
                    h = w / normRatio
                }
                if h < clampedMin {
                    h = clampedMin
                    w = h * normRatio
                }
                if movesLeft { left = right - w } else { right = left + w }
                if movesBottom { bottom = top - h } else { top = bottom + h }
            }
        }

        return NormalizedCropRect(
            x: max(0, left),
            y: max(0, bottom),
            width: max(clampedMin, min(1 - left, right - left)),
            height: max(clampedMin, min(1 - bottom, top - bottom))
        )
    }
}

