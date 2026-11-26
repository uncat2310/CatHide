import AppKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
public final class MosaicDocumentState {
    public static let minBrushSize: CGFloat = 8
    public static let maxBrushSize: CGFloat = 120
    private static let stripExifStorageKey = "catHide.stripExifOnExport"

    public var originalImage: CGImage?
    public var previewOriginalImage: CGImage?
    public var previewMosaicImage: CGImage?
    public var previewScale: CGFloat = 1.0
    public var sourceURL: URL?
    public var fileName: String = "猫猫藏藏"
    public var isRenamingTitle: Bool = false
    public var isEditingBrushSize: Bool = false
    public var isPointerOverFloatingControls: Bool = false
    public var isFilmstripExpandedWhileZoomed: Bool = false

    public var isEditingTextInput: Bool {
        isRenamingTitle || isEditingBrushSize
    }

    public var queue: [MosaicQueueItem] = []
    public var currentIndex: Int = 0

    public var tool: MosaicTool = .mosaic
    public var brushSize: CGFloat = 36
    public var granularity: MosaicGranularity = .medium
    public var effectStyle: MosaicEffectStyle = .mosaic
    public var cropRect: NormalizedCropRect = .full
    public var rotationQuarterTurns: Int = 0
    public var isCropping: Bool = false
    public var draftCropRect: NormalizedCropRect = .full
    public var cropAspectPreset: CropAspectPreset = .free
    public var isComparingOriginal: Bool = false
    public var stripExifOnExport: Bool {
        didSet {
            UserDefaults.standard.set(stripExifOnExport, forKey: Self.stripExifStorageKey)
        }
    }
    public var strokes: [MosaicStroke] = []
    public var redoStack: [MosaicStroke] = []
    public var zoomMode: ZoomMode = .fit
    public var maskRevision: Int = 0

    public var toastMessage: String?
    public var errorMessage: String?

    private struct PreparedImageEntry: Sendable {
        let original: CGImage
        let previewOriginal: CGImage
        let previewScale: CGFloat
        let previewMosaic: CGImage?
        let granularity: MosaicGranularity
        let effectStyle: MosaicEffectStyle
        let rotationQuarterTurns: Int
    }

    private struct CropBackup {
        let cropRect: NormalizedCropRect
        let rotationQuarterTurns: Int
        let strokes: [MosaicStroke]
        let redoStack: [MosaicStroke]
    }

    @ObservationIgnored
    private var toastTask: Task<Void, Never>?
    @ObservationIgnored
    private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored
    private var preloadTask: Task<Void, Never>?
    @ObservationIgnored
    private var preparedImageCache: [UUID: PreparedImageEntry] = [:]
    @ObservationIgnored
    private var preparedImageOrder: [UUID] = []
    @ObservationIgnored
    private var cropBackup: CropBackup?
    private let maxCachedPreparedImages = 12

    public init() {
        self.stripExifOnExport = UserDefaults.standard.object(forKey: Self.stripExifStorageKey) as? Bool ?? true
    }

    public var hasImage: Bool {
        originalImage != nil
    }

    public var isMultiImageMode: Bool {
        queue.count > 1
    }

    public var canSelectPrevious: Bool {
        isMultiImageMode && currentIndex > 0
    }

    public var canSelectNext: Bool {
        isMultiImageMode && currentIndex < queue.count - 1
    }

    public var modifiedCount: Int {
        queue.filter(\.hasEdits).count
    }

    public var unsavedCount: Int {
        queue.filter { $0.hasEdits && !$0.isExported }.count
    }

    public var hasUnsavedChanges: Bool {
        unsavedCount > 0
    }

    public var queuePositionText: String {
        guard !queue.isEmpty else { return "" }
        return "\(currentIndex + 1)/\(queue.count)"
    }

    public var canUndo: Bool {
        !strokes.isEmpty
    }

    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    public var imageDimensionsText: String {
        guard let originalImage else { return "" }
        if isCropping || cropRect.isFull {
            return "\(originalImage.width) × \(originalImage.height)"
        }
        let cropped = cropRect.pixelRect(width: originalImage.width, height: originalImage.height)
        return "\(Int(cropped.width)) × \(Int(cropped.height))"
    }

