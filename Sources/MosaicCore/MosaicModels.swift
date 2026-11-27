import CoreGraphics
import Foundation

public enum MosaicTool: String, CaseIterable, Identifiable, Sendable {
    case mosaic
    case rectangle
    case eraser

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mosaic: "涂抹"
        case .rectangle: "框选"
        case .eraser: "橡皮"
        }
    }

    public var systemImage: String {
        switch self {
        case .mosaic: "paintbrush.pointed.fill"
        case .rectangle: "rectangle.dashed"
        case .eraser: "eraser.fill"
        }
    }
}

public enum MosaicEffectStyle: String, CaseIterable, Identifiable, Sendable {
    case mosaic
    case blur
    case solid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mosaic: "马赛克"
        case .blur: "高斯模糊"
        case .solid: "纯色遮挡"
        }
    }

    public var shortTitle: String {
        switch self {
        case .mosaic: "马赛克"
        case .blur: "模糊"
        case .solid: "纯色"
        }
    }

    public var systemImage: String {
        switch self {
        case .mosaic: "square.grid.3x3.fill"
        case .blur: "drop.halffull"
        case .solid: "square.fill"
        }
    }
}

public enum MosaicGranularity: String, CaseIterable, Identifiable, Sendable {
    case fine
    case medium
    case coarse

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fine: "小"
        case .medium: "中"
        case .coarse: "大"
        }
    }

    public func title(for style: MosaicEffectStyle) -> String {
        switch style {
        case .solid:
            switch self {
            case .fine: return "黑"
            case .medium: return "灰"
            case .coarse: return "白"
            }
        case .mosaic, .blur:
            return title
        }
    }

    public func blockSize(forPixelDimensions width: Int, height: Int) -> CGFloat {
        let maxDim = CGFloat(max(width, height))
        switch self {
        case .fine:
            return max(6, (maxDim / 110).rounded())
        case .medium:
            return max(10, (maxDim / 65).rounded())
        case .coarse:
            return max(16, (maxDim / 38).rounded())
        }
    }

    public func blurRadius(forPixelDimensions width: Int, height: Int) -> CGFloat {
        let maxDim = CGFloat(max(width, height))
        switch self {
        case .fine:
            return max(4, (maxDim / 150).rounded())
        case .medium:
            return max(8, (maxDim / 80).rounded())
        case .coarse:
            return max(14, (maxDim / 44).rounded())
        }
    }
}

public struct NormalizedCropRect: Equatable, Codable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public static let full = NormalizedCropRect(x: 0, y: 0, width: 1, height: 1)

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isFull: Bool {
        abs(x) < 1e-4 && abs(y) < 1e-4 && abs(width - 1) < 1e-4 && abs(height - 1) < 1e-4
    }

    public func pixelRect(width imgW: Int, height imgH: Int) -> CGRect {
        let w = CGFloat(max(1, imgW))
        let h = CGFloat(max(1, imgH))
        let px = max(0, min(w - 1, (x * w).rounded()))
        let py = max(0, min(h - 1, (y * h).rounded()))
        let pw = max(1, min(w - px, (width * w).rounded()))
        let ph = max(1, min(h - py, (height * h).rounded()))
        return CGRect(x: px, y: py, width: pw, height: ph)
    }

    public func cgImageCroppingRect(width imgW: Int, height imgH: Int) -> CGRect {
        let pr = pixelRect(width: imgW, height: imgH)
        let topY = max(0, CGFloat(imgH) - pr.maxY)
        return CGRect(x: pr.minX, y: topY, width: pr.width, height: pr.height)
    }
}

public enum CropAspectPreset: String, CaseIterable, Identifiable, Sendable {
    case free
    case original
    case square
    case ratio4x3
    case ratio16x9

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .free: "自由"
        case .original: "原比例"
        case .square: "1:1"
        case .ratio4x3: "4:3"
        case .ratio16x9: "16:9"
        }
    }

    public func targetAspectRatio(originalWidth: Int, originalHeight: Int) -> CGFloat? {
        switch self {
        case .free:
            nil
        case .original:
            CGFloat(max(1, originalWidth)) / CGFloat(max(1, originalHeight))
        case .square:
            1.0
        case .ratio4x3:
            4.0 / 3.0
        case .ratio16x9:
            16.0 / 9.0
        }
    }
}

