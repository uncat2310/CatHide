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
    public var previewEffectImages: [MosaicEffectSpec: CGImage] = [:]
    public var previewScale: CGFloat = 1.0
    public var sourceURL: URL?
    public var fileName: String = "猫猫藏藏"
    public var isRenamingTitle: Bool = false
    public var isEditingBrushSize: Bool = false
    public var isPointerOverFloatingControls: Bool = false
    public var isFilmstripExpandedWhileZoomed: Bool = false

    public var currentEffectSpec: MosaicEffectSpec {
        MosaicEffectSpec(style: effectStyle, granularity: granularity)
    }

    public var isEditingTextInput: Bool {
        isRenamingTitle || isEditingBrushSize
    }

    public var queue: [MosaicQueueItem] = []
    public var currentIndex: Int = 0

    public var tool: MosaicTool = .mosaic
    public var brushSize: CGFloat = 36
    public var granularity: MosaicGranularity = .medium
    public var effectStyle: MosaicEffectStyle = .blur
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

    /// 自动识别 results waiting for the user to confirm (boxes over the current page).
    public var suggestions: SuggestionSession?
    /// Long work in progress (recognising text, exporting a PDF); shown instead of the toast.
    public var busyMessage: String?
    /// Asks for a PDF's password: (file name, the previous try was wrong) → password, nil cancels.
    @ObservationIgnored
    public var pdfPasswordProvider: ((String, Bool) -> String?)?
    @ObservationIgnored
    private var cancelBusyRequested = false

    public struct SuggestionSession: Equatable, Sendable {
        public let itemID: UUID
        public var list: [PrivacySuggestion]
        /// Suggestions the user switched off (everything starts selected).
        public var off: Set<Int>
        /// For a PDF: also find and mask the other pages.
        public var wholeDocument: Bool

        public var pickedCount: Int { list.count - list.filter { off.contains($0.id) }.count }
        public var kinds: [PrivacyKind] {
            PrivacyKind.displayOrder.filter { k in list.contains { $0.kind == k } }
        }
        public func ids(of kind: PrivacyKind) -> [Int] { list.filter { $0.kind == kind }.map(\.id) }
    }

    private struct PreparedImageEntry: Sendable {
        let original: CGImage
        let previewOriginal: CGImage
        let previewScale: CGFloat
        var previewEffects: [MosaicEffectSpec: CGImage]
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

    public var currentItem: MosaicQueueItem? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    public var currentPDFPage: PDFPageRef? {
        currentItem?.pdfPage
    }

    /// Indices of the pages that belong to the same PDF as the current page.
    public var currentDocumentIndices: [Int] {
        guard let doc = currentPDFPage?.documentID else { return [] }
        return queue.indices.filter { queue[$0].pdfPage?.documentID == doc }
    }

    /// "3 / 12" for the pager (1-based position among this PDF's pages).
    public var pageNumber: (current: Int, total: Int)? {
        let pages = currentDocumentIndices
        guard let pos = pages.firstIndex(of: currentIndex) else { return nil }
        return (pos + 1, pages.count)
    }

    public var canSelectPreviousPage: Bool {
        guard let first = currentDocumentIndices.first else { return false }
        return currentIndex > first
    }

    public var canSelectNextPage: Bool {
        guard let last = currentDocumentIndices.last else { return false }
        return currentIndex < last
    }

    public func selectPreviousPage() {
        if currentPDFPage == nil { selectPrevious(); return }
        guard canSelectPreviousPage else { return }
        selectItem(at: currentIndex - 1)
    }

    public func selectNextPage() {
        if currentPDFPage == nil { selectNext(); return }
        guard canSelectNextPage else { return }
        selectItem(at: currentIndex + 1)
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
        !strokes.isEmpty && suggestions == nil
    }

    /// Committed strokes plus the selected suggestions (a preview until 应用).
    public var displayStrokes: [MosaicStroke] {
        guard let session = suggestions, let originalImage,
              queue.indices.contains(currentIndex), queue[currentIndex].id == session.itemID else {
            return strokes
        }
        let preview = session.list.filter { !session.off.contains($0.id) }.map {
            $0.stroke(imageWidth: originalImage.width, imageHeight: originalImage.height, style: effectStyle, granularity: granularity, group: -1)
        }
        return strokes + preview
    }

    public var canRedo: Bool {
        !redoStack.isEmpty && suggestions == nil
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
        // A PDF is renamed as a whole.
        let targets = currentPDFPage == nil ? [currentIndex] : currentDocumentIndices
        for idx in targets where queue.indices.contains(idx) {
            queue[idx].fileName = finalName
            queue[idx].hasCustomFileName = true
        }
        return true
    }

    public var brushDiameterInOriginalPixels: CGFloat {
        guard let originalImage else { return brushSize }
        let maxDim = CGFloat(max(originalImage.width, originalImage.height))
        return max(4, brushSize * (maxDim / 1000.0))
    }

    /// Images become one item each; a PDF one item per page (after asking for its password).
    private func makeQueueItems(from urls: [URL]) -> [MosaicQueueItem]? {
        let fileURLs = MosaicRenderer.collectImageURLs(from: urls)
        guard !fileURLs.isEmpty else {
            errorMessage = "所选内容中没有找到图片或 PDF 文件。"
            return nil
        }
        var items: [MosaicQueueItem] = []
        var problems: [String] = []
        for url in fileURLs {
            if PDFSupport.isPDF(url) {
                do {
                    let ask = pdfPasswordProvider ?? { _, _ in nil }
                    if let pages = try PDFSupport.openPages(url: url, granularity: granularity, effectStyle: effectStyle, askPassword: ask) {
                        items += pages
                    }
                } catch {
                    problems.append(error.localizedDescription)
                }
            } else {
                items.append(MosaicQueueItem(
                    sourceURL: url,
                    fileName: url.lastPathComponent,
                    granularity: granularity,
                    effectStyle: effectStyle
                ))
            }
        }
        if !problems.isEmpty {
            errorMessage = problems.joined(separator: "\n")
        }
        return items.isEmpty ? nil : items
    }

    public func loadImages(from urls: [URL]) {
        guard let items = makeQueueItems(from: urls) else { return }
        loadQueue(items)
    }

    public func appendImages(from urls: [URL]) {
        guard let items = makeQueueItems(from: urls) else { return }
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
        SensitiveDetector.warmUp()
        currentIndex = firstInsertedIndex
        activateItem(at: firstInsertedIndex)
        startThumbnailGeneration()
        startImagePreloading(around: firstInsertedIndex)
        showToast(items.allSatisfy({ $0.pdfPage != nil }) ? "已追加 \(items.count) 页" : "已追加 \(items.count) 项")
    }

    public func loadQueue(_ items: [MosaicQueueItem]) {
        guard !items.isEmpty else { return }
        thumbnailTask?.cancel()
        preloadTask?.cancel()
        clearPreparedImageCache()
        isCropping = false
        cropBackup = nil
        suggestions = nil
        PDFDocumentStore.shared.retain(only: Set(items.compactMap { $0.pdfPage?.documentID }))
        queue = items
        currentIndex = 0
        activateItem(at: 0)
        SensitiveDetector.warmUp()
        startThumbnailGeneration()
        startImagePreloading(around: 0)
        if items.count > 1 {
            let docs = Set(items.compactMap { $0.pdfPage?.documentID })
            let images = items.filter { $0.pdfPage == nil }.count
            if docs.count == 1 && images == 0 {
                showToast("已打开 PDF，共 \(items.count) 页")
            } else if docs.isEmpty {
                showToast("已导入 \(items.count) 张图片")
            } else {
                showToast("已导入 \(images) 张图片、\(docs.count) 个 PDF")
            }
        }
    }

    public func loadImage(_ cgImage: CGImage, fileName: String, sourceURL: URL? = nil) {
        thumbnailTask?.cancel()
        preloadTask?.cancel()
        clearPreparedImageCache()
        isCropping = false
        cropBackup = nil
        suggestions = nil
        PDFDocumentStore.shared.retain(only: [])
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
        SensitiveDetector.warmUp()
        let spec = MosaicEffectSpec(style: item.effectStyle, granularity: item.granularity)
        let entry = Self.makePreparedEntry(
            from: cgImage,
            specs: [spec],
            rotationQuarterTurns: item.rotationQuarterTurns
        )
        cachePreparedEntry(entry, for: item.id)
        applyPreparedEntry(entry, item: item)
    }

    private func startThumbnailGeneration() {
        let itemsSnapshot = queue.enumerated().compactMap { index, item -> (Int, UUID, URL?, CGImage?, PDFPageRef?)? in
            if item.thumbnail != nil { return nil }
            return (index, item.id, item.sourceURL, item.inMemoryImage, item.pdfPage)
        }
        guard !itemsSnapshot.isEmpty else { return }

        thumbnailTask = Task { @MainActor [weak self] in
            for (index, itemID, url, memImage, pdfPage) in itemsSnapshot {
                if Task.isCancelled { return }
                let thumb: CGImage? = await Task.detached(priority: .utility) {
                    if let pdfPage {
                        return PDFDocumentStore.shared.thumbnail(documentID: pdfPage.documentID, index: pdfPage.pageIndex)
                    }
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
        suggestions = nil
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
        if suggestions?.itemID == removed.id { suggestions = nil }
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
        PDFDocumentStore.shared.retain(only: Set(queue.compactMap { $0.pdfPage?.documentID }))
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

    private static func requiredSpecs(for item: MosaicQueueItem) -> Set<MosaicEffectSpec> {
        var specs: Set<MosaicEffectSpec> = [
            MosaicEffectSpec(style: item.effectStyle, granularity: item.granularity)
        ]
        for stroke in item.strokes where stroke.tool != .eraser {
            specs.insert(
                stroke.resolvedEffectSpec(
                    fallbackStyle: item.effectStyle,
                    fallbackGranularity: item.granularity
                )
            )
        }
        return specs
    }

    private func activateItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let item = queue[index]
        let neededSpecs = Self.requiredSpecs(for: item)
        do {
            let entry: PreparedImageEntry
            if var cached = preparedImageCache[item.id], cached.rotationQuarterTurns == item.rotationQuarterTurns {
                for spec in neededSpecs where cached.previewEffects[spec] == nil {
                    if let rendered = Self.makePreviewEffect(
                        original: cached.original,
                        previewOriginal: cached.previewOriginal,
                        previewScale: cached.previewScale,
                        granularity: spec.granularity,
                        style: spec.style
                    ) {
                        cached.previewEffects[spec] = rendered
                    }
                }
                cachePreparedEntry(cached, for: item.id)
                entry = cached
            } else {
                let rawImage = try Self.loadSourceImage(for: item)
                let cgImage = MosaicRenderer.rotateImage(rawImage, quarterTurns: item.rotationQuarterTurns)
                let built = Self.makePreparedEntry(
                    from: cgImage,
                    specs: neededSpecs,
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

    /// The item's pixels before rotation: the decoded image, or the PDF page rendered now.
    nonisolated private static func loadSourceImage(for item: MosaicQueueItem) throws -> CGImage {
        if let page = item.pdfPage {
            guard let rendered = PDFDocumentStore.shared.renderPage(documentID: page.documentID, index: page.pageIndex) else {
                throw MosaicRenderError.invalidImageFile
            }
            return rendered
        }
        if let inMemory = item.inMemoryImage {
            return inMemory
        }
        if let url = item.sourceURL {
            return try MosaicRenderer.loadOrientedImage(from: url)
        }
        throw MosaicRenderError.invalidImageFile
    }

    /// PDF pages are kept rendered only next to the shown page; images keep the larger cache.
    private func isKeptRendered(_ index: Int) -> Bool {
        guard queue.indices.contains(index) else { return false }
        return queue[index].pdfPage == nil || abs(index - currentIndex) <= 1
    }

    nonisolated private static func makePreparedEntry(
        from cgImage: CGImage,
        specs: Set<MosaicEffectSpec>,
        rotationQuarterTurns: Int
    ) -> PreparedImageEntry {
        let preview = MosaicRenderer.makePreviewImage(from: cgImage)
        var effects: [MosaicEffectSpec: CGImage] = [:]
        for spec in specs {
            if let effect = makePreviewEffect(
                original: cgImage,
                previewOriginal: preview.image,
                previewScale: preview.scale,
                granularity: spec.granularity,
                style: spec.style
            ) {
                effects[spec] = effect
            }
        }
        return PreparedImageEntry(
            original: cgImage,
            previewOriginal: preview.image,
            previewScale: preview.scale,
            previewEffects: effects,
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
            .filter { isKeptRendered($0) }
            .map { queue[$0] }
            .filter { preparedImageCache[$0.id] == nil }
            .prefix(max(0, maxCachedPreparedImages - 1))
            .map { ($0, Self.requiredSpecs(for: $0), $0.rotationQuarterTurns) }

        guard !candidates.isEmpty else { return }

        preloadTask = Task { @MainActor [weak self] in
            for (item, specs, turns) in candidates {
                if Task.isCancelled { return }
                let itemID = item.id
                let entry: PreparedImageEntry? = await Task.detached(priority: .utility) {
                    guard let rawImage = try? Self.loadSourceImage(for: item) else { return nil }
                    let oriented = MosaicRenderer.rotateImage(rawImage, quarterTurns: turns)
                    return Self.makePreparedEntry(
                        from: oriented,
                        specs: specs,
                        rotationQuarterTurns: turns
                    )
                }.value

                if Task.isCancelled { return }
                guard let self,
                      let idx = self.queue.firstIndex(where: { $0.id == itemID }),
                      self.isKeptRendered(idx),
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
        // Free PDF pages that are no longer next to the shown one.
        let far = Set(queue.indices.filter { !isKeptRendered($0) }.map { queue[$0].id })
        if !far.isEmpty {
            preparedImageOrder.removeAll { far.contains($0) && $0 != activeID }
            for key in preparedImageCache.keys where far.contains(key) && key != activeID {
                preparedImageCache.removeValue(forKey: key)
            }
        }
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
        self.previewEffectImages = entry.previewEffects
        self.previewScale = entry.previewScale
        self.sourceURL = item.sourceURL
        self.fileName = item.fileName
        self.isRenamingTitle = false
        self.isEditingBrushSize = false
        self.isComparingOriginal = false
        self.isFilmstripExpandedWhileZoomed = false
        self.granularity = item.granularity
        self.effectStyle = item.effectStyle
        self.previewMosaicImage = entry.previewEffects[MosaicEffectSpec(style: item.effectStyle, granularity: item.granularity)]
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

    /// One step back; strokes added together (one 自动识别 apply) go back together.
    public func undo() {
        guard suggestions == nil, let last = strokes.popLast() else { return }
        redoStack.append(last)
        if let group = last.group {
            while let prev = strokes.last, prev.group == group {
                redoStack.append(strokes.removeLast())
            }
        }
        maskRevision += 1
        syncCurrentQueueItem()
    }

    public func redo() {
        guard suggestions == nil, let next = redoStack.popLast() else { return }
        strokes.append(next)
        if let group = next.group {
            while let following = redoStack.last, following.group == group {
                strokes.append(redoStack.removeLast())
            }
        }
        maskRevision += 1
        syncCurrentQueueItem()
    }

    public func clearAll() {
        guard !strokes.isEmpty, suggestions == nil else { return }
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
        PDFDocumentStore.shared.retain(only: [])
        suggestions = nil
        cancelBusyRequested = true
        busyMessage = nil
        originalImage = nil
        previewOriginalImage = nil
        previewMosaicImage = nil
        previewEffectImages.removeAll()
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
        syncCurrentQueueItem(resetExportedIfChanged: false)
        previewMosaicImage = previewEffectImage(for: currentEffectSpec)
        if suggestions != nil { maskRevision += 1 }
    }

    public func setEffectStyle(_ newStyle: MosaicEffectStyle) {
        guard effectStyle != newStyle else { return }
        effectStyle = newStyle
        syncCurrentQueueItem(resetExportedIfChanged: false)
        previewMosaicImage = previewEffectImage(for: currentEffectSpec)
        if suggestions != nil { maskRevision += 1 }
    }

    @discardableResult
    public func previewEffectImage(for spec: MosaicEffectSpec) -> CGImage? {
        if let existing = previewEffectImages[spec] {
            return existing
        }
        guard let originalImage, let previewOriginalImage else { return nil }
        guard let generated = Self.makePreviewEffect(
            original: originalImage,
            previewOriginal: previewOriginalImage,
            previewScale: previewScale,
            granularity: spec.granularity,
            style: spec.style
        ) else {
            return nil
        }
        previewEffectImages[spec] = generated
        if queue.indices.contains(currentIndex) {
            let itemID = queue[currentIndex].id
            let updated = PreparedImageEntry(
                original: originalImage,
                previewOriginal: previewOriginalImage,
                previewScale: previewScale,
                previewEffects: previewEffectImages,
                rotationQuarterTurns: rotationQuarterTurns
            )
            cachePreparedEntry(updated, for: itemID)
        }
        return generated
    }

    /// PDF pages keep their page size, so they are not cropped or rotated.
    public var canCrop: Bool {
        hasImage && currentPDFPage == nil && suggestions == nil && busyMessage == nil
    }

    public func beginCrop() {
        guard canCrop, !isCropping else { return }
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
                rect: rotatedRect,
                effectStyle: stroke.effectStyle,
                granularity: stroke.granularity,
                group: stroke.group
            )
        }

        strokes = strokes.map(rotateStroke)
        redoStack = redoStack.map(rotateStroke)
        draftCropRect = CanvasNavigationMath.rotateNormalizedCropClockwise(draftCropRect)
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4

        let rotatedOriginal = MosaicRenderer.rotateImage(originalImage, quarterTurns: 1)
        var specs: Set<MosaicEffectSpec> = [currentEffectSpec]
        for stroke in strokes where stroke.tool != .eraser {
            specs.insert(stroke.resolvedEffectSpec(fallbackStyle: effectStyle, fallbackGranularity: granularity))
        }
        let entry = Self.makePreparedEntry(
            from: rotatedOriginal,
            specs: specs,
            rotationQuarterTurns: rotationQuarterTurns
        )

        self.originalImage = entry.original
        self.previewOriginalImage = entry.previewOriginal
        self.previewEffectImages = entry.previewEffects
        self.previewMosaicImage = entry.previewEffects[currentEffectSpec]
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
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let page = currentPDFPage {
            try exportPDF(documentID: page.documentID, to: url)
            return
        }
        guard let rendered = renderFinalImage() else {
            throw MosaicRenderError.failedToEncodeImage
        }
        let format: ExportFormat = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png
        guard let data = MosaicRenderer.encodeImage(
            rendered,
            format: format,
            stripMetadata: stripExifOnExport || currentPDFPage != nil,
            sourceMetadataURL: currentPDFPage == nil ? sourceURL : nil
        ) else {
            throw MosaicRenderError.failedToEncodeImage
        }
        try data.write(to: url, options: .atomic)

        if queue.indices.contains(currentIndex) {
            queue[currentIndex].isExported = true
        }
        finishExport(done: currentPDFPage == nil ? "已导出图片" : "已导出当前页")
    }

    /// After an export: move on to the next item that still needs exporting.
    private func finishExport(done: String) {
        guard isMultiImageMode else {
            showToast(done)
            return
        }
        let doc = currentPDFPage?.documentID
        let next = nextUnexportedIndex(after: currentIndex).flatMap { idx -> Int? in
            // Pages of a PDF just exported as a whole are done too.
            if let doc, queue[idx].pdfPage?.documentID == doc { return nil }
            return idx
        }
        if let next {
            selectItem(at: next)
            showToast("\(done)，已切换至下一项 (\(next + 1)/\(queue.count))")
        } else {
            showToast("\(done)（本批已全部完成）")
        }
    }

    /// The pages of one PDF in order, rasterised with their strokes, at their original size.
    private func renderedPDFPages(documentID: UUID) throws -> [(image: CGImage, size: CGSize)] {
        try queue.indices.filter { queue[$0].pdfPage?.documentID == documentID }.map { idx in
            let item = queue[idx]
            guard let page = item.pdfPage else { throw MosaicRenderError.failedToEncodeImage }
            let source: CGImage
            if idx == currentIndex, let originalImage {
                source = originalImage
            } else {
                source = try Self.loadSourceImage(for: item)
            }
            guard let rendered = MosaicRenderer.renderFinalImage(
                original: source,
                strokes: item.strokes,
                granularity: item.granularity,
                style: item.effectStyle
            ) else { throw MosaicRenderError.failedToEncodeImage }
            return (rendered, page.pageSize)
        }
    }

    /// Writes the whole PDF as pictures only, so masked text is gone from the file.
    public func exportPDF(documentID: UUID, to url: URL) throws {
        syncCurrentQueueItem(resetExportedIfChanged: false)
        let pages = try renderedPDFPages(documentID: documentID)
        guard !pages.isEmpty else { throw MosaicRenderError.failedToEncodeImage }
        try PDFSupport.writeImagePDF(pages: pages, to: url)
        for idx in queue.indices where queue[idx].pdfPage?.documentID == documentID {
            queue[idx].isExported = true
        }
        finishExport(done: "已导出 PDF（\(pages.count) 页）")
    }

    /// How many files a batch export writes: one per edited image, one per PDF with an edited page.
    public var batchExportCount: Int {
        var docs = Set<UUID>()
        var images = 0
        for item in queue where item.hasEdits {
            if let doc = item.pdfPage?.documentID { docs.insert(doc) } else { images += 1 }
        }
        return images + docs.count
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
        var exportedDocs = Set<UUID>()

        func outputURL(for item: MosaicQueueItem, ext: String) -> URL {
            let stem = ((item.fileName as NSString).deletingPathExtension).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanStem = stem.isEmpty ? "cathide" : stem
            let outputBase = item.hasCustomFileName ? cleanStem : "\(cleanStem)_cathide"
            return uniqueOutputURL(
                in: directoryURL,
                baseName: outputBase,
                fileExtension: ext,
                usedNames: &usedFileNames,
                fileManager: fm
            )
        }

        for idx in editedIndices {
            let item = queue[idx]
            // An edited PDF is written whole, as one PDF.
            if let page = item.pdfPage {
                guard exportedDocs.insert(page.documentID).inserted else { continue }
                let pages = try renderedPDFPages(documentID: page.documentID)
                try PDFSupport.writeImagePDF(pages: pages, to: outputURL(for: item, ext: "pdf"))
                for j in queue.indices where queue[j].pdfPage?.documentID == page.documentID {
                    queue[j].isExported = true
                }
                exportedCount += 1
                continue
            }

            let sourceCG: CGImage
            if idx == currentIndex, let originalImage {
                sourceCG = originalImage
            } else {
                sourceCG = MosaicRenderer.rotateImage(try Self.loadSourceImage(for: item), quarterTurns: item.rotationQuarterTurns)
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

            try encoded.write(to: outputURL(for: item, ext: format.fileExtension), options: .atomic)
            queue[idx].isExported = true
            exportedCount += 1
        }

        showToast(exportedDocs.isEmpty ? "已批量导出 \(exportedCount) 张图片" : "已批量导出 \(exportedCount) 个文件")
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
        suggestedExportFileName(fileExtension: format.fileExtension, wholePDF: false)
    }

    /// `wholePDF`: the name for the PDF itself; otherwise a single page gets "_p3" added.
    public func suggestedExportFileName(fileExtension: String, wholePDF: Bool) -> String {
        let isCustom = queue.indices.contains(currentIndex) && queue[currentIndex].hasCustomFileName
        let rawBase = isCustom ? fileName : (sourceURL?.lastPathComponent ?? fileName)
        let stem = (rawBase as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanBase = stem.isEmpty ? "cathide" : stem
        if !wholePDF, let page = pageNumber, page.total > 1 {
            cleanBase += "_p\(page.current)"
        }
        return isCustom
            ? "\(cleanBase).\(fileExtension)"
            : "\(cleanBase)_cathide.\(fileExtension)"
    }

    // MARK: - 自动识别

    public var canAutoDetect: Bool {
        hasImage && !isCropping && busyMessage == nil
    }

    /// Stops a long run (recognising the other pages of a PDF).
    public func cancelBusyWork() {
        cancelBusyRequested = true
    }

    /// Reads the current image and shows what looks sensitive as boxes to confirm.
    public func startAutoDetect() async {
        guard canAutoDetect, suggestions == nil, let image = originalImage,
              queue.indices.contains(currentIndex) else { return }
        let itemID = queue[currentIndex].id
        isComparingOriginal = false
        busyMessage = "正在识别敏感信息…"
        defer { busyMessage = nil }
        do {
            let found = try await Task.detached(priority: .userInitiated) {
                try SensitiveDetector.detect(in: image)
            }.value
            guard queue.indices.contains(currentIndex), queue[currentIndex].id == itemID else { return }
            // Only what is inside the crop.
            let visible = cropRect.isFull
                ? CGRect(x: 0, y: 0, width: image.width, height: image.height)
                : cropRect.pixelRect(width: image.width, height: image.height)
            let list = found.filter { $0.rect.intersects(visible) }
            if list.isEmpty {
                showToast("没有找到手机号、地址、证件号等敏感信息")
            } else {
                suggestions = SuggestionSession(itemID: itemID, list: list, off: [], wholeDocument: true)
                maskRevision += 1
            }
        } catch {
            showToast("识别失败：\(error.localizedDescription)")
        }
    }

    public func toggleSuggestions(_ ids: [Int], on: Bool) {
        guard var session = suggestions else { return }
        for id in ids {
            if on { session.off.remove(id) } else { session.off.insert(id) }
        }
        suggestions = session
        maskRevision += 1
    }

    public func setSuggestionsWholeDocument(_ on: Bool) {
        suggestions?.wholeDocument = on
    }

    public func cancelSuggestions() {
        guard suggestions != nil else { return }
        suggestions = nil
        maskRevision += 1
    }

    /// Masks the selected boxes in one undo step. For a PDF with 全部页面 on, the other pages are
    /// recognised too and masked the same way (kinds switched off here are skipped there).
    public func applySuggestions() async {
        guard let session = suggestions, let image = originalImage,
              queue.indices.contains(currentIndex), queue[currentIndex].id == session.itemID else { return }
        let group = Int(Date().timeIntervalSince1970 * 1000) & 0x7FFF_FFFF
        let style = effectStyle
        let gran = granularity
        let add = session.list.filter { !session.off.contains($0.id) }.map {
            $0.stroke(imageWidth: image.width, imageHeight: image.height, style: style, granularity: gran, group: group)
        }
        suggestions = nil
        if !add.isEmpty {
            strokes.append(contentsOf: add)
            redoStack.removeAll()
            syncCurrentQueueItem()
        }
        maskRevision += 1

        let others = session.wholeDocument
            ? currentDocumentIndices.filter { $0 != currentIndex }.map { queue[$0] }
            : []
        guard !others.isEmpty else {
            if !add.isEmpty { showToast("已打码 \(add.count) 处，撤销一次即可全部还原") }
            return
        }

        let skipped = Set(session.kinds.filter { k in session.list.allSatisfy { $0.kind != k || session.off.contains($0.id) } })
        cancelBusyRequested = false
        var pagesWithMasks = add.isEmpty ? 0 : 1
        var total = add.count
        var done = 0
        for item in others {
            if cancelBusyRequested { break }
            done += 1
            busyMessage = "正在识别其余页面 \(done)/\(others.count)…（Esc 停止）"
            let found: [PrivacySuggestion]
            let size: (Int, Int)
            do {
                (found, size) = try await Task.detached(priority: .userInitiated) {
                    let page = try Self.loadSourceImage(for: item)
                    return (try SensitiveDetector.detect(in: page), (page.width, page.height))
                }.value
            } catch {
                showToast("识别失败：\(error.localizedDescription)")
                break
            }
            guard let idx = queue.firstIndex(where: { $0.id == item.id }) else { continue }
            let pageStrokes = found.filter { !skipped.contains($0.kind) }.map {
                $0.stroke(imageWidth: size.0, imageHeight: size.1, style: style, granularity: gran, group: group)
            }
            guard !pageStrokes.isEmpty else { continue }
            queue[idx].strokes += pageStrokes
            queue[idx].redoStack.removeAll()
            queue[idx].isExported = false
            pagesWithMasks += 1
            total += pageStrokes.count
        }
        busyMessage = nil
        let stopped = cancelBusyRequested ? "已停止（识别了 \(done)/\(others.count) 页），" : ""
        cancelBusyRequested = false
        showToast(total > 0 ? "\(stopped)在 \(pagesWithMasks) 页中打码 \(total) 处，可以逐页检查" : "\(stopped)其余页面没有找到敏感信息")
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