    public var currentFileStem: String {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.isEmpty ? fileName : stem
    }

    public var currentFileExtension: String {
        (fileName as NSString).pathExtension
    }

    @discardableResult
    public func renameCurrentImage(to rawName: String) -> Bool {
        let sanitized = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !sanitized.isEmpty else { return false }

        let existingExt = currentFileExtension
        let sanitizedExt = (sanitized as NSString).pathExtension
        let finalName: String
        if sanitizedExt.isEmpty && !existingExt.isEmpty {
            finalName = "\(sanitized).\(existingExt)"
        } else {
            finalName = sanitized
        }

        fileName = finalName
        if queue.indices.contains(currentIndex) {
            queue[currentIndex].fileName = finalName
            queue[currentIndex].hasCustomFileName = true
        }
        return true
    }

    public var brushDiameterInOriginalPixels: CGFloat {
        guard let originalImage else { return brushSize }
        let maxDim = CGFloat(max(originalImage.width, originalImage.height))
        return max(4, brushSize * (maxDim / 1000.0))
    }

    public func loadImages(from urls: [URL]) {
        let imageURLs = MosaicRenderer.collectImageURLs(from: urls)
        guard !imageURLs.isEmpty else {
            errorMessage = "所选内容中没有找到常见图片文件。"
            return
        }

        let items = imageURLs.map { url in
            MosaicQueueItem(
                sourceURL: url,
                fileName: url.lastPathComponent,
                granularity: granularity,
                effectStyle: effectStyle
            )
        }
        loadQueue(items)
    }

    public func appendImages(from urls: [URL]) {
        let imageURLs = MosaicRenderer.collectImageURLs(from: urls)
        guard !imageURLs.isEmpty else {
            errorMessage = "所选内容中没有找到常见图片文件。"
            return
        }

        let items = imageURLs.map { url in
            MosaicQueueItem(
                sourceURL: url,
                fileName: url.lastPathComponent,
                granularity: granularity,
                effectStyle: effectStyle
            )
        }
        appendQueueItems(items)
    }

    public func appendQueueItems(_ items: [MosaicQueueItem]) {
        guard !items.isEmpty else { return }
        guard hasImage || !queue.isEmpty else {
            loadQueue(items)
            return
        }
        syncCurrentQueueItem(resetExportedIfChanged: false)
        let firstInsertedIndex = queue.count
        queue.append(contentsOf: items)
        currentIndex = firstInsertedIndex
        activateItem(at: firstInsertedIndex)
        startThumbnailGeneration()
        startImagePreloading(around: firstInsertedIndex)
        showToast("已追加 \(items.count) 张图片")
    }

    public func loadQueue(_ items: [MosaicQueueItem]) {
        guard !items.isEmpty else { return }
        thumbnailTask?.cancel()
        preloadTask?.cancel()
        clearPreparedImageCache()
        isCropping = false
        cropBackup = nil
        queue = items
        currentIndex = 0
        activateItem(at: 0)
        startThumbnailGeneration()
        startImagePreloading(around: 0)
        if items.count > 1 {
            showToast("已导入 \(items.count) 张图片")
        }
    }

    public func loadImage(_ cgImage: CGImage, fileName: String, sourceURL: URL? = nil) {
        thumbnailTask?.cancel()
        preloadTask?.cancel()
        clearPreparedImageCache()
        isCropping = false
        cropBackup = nil
        let thumb = MosaicRenderer.makeThumbnail(from: cgImage)
        let item = MosaicQueueItem(
            sourceURL: sourceURL,
            fileName: fileName,
            granularity: granularity,
            effectStyle: effectStyle,
            inMemoryImage: sourceURL == nil ? cgImage : nil,
            thumbnail: thumb
        )
        queue = [item]
        currentIndex = 0
        let entry = Self.makePreparedEntry(
            from: cgImage,
            granularity: item.granularity,
            effectStyle: item.effectStyle,
            rotationQuarterTurns: item.rotationQuarterTurns
        )
        cachePreparedEntry(entry, for: item.id)
        applyPreparedEntry(entry, item: item)
    }