public enum ExportFormat: String, CaseIterable, Sendable {
    case png
    case jpeg

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }
}

public enum ZoomMode: Equatable, Sendable {
    case fit
    case custom(CGFloat)
}

public struct MosaicEffectSpec: Equatable, Hashable, Sendable {
    public let style: MosaicEffectStyle
    public let granularity: MosaicGranularity

    public init(style: MosaicEffectStyle, granularity: MosaicGranularity) {
        self.style = style
        self.granularity = granularity
    }
}

public struct MosaicStroke: Equatable, Sendable {
    public let tool: MosaicTool
    public let diameter: CGFloat
    public var points: [CGPoint]
    public let rect: CGRect?
    public let effectStyle: MosaicEffectStyle?
    public let granularity: MosaicGranularity?

    public init(
        tool: MosaicTool,
        diameter: CGFloat,
        points: [CGPoint] = [],
        rect: CGRect? = nil,
        effectStyle: MosaicEffectStyle? = nil,
        granularity: MosaicGranularity? = nil
    ) {
        self.tool = tool
        self.diameter = diameter
        self.points = points
        self.rect = rect
        self.effectStyle = effectStyle
        self.granularity = granularity
    }

    public init(
        tool: MosaicTool,
        rect: CGRect,
        effectStyle: MosaicEffectStyle? = nil,
        granularity: MosaicGranularity? = nil
    ) {
        self.tool = tool
        self.diameter = 0
        self.points = []
        self.rect = rect
        self.effectStyle = effectStyle
        self.granularity = granularity
    }

    public func resolvedEffectSpec(
        fallbackStyle: MosaicEffectStyle,
        fallbackGranularity: MosaicGranularity
    ) -> MosaicEffectSpec {
        MosaicEffectSpec(
            style: effectStyle ?? fallbackStyle,
            granularity: granularity ?? fallbackGranularity
        )
    }
}

public struct MosaicQueueItem: Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: URL?
    public var fileName: String
    public var strokes: [MosaicStroke]
    public var redoStack: [MosaicStroke]
    public var granularity: MosaicGranularity
    public var effectStyle: MosaicEffectStyle
    public var cropRect: NormalizedCropRect
    public var rotationQuarterTurns: Int
    public var isExported: Bool
    public var hasCustomFileName: Bool
    public var inMemoryImage: CGImage?
    public var thumbnail: CGImage?

    public var hasEdits: Bool {
        !strokes.isEmpty || !cropRect.isFull || rotationQuarterTurns != 0
    }

    public init(
        id: UUID = UUID(),
        sourceURL: URL? = nil,
        fileName: String,
        strokes: [MosaicStroke] = [],
        redoStack: [MosaicStroke] = [],
        granularity: MosaicGranularity = .medium,
        effectStyle: MosaicEffectStyle = .mosaic,
        cropRect: NormalizedCropRect = .full,
        rotationQuarterTurns: Int = 0,
        isExported: Bool = false,
        hasCustomFileName: Bool = false,
        inMemoryImage: CGImage? = nil,
        thumbnail: CGImage? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.strokes = strokes
        self.redoStack = redoStack
        self.granularity = granularity
        self.effectStyle = effectStyle
        self.cropRect = cropRect
        self.rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4
        self.isExported = isExported
        self.hasCustomFileName = hasCustomFileName
        self.inMemoryImage = inMemoryImage
        self.thumbnail = thumbnail
    }
}

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "白天模式"
        case .dark: "黑夜模式"
        }
    }

    public var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    public var next: AppAppearance {
        switch self {
        case .system: .light
        case .light: .dark
        case .dark: .system
        }
    }
}