    private func startThumbnailGeneration() {
        let itemsSnapshot = queue.enumerated().compactMap { index, item -> (Int, UUID, URL?, CGImage?)? in
            if item.thumbnail != nil { return nil }
            return (index, item.id, item.sourceURL, item.inMemoryImage)
        }
        guard !itemsSnapshot.isEmpty else { return }

        thumbnailTask = Task { @MainActor [weak self] in
            for (index, itemID, url, memImage) in itemsSnapshot {
                if Task.isCancelled { return }
                let thumb: CGImage? = await Task.detached(priority: .utility) {
                    if let memImage {
                        return MosaicRenderer.makeThumbnail(from: memImage)
                    }
                    if let url {
                        return MosaicRenderer.makeThumbnail(from: url)
                    }
                    return nil
                }.value

                if Task.isCancelled { return }
                guard let self,
                      self.queue.indices.contains(index),
                      self.queue[index].id == itemID else { continue }
                if let thumb {
                    self.queue[index].thumbnail = thumb
                }
            }
        }
    }

    public func selectItem(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        syncCurrentQueueItem(resetExportedIfChanged: false)
        currentIndex = index
        activateItem(at: index)
        startImagePreloading(around: index)
    }

    public func selectPrevious() {
        guard canSelectPrevious else { return }
        selectItem(at: currentIndex - 1)
    }

    public func selectNext() {
        guard canSelectNext else { return }
        selectItem(at: currentIndex + 1)
    }

    public func removeItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        if queue.count == 1 {
            closeAllImages()
            return
        }

        let removed = queue[index]
        preparedImageCache.removeValue(forKey: removed.id)
        preparedImageOrder.removeAll { $0 == removed.id }

        if index == currentIndex {
            syncCurrentQueueItem(resetExportedIfChanged: false)
        }

        let wasCurrent = index == currentIndex
        queue.remove(at: index)

        if index < currentIndex {
            currentIndex -= 1
        } else if currentIndex >= queue.count {
            currentIndex = queue.count - 1
        }

        if wasCurrent {
            isCropping = false
            cropBackup = nil
            activateItem(at: currentIndex)
            startImagePreloading(around: currentIndex)
        }
        showToast("已从列表移除")
    }

    public func nextUnexportedIndex(after index: Int) -> Int? {
        guard queue.count > 1 else { return nil }
        for idx in (index + 1)..<queue.count where !queue[idx].isExported {
            return idx
        }
        for idx in 0..<index where !queue[idx].isExported {
            return idx
        }
        return nil
    }

    private func activateItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let item = queue[index]
        do {
            let entry: PreparedImageEntry
            if let cached = preparedImageCache[item.id], cached.rotationQuarterTurns == item.rotationQuarterTurns {
                if cached.granularity == item.granularity && cached.effectStyle == item.effectStyle {
                    entry = cached
                } else {
                    let mosaic = Self.makePreviewEffect(
                        original: cached.original,
                        previewOriginal: cached.previewOriginal,
                        previewScale: cached.previewScale,
                        granularity: item.granularity,
                        style: item.effectStyle
                    )
                    let updated = PreparedImageEntry(
                        original: cached.original,
                        previewOriginal: cached.previewOriginal,
                        previewScale: cached.previewScale,
                        previewMosaic: mosaic,
                        granularity: item.granularity,
                        effectStyle: item.effectStyle,
                        rotationQuarterTurns: item.rotationQuarterTurns
                    )
                    cachePreparedEntry(updated, for: item.id)
                    entry = updated
                }
            } else {
                let rawImage: CGImage
                if let inMemory = item.inMemoryImage {
                    rawImage = inMemory
                } else if let url = item.sourceURL {
                    rawImage = try MosaicRenderer.loadOrientedImage(from: url)
                } else {
                    throw MosaicRenderError.invalidImageFile
                }
                let cgImage = MosaicRenderer.rotateImage(rawImage, quarterTurns: item.rotationQuarterTurns)
                let built = Self.makePreparedEntry(
                    from: cgImage,
                    granularity: item.granularity,
                    effectStyle: item.effectStyle,
                    rotationQuarterTurns: item.rotationQuarterTurns
                )
                cachePreparedEntry(built, for: item.id)
                entry = built
            }
            applyPreparedEntry(entry, item: item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated private static func makePreparedEntry(
        from cgImage: CGImage,
        granularity: MosaicGranularity,
        effectStyle: MosaicEffectStyle,
        rotationQuarterTurns: Int
    ) -> PreparedImageEntry {
        let preview = MosaicRenderer.makePreviewImage(from: cgImage)
        let mosaic = makePreviewEffect(
            original: cgImage,
            previewOriginal: preview.image,
            previewScale: preview.scale,
            granularity: granularity,
            style: effectStyle
        )
        return PreparedImageEntry(
            original: cgImage,
            previewOriginal: preview.image,
            previewScale: preview.scale,
            previewMosaic: mosaic,
            granularity: granularity,
            effectStyle: effectStyle,
            rotationQuarterTurns: rotationQuarterTurns
        )
    }

    nonisolated private static func makePreviewEffect(
        original: CGImage,
        previewOriginal: CGImage,
        previewScale: CGFloat,
        granularity: MosaicGranularity,
        style: MosaicEffectStyle
    ) -> CGImage? {
        MosaicRenderer.makeEffectImage(
            from: previewOriginal,
            style: style,
            granularity: granularity,
            originalWidth: original.width,
            originalHeight: original.height,
            previewScale: previewScale
        )
    }

    private func startImagePreloading(around centerIndex: Int) {
        preloadTask?.cancel()
        guard queue.count > 1 else { return }

        var candidateIndices: [Int] = []
        let maxRadius = queue.count - 1
        for offset in 1...maxRadius {
            let right = centerIndex + offset
            if right < queue.count {
                candidateIndices.append(right)
            }
            let left = centerIndex - offset
            if left >= 0 {
                candidateIndices.append(left)
            }
        }

        let candidates = candidateIndices
            .map { queue[$0] }
            .filter { preparedImageCache[$0.id] == nil }
            .prefix(max(0, maxCachedPreparedImages - 1))
            .map { ($0.id, $0.sourceURL, $0.inMemoryImage, $0.granularity, $0.effectStyle, $0.rotationQuarterTurns) }

        guard !candidates.isEmpty else { return }

        preloadTask = Task { @MainActor [weak self] in
            for (itemID, url, memImage, granularity, style, turns) in candidates {
                if Task.isCancelled { return }
                let entry: PreparedImageEntry? = await Task.detached(priority: .utility) {
                    let rawImage: CGImage?
                    if let memImage {
                        rawImage = memImage
                    } else if let url {
                        rawImage = try? MosaicRenderer.loadOrientedImage(from: url)
                    } else {
                        rawImage = nil
                    }
                    guard let rawImage else { return nil }
                    let oriented = MosaicRenderer.rotateImage(rawImage, quarterTurns: turns)
                    return Self.makePreparedEntry(
                        from: oriented,
                        granularity: granularity,
                        effectStyle: style,
                        rotationQuarterTurns: turns
                    )
                }.value

                if Task.isCancelled { return }
                guard let self,
                      self.queue.contains(where: { $0.id == itemID }),
                      self.preparedImageCache[itemID] == nil,
                      let entry else { continue }
                self.cachePreparedEntry(entry, for: itemID)
            }
        }
    }

    private func cachePreparedEntry(_ entry: PreparedImageEntry, for id: UUID) {
        preparedImageCache[id] = entry
        if let existingIndex = preparedImageOrder.firstIndex(of: id) {
            preparedImageOrder.remove(at: existingIndex)
        }
        preparedImageOrder.append(id)

        let activeID = queue.indices.contains(currentIndex) ? queue[currentIndex].id : nil
        while preparedImageOrder.count > maxCachedPreparedImages {
            if let evictIndex = preparedImageOrder.firstIndex(where: { $0 != activeID }) {
                let evictedID = preparedImageOrder.remove(at: evictIndex)
                preparedImageCache.removeValue(forKey: evictedID)
            } else {
                break
            }
        }
    }

    private func clearPreparedImageCache() {
        preparedImageCache.removeAll()
        preparedImageOrder.removeAll()
    }

    private func applyPreparedEntry(_ entry: PreparedImageEntry, item: MosaicQueueItem) {
        self.originalImage = entry.original
        self.previewOriginalImage = entry.previewOriginal
        self.previewMosaicImage = entry.previewMosaic
        self.previewScale = entry.previewScale
        self.sourceURL = item.sourceURL
        self.fileName = item.fileName
        self.isRenamingTitle = false
        self.isEditingBrushSize = false
        self.isComparingOriginal = false
        self.isFilmstripExpandedWhileZoomed = false
        self.granularity = item.granularity
        self.effectStyle = item.effectStyle
        self.cropRect = item.cropRect
        self.rotationQuarterTurns = item.rotationQuarterTurns
        self.draftCropRect = item.cropRect
        self.strokes = item.strokes
        self.redoStack = item.redoStack
        self.zoomMode = .fit
        self.errorMessage = nil
        self.maskRevision += 1
    }

    private func syncCurrentQueueItem(resetExportedIfChanged: Bool = true) {
        guard queue.indices.contains(currentIndex) else { return }
        queue[currentIndex].strokes = strokes
        queue[currentIndex].redoStack = redoStack
        queue[currentIndex].granularity = granularity
        queue[currentIndex].effectStyle = effectStyle
        queue[currentIndex].cropRect = cropRect
        queue[currentIndex].rotationQuarterTurns = rotationQuarterTurns
        if resetExportedIfChanged {
            queue[currentIndex].isExported = false
        }
    }

    @discardableResult
    public func pasteFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            let imageURLs = MosaicRenderer.collectImageURLs(from: urls)
            if !imageURLs.isEmpty {
                loadImages(from: imageURLs)
                if imageURLs.count == 1 {
                    showToast("已导入粘贴的图片")
                }
                return true
            }
        }

        let preferredTypes: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"),
            (.tiff, "png"),
            (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
            (NSPasteboard.PasteboardType("public.heic"), "heic")
        ]
        for (type, ext) in preferredTypes {
            if let data = pasteboard.data(forType: type),
               let cgImage = MosaicRenderer.loadOrientedImage(from: data) {
                let name = MosaicRenderer.resolvedImageFileName(suggestedName: nil, preferredExtension: ext)
                loadImage(cgImage, fileName: name)
                showToast("已粘贴剪贴板图片")
                return true
            }
        }

        if let nsImage = NSImage(pasteboard: pasteboard),
           let cgImage = MosaicRenderer.normalizeImage(nsImage) {
            let name = MosaicRenderer.resolvedImageFileName(suggestedName: nil, preferredExtension: "png")
            loadImage(cgImage, fileName: name)
            showToast("已粘贴剪贴板图片")
            return true
        }

        showToast("剪贴板中没有可用图片")
        return false
    }

    public func commitStroke(_ stroke: MosaicStroke) {
        guard !stroke.points.isEmpty || stroke.rect != nil else { return }
        strokes.append(stroke)
        redoStack.removeAll()
        syncCurrentQueueItem()
    }

    public func undo() {
        guard let last = strokes.popLast() else { return }
        redoStack.append(last)
        maskRevision += 1
        syncCurrentQueueItem()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        strokes.append(next)
        maskRevision += 1
        syncCurrentQueueItem()
    }

    public func clearAll() {
        guard !strokes.isEmpty else { return }
        strokes.removeAll()
        redoStack.removeAll()
        maskRevision += 1
        syncCurrentQueueItem()
        showToast("已清空所有打码")
    }

    public func closeAllImages() {
        guard hasImage || !queue.isEmpty else { return }
        thumbnailTask?.cancel()
        thumbnailTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        clearPreparedImageCache()
        originalImage = nil
        previewOriginalImage = nil
        previewMosaicImage = nil
        previewScale = 1.0
        sourceURL = nil
        fileName = "猫猫藏藏"
        isRenamingTitle = false
        isEditingBrushSize = false
        isPointerOverFloatingControls = false
        isFilmstripExpandedWhileZoomed = false
        isCropping = false
        cropBackup = nil
        cropRect = .full
        draftCropRect = .full
        cropAspectPreset = .free
        rotationQuarterTurns = 0
        isComparingOriginal = false
        queue.removeAll()
        currentIndex = 0
        strokes.removeAll()
        redoStack.removeAll()
        zoomMode = .fit
        errorMessage = nil
        maskRevision += 1
    }

    public func setGranularity(_ newGranularity: MosaicGranularity) {
        guard granularity != newGranularity else { return }
        granularity = newGranularity
        syncCurrentQueueItem()
        rebuildPreviewEffectLayer()
    }

    public func setEffectStyle(_ newStyle: MosaicEffectStyle) {
        guard effectStyle != newStyle else { return }
        effectStyle = newStyle
        syncCurrentQueueItem()
        rebuildPreviewEffectLayer()
    }

    private func rebuildPreviewEffectLayer() {
        guard let originalImage, let previewOriginalImage else { return }
        let newEffect = Self.makePreviewEffect(
            original: originalImage,
            previewOriginal: previewOriginalImage,
            previewScale: previewScale,
            granularity: granularity,
            style: effectStyle
        )
        previewMosaicImage = newEffect
        if queue.indices.contains(currentIndex) {
            let itemID = queue[currentIndex].id
            let updated = PreparedImageEntry(
                original: originalImage,
                previewOriginal: previewOriginalImage,
                previewScale: previewScale,
                previewMosaic: newEffect,
                granularity: granularity,
                effectStyle: effectStyle,
                rotationQuarterTurns: rotationQuarterTurns
            )
            cachePreparedEntry(updated, for: itemID)
        }
    }

    public func beginCrop() {
        guard hasImage, !isCropping else { return }
        cropBackup = CropBackup(
            cropRect: cropRect,
            rotationQuarterTurns: rotationQuarterTurns,
            strokes: strokes,
            redoStack: redoStack
        )
        draftCropRect = cropRect
        cropAspectPreset = .free
        zoomMode = .fit
        isFilmstripExpandedWhileZoomed = false
        isCropping = true
    }

    public func setCropAspectPreset(_ preset: CropAspectPreset) {
        cropAspectPreset = preset
        guard let originalImage,
              let ratio = preset.targetAspectRatio(
                originalWidth: originalImage.width,
                originalHeight: originalImage.height
              ) else {
            return
        }
        draftCropRect = CanvasNavigationMath.fittedCropRect(
            within: .full,
            aspectRatio: ratio,
            imageWidth: CGFloat(originalImage.width),
            imageHeight: CGFloat(originalImage.height)
        )
    }

    public func resetDraftCrop() {
        draftCropRect = .full
        cropAspectPreset = .free
    }

    public func rotateClockwiseInCrop() {
        guard let originalImage else { return }
        let oldW = CGFloat(originalImage.width)
        let oldH = CGFloat(originalImage.height)

        func rotateStroke(_ stroke: MosaicStroke) -> MosaicStroke {
            let rotatedPoints = stroke.points.map {
                CanvasNavigationMath.rotatePointClockwise($0, originalWidth: oldW, originalHeight: oldH)
            }
            let rotatedRect = stroke.rect.map {
                CanvasNavigationMath.rotateRectClockwise($0, originalWidth: oldW, originalHeight: oldH)
            }
            return MosaicStroke(
                tool: stroke.tool,
                diameter: stroke.diameter,
                points: rotatedPoints,
                rect: rotatedRect
            )
        }

        strokes = strokes.map(rotateStroke)
        redoStack = redoStack.map(rotateStroke)
        draftCropRect = CanvasNavigationMath.rotateNormalizedCropClockwise(draftCropRect)
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4

        let rotatedOriginal = MosaicRenderer.rotateImage(originalImage, quarterTurns: 1)
        let entry = Self.makePreparedEntry(
            from: rotatedOriginal,
            granularity: granularity,
            effectStyle: effectStyle,
            rotationQuarterTurns: rotationQuarterTurns
        )

        self.originalImage = entry.original
        self.previewOriginalImage = entry.previewOriginal
        self.previewMosaicImage = entry.previewMosaic
        self.previewScale = entry.previewScale
        self.maskRevision += 1
        self.zoomMode = .fit

        if queue.indices.contains(currentIndex) {
            let itemID = queue[currentIndex].id
            cachePreparedEntry(entry, for: itemID)
            queue[currentIndex].thumbnail = MosaicRenderer.makeThumbnail(from: entry.previewOriginal)
            syncCurrentQueueItem()
        }
    }

    public func applyCrop() {
        guard isCropping else { return }
        let changed = draftCropRect != cropRect
        cropRect = draftCropRect
        isCropping = false
        cropBackup = nil
        zoomMode = .fit
        syncCurrentQueueItem(resetExportedIfChanged: changed)
        showToast("已应用裁剪")
    }

    public func cancelCrop() {
        guard isCropping else { return }
        if let backup = cropBackup {
            cropRect = backup.cropRect
            strokes = backup.strokes
            redoStack = backup.redoStack
            let rotationChanged = rotationQuarterTurns != backup.rotationQuarterTurns
            rotationQuarterTurns = backup.rotationQuarterTurns
            if queue.indices.contains(currentIndex) {
                queue[currentIndex].cropRect = backup.cropRect
                queue[currentIndex].rotationQuarterTurns = backup.rotationQuarterTurns
                queue[currentIndex].strokes = backup.strokes
                queue[currentIndex].redoStack = backup.redoStack
                if rotationChanged {
                    preparedImageCache.removeValue(forKey: queue[currentIndex].id)
                    activateItem(at: currentIndex)
                    if let currentOrig = self.previewOriginalImage {
                        queue[currentIndex].thumbnail = MosaicRenderer.makeThumbnail(from: currentOrig)
                    }
                }
            }
            maskRevision += 1
        }
        cropBackup = nil
        isCropping = false
        zoomMode = .fit
    }

    public func adjustBrushSize(by delta: CGFloat) {
        brushSize = min(Self.maxBrushSize, max(Self.minBrushSize, brushSize + delta))
    }

    @discardableResult
    public func setBrushSize(fromInput text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let parsed = Double(trimmed),
              parsed.isFinite else {
            return false
        }
        let rounded = CGFloat(parsed.rounded())
        brushSize = min(Self.maxBrushSize, max(Self.minBrushSize, rounded))
        return true
    }

    public func zoomIn(currentScale: CGFloat) {
        let base = switch zoomMode {
        case .fit: currentScale
        case .custom(let value): value
        }
        zoomMode = .custom(min(8.0, base * 1.25))
    }

    public func zoomOut(currentScale: CGFloat) {
        let base = switch zoomMode {
        case .fit: currentScale
        case .custom(let value): value
        }
        zoomMode = .custom(max(0.1, base / 1.25))
    }

    public func zoomFit() {
        zoomMode = .fit
    }

    public func zoomActualSize() {
        zoomMode = .custom(1.0)
    }

    public func renderFinalImage() -> CGImage? {
        guard let originalImage else { return nil }
        return MosaicRenderer.renderFinalImage(
            original: originalImage,
            strokes: strokes,
            granularity: granularity,
            style: effectStyle,
            cropRect: cropRect
        )
    }

    @discardableResult
    public func copyToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard let rendered = renderFinalImage(),
              let pngData = MosaicRenderer.encodeImage(rendered, format: .png, stripMetadata: true) else {
            return false
        }
        let nsImage = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        if let tiffData = nsImage.tiffRepresentation {
            pasteboard.setData(tiffData, forType: .tiff)
        }
        showToast("已复制到剪贴板")
        return true
    }

    public func exportImage(to url: URL) throws {
        guard let rendered = renderFinalImage() else {
            throw MosaicRenderError.failedToEncodeImage
        }
        let ext = url.pathExtension.lowercased()
        let format: ExportFormat = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png
        guard let data = MosaicRenderer.encodeImage(
            rendered,
            format: format,
            stripMetadata: stripExifOnExport,
            sourceMetadataURL: sourceURL
        ) else {
            throw MosaicRenderError.failedToEncodeImage
        }
        try data.write(to: url, options: .atomic)

        if queue.indices.contains(currentIndex) {
            queue[currentIndex].isExported = true
        }

        if isMultiImageMode {
            if let nextIndex = nextUnexportedIndex(after: currentIndex) {
                selectItem(at: nextIndex)
                showToast("已导出，已切换至下一张 (\(nextIndex + 1)/\(queue.count))")
            } else {
                showToast("已导出（本批图片已全部完成）")
            }
        } else {
            showToast("已导出图片")
        }
    }

    @discardableResult
    public func batchExportModified(to directoryURL: URL, format: ExportFormat = .png) throws -> Int {
        syncCurrentQueueItem(resetExportedIfChanged: false)
        let editedIndices = queue.indices.filter { queue[$0].hasEdits }
        guard !editedIndices.isEmpty else {
            showToast("当前没有已打码或编辑过的图片")
            return 0
        }

        let fm = FileManager.default
        var usedFileNames = Set<String>()
        var exportedCount = 0

        for idx in editedIndices {
            let item = queue[idx]
            let sourceCG: CGImage
            if idx == currentIndex, let originalImage {
                sourceCG = originalImage
            } else if let inMemory = item.inMemoryImage {
                sourceCG = MosaicRenderer.rotateImage(inMemory, quarterTurns: item.rotationQuarterTurns)
            } else if let sourceURL = item.sourceURL {
                let raw = try MosaicRenderer.loadOrientedImage(from: sourceURL)
                sourceCG = MosaicRenderer.rotateImage(raw, quarterTurns: item.rotationQuarterTurns)
            } else {
                continue
            }

            guard let rendered = MosaicRenderer.renderFinalImage(
                original: sourceCG,
                strokes: item.strokes,
                granularity: item.granularity,
                style: item.effectStyle,
                cropRect: item.cropRect
            ), let encoded = MosaicRenderer.encodeImage(
                rendered,
                format: format,
                stripMetadata: stripExifOnExport,
                sourceMetadataURL: item.sourceURL
            ) else {
                throw MosaicRenderError.failedToEncodeImage
            }

            let stem = ((item.fileName as NSString).deletingPathExtension).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanStem = stem.isEmpty ? "cathide" : stem
            let outputBase = item.hasCustomFileName ? cleanStem : "\(cleanStem)_cathide"
            let targetURL = uniqueOutputURL(
                in: directoryURL,
                baseName: outputBase,
                fileExtension: format.fileExtension,
                usedNames: &usedFileNames,
                fileManager: fm
            )
            try encoded.write(to: targetURL, options: .atomic)
            queue[idx].isExported = true
            exportedCount += 1
        }

        showToast("已批量导出 \(exportedCount) 张图片")
        return exportedCount
    }

    private func uniqueOutputURL(
        in directory: URL,
        baseName: String,
        fileExtension: String,
        usedNames: inout Set<String>,
        fileManager: FileManager
    ) -> URL {
        var suffixIndex = 1
        while true {
            let candidateName = suffixIndex == 1
                ? "\(baseName).\(fileExtension)"
                : "\(baseName)_\(suffixIndex).\(fileExtension)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            if !usedNames.contains(candidateName) && !fileManager.fileExists(atPath: candidateURL.path) {
                usedNames.insert(candidateName)
                return candidateURL
            }
            suffixIndex += 1
        }
    }

    public func suggestedExportFileName(format: ExportFormat = .png) -> String {
        let isCustom = queue.indices.contains(currentIndex) && queue[currentIndex].hasCustomFileName
        let rawBase = isCustom ? fileName : (sourceURL?.lastPathComponent ?? fileName)
        let stem = (rawBase as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBase = stem.isEmpty ? "cathide" : stem
        return isCustom
            ? "\(cleanBase).\(format.fileExtension)"
            : "\(cleanBase)_cathide.\(format.fileExtension)"
    }

    public func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }
}
