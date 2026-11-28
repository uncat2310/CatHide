import AppKit
import MosaicCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var state: MosaicDocumentState
    var shortcutStore: ShortcutStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("catHide.suppressLaunchGuide") private var suppressLaunchGuide = false
    @AppStorage("catHide.appearance") private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage("catHide.lastExportFormat") private var lastExportFormatRaw = ExportFormat.png.rawValue
    @State private var currentFitScale: CGFloat = 1.0
    @State private var isDropTargeted = false
    @State private var showGuideSheet = false
    @State private var isLaunchGuide = false
    @State private var hasHandledInitialAppear = false
    @State private var isHoveringBottomControls = false
    @State private var isScrubbingZoom = false

    @State private var showUnsavedCloseAlert = false
    @State private var showDropChoiceDialog = false
    @State private var pendingDropURLs: [URL] = []
    @State private var pendingDropItems: [MosaicQueueItem] = []

    @State private var showUpdateAlert = false
    @State private var updateAlertTitle = ""
    @State private var updateAlertMessage = ""
    @State private var updateReleaseURL: URL?

    private static let lastExportDirectoryKey = "catHide.lastExportDirectory"

    private var currentAppearance: AppAppearance {
        AppAppearance(rawValue: appearanceRawValue) ?? .system
    }

    private var preferredExportFormat: ExportFormat {
        ExportFormat(rawValue: lastExportFormatRaw) ?? .png
    }

    private var zoomLabel: String {
        switch state.zoomMode {
        case .fit:
            return "适应"
        case .custom(let value):
            return "\(Int((value * 100).rounded()))%"
        }
    }

    private var currentDisplayedScale: CGFloat {
        switch state.zoomMode {
        case .fit:
            return currentFitScale
        case .custom(let value):
            return value
        }
    }

    private var isZoomedBeyondFit: Bool {
        state.isMultiImageMode
            && !state.isCropping
            && state.zoomMode != .fit
            && currentDisplayedScale > currentFitScale * 1.04
    }

    private var showsExpandedFilmstrip: Bool {
        state.isMultiImageMode && !state.isCropping && (!isZoomedBeyondFit || state.isFilmstripExpandedWhileZoomed)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if state.hasImage {
                    MosaicCanvasView(state: state, currentFitScale: $currentFitScale)
                        .clipped()
                        .ignoresSafeArea(.container, edges: .top)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyDropView
                        .ignoresSafeArea(.container, edges: .top)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                FloatingGlassGroup(spacing: 10) {
                    VStack(spacing: 2) {
                        if let busy = state.busyMessage {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(busy)
                                    .font(.callout.weight(.medium))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .floatingGlassCapsule()
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else if let toast = state.toastMessage {
                            Text(toast)
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .floatingGlassCapsule()
                                .padding(.bottom, 8)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .allowsHitTesting(false)
                        }

                        if state.hasImage {
                            if state.isCropping {
                                floatingCropPill
                            } else if let session = state.suggestions {
                                SuggestionPill(state: state, session: session)
                            } else {
                                floatingControlPill
                            }
                        }

                        if state.isMultiImageMode && !state.isCropping {
                            if isZoomedBeyondFit && !state.isFilmstripExpandedWhileZoomed {
                                CollapsedFilmstripPill(positionText: state.queuePositionText) {
                                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                                        state.isFilmstripExpandedWhileZoomed = true
                                    }
                                }
                                .padding(.top, 6)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                            } else {
                                FilmstripBarView(
                                    state: state,
                                    shortcutStore: shortcutStore,
                                    useGlassDock: isZoomedBeyondFit,
                                    onCollapse: isZoomedBeyondFit ? {
                                        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                                            state.isFilmstripExpandedWhileZoomed = false
                                        }
                                    } : nil
                                )
                                .padding(.top, isZoomedBeyondFit ? 6 : 0)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, showsExpandedFilmstrip ? 6 : (state.hasImage ? 14 : 24))
                .animation(.spring(response: 0.24, dampingFraction: 0.84), value: showsExpandedFilmstrip)
                .onHover { hovering in
                    isHoveringBottomControls = hovering
                    state.isPointerOverFloatingControls = hovering || isScrubbingZoom
                }
            }
            .overlay {
                if isDropTargeted && state.hasImage {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.toastMessage)
        .animation(.easeOut(duration: 0.18), value: state.busyMessage)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: state.suggestions != nil)
        .onChange(of: isZoomedBeyondFit) { _, zoomed in
            if !zoomed {
                state.isFilmstripExpandedWhileZoomed = false
            }
        }
        .onChange(of: state.isCropping) { _, cropping in
            if cropping {
                state.isFilmstripExpandedWhileZoomed = false
                state.isComparingOriginal = false
            }
        }
        .navigationTitle("")
        .transparentWindowToolbar()
        .toolbar {
            if state.hasImage {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        requestCloseToHome()
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                    }
                    .help("关闭图片并返回主界面 (\(shortcutStore.combo(for: .closeToHome).displayString))")

                    Button {
                        openImagePanel()
                    } label: {
                        Image(systemName: "folder")
                            .accessibilityLabel("打开")
                    }
                    .disabled(state.isCropping)
                    .help("打开图片、PDF 或文件夹 (\(shortcutStore.combo(for: .openImage).displayString))")

                    if state.isMultiImageMode {
                        Menu {
                            Button {
                                saveImagePanel()
                            } label: {
                                Label(state.currentPDFPage == nil ? "导出当前图" : "导出当前 PDF", systemImage: state.currentPDFPage == nil ? "photo" : "doc.richtext")
                            }

                            Button {
                                batchExportPanel()
                            } label: {
                                Label("批量导出（\(state.batchExportCount) 个文件）", systemImage: "square.stack")
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .offset(y: -1)
                                .accessibilityLabel("导出")
                        }
                        .menuIndicator(.hidden)
                        .disabled(state.isCropping)
                        .help("导出当前图 (\(shortcutStore.combo(for: .exportCurrent).displayString)) 或批量导出 (\(shortcutStore.combo(for: .batchExport).displayString))")
                    } else {
                        Button {
                            saveImagePanel()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .offset(y: -1)
                                .accessibilityLabel("导出")
                        }
                        .disabled(state.isCropping)
                        .help("导出图片 (\(shortcutStore.combo(for: .exportCurrent).displayString))")
                    }
                }

                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        TitleRenameView(state: state)
                        if let page = state.pageNumber, page.total > 1 {
                            PDFPagerView(state: state, current: page.current, total: page.total)
                        }
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        state.undo()
                    } label: {
                        Label("撤销", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(state.isCropping || !state.canUndo)
                    .help("撤销上一笔 (\(shortcutStore.combo(for: .undo).displayString))")

                    Button {
                        state.redo()
                    } label: {
                        Label("重做", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(state.isCropping || !state.canRedo)
                    .help("重做 (\(shortcutStore.combo(for: .redo).displayString))")

                    Button {
                        state.clearAll()
                    } label: {
                        Label("清空", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(state.isCropping || !state.canUndo)
                    .help("清空所有打码 (\(shortcutStore.combo(for: .clearAll).displayString))")

                    Button {
                        if state.suggestions != nil {
                            state.cancelSuggestions()
                        } else {
                            Task { await state.startAutoDetect() }
                        }
                    } label: {
                        Image(systemName: "text.viewfinder")
                            .foregroundStyle(state.suggestions != nil ? Color.accentColor : Color.primary)
                            .accessibilityLabel("自动识别")
                    }
                    .disabled(!state.canAutoDetect)
                    .help(state.suggestions != nil
                          ? "取消自动识别 (Esc)"
                          : "自动识别隐私信息：手机号、地址、姓名、证件号、二维码… (\(shortcutStore.combo(for: .autoDetect).displayString))")

                    Button {
                        if state.isCropping {
                            state.cancelCrop()
                        } else {
                            state.beginCrop()
                        }
                    } label: {
                        Image(systemName: "crop")
                            .foregroundStyle(
                                (state.isCropping || !state.cropRect.isFull || state.rotationQuarterTurns != 0)
                                ? Color.accentColor
                                : Color.primary
                            )
                            .accessibilityLabel("裁剪")
                    }
                    .disabled(!state.canCrop && !state.isCropping)
                    .help(state.currentPDFPage != nil ? "PDF 页面保持原尺寸，不能裁剪" : "裁剪与旋转 (\(shortcutStore.combo(for: .toggleCrop).displayString))")

                    Image(systemName: state.isComparingOriginal ? "eye.fill" : "eye")
                        .font(.system(size: 13.5, weight: .regular))
                        .frame(width: 30, height: 26)
                        .foregroundStyle(state.isComparingOriginal ? Color.accentColor : Color.primary)
                        .contentShape(Capsule())
                        .padding(.trailing, 3)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    if !state.isCropping && !state.isComparingOriginal {
                                        state.isComparingOriginal = true
                                    }
                                }
                                .onEnded { _ in
                                    state.isComparingOriginal = false
                                }
                        )
                        .disabled(state.isCropping)
                        .opacity(state.isCropping ? 0.35 : 1.0)
                        .help("按住对比原图（或按住 \\ 键）")
                }

                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    let next = currentAppearance.next
                    appearanceRawValue = next.rawValue
                    state.showToast("外观：\(next.title)")
                } label: {
                    Label("外观主题", systemImage: currentAppearance.systemImage)
                }
                .help("当前：\(currentAppearance.title)（点击切换为\(currentAppearance.next.title)）")
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .alert(
            "无法处理图片",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {
                state.errorMessage = nil
            }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .catHideOpenImage)) { _ in
            openImagePanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .catHideExportImage)) { _ in
            if state.hasImage {
                saveImagePanel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .catHideBatchExport)) { _ in
            if state.isMultiImageMode && !state.isCropping {
                batchExportPanel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .catHideRequestCloseToHome)) { _ in
            if state.hasImage {
                requestCloseToHome()
            }
        }
        .alert("还有 \(state.unsavedCount) 张已编辑的图片或页面未导出", isPresented: $showUnsavedCloseAlert) {
            Button("仍然返回", role: .destructive) {
                state.closeAllImages()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("返回主界面后，未导出的打码和裁剪修改将会丢失。")
        }
        .confirmationDialog("当前已有打开的文件", isPresented: $showDropChoiceDialog, titleVisibility: .visible) {
            Button("追加到当前列表") {
                commitPendingDrop(append: true)
            }
            Button("替换为新文件", role: .destructive) {
                commitPendingDrop(append: false)
            }
            Button("取消", role: .cancel) {
                pendingDropURLs.removeAll()
                pendingDropItems.removeAll()
            }
        } message: {
            Text("是否将新拖入的文件追加到当前列表，还是直接替换？")
        }
        .onReceive(NotificationCenter.default.publisher(for: .catHideZoomIn)) { _ in
            if state.hasImage {
                state.zoomIn(currentScale: currentFitScale)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .catHideZoomOut)) { _ in
            if state.hasImage {
                state.zoomOut(currentScale: currentFitScale)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .catHideShowGuide)) { _ in
            isLaunchGuide = false
            showGuideSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .catHideCheckUpdates)) { _ in
            Task { @MainActor in
                await performUpdateCheck()
            }
        }
        .onAppear {
            state.pdfPasswordProvider = { name, wrongBefore in
                PDFPasswordPrompt.ask(fileName: name, wrongBefore: wrongBefore)
            }
            guard !hasHandledInitialAppear else { return }
            hasHandledInitialAppear = true
            if !suppressLaunchGuide {
                isLaunchGuide = true
                showGuideSheet = true
            }
        }
        .sheet(isPresented: $showGuideSheet) {
            GuideSheetView(
                shortcutStore: shortcutStore,
                suppressLaunchGuide: $suppressLaunchGuide,
                isLaunchPresentation: isLaunchGuide,
                onClose: { showGuideSheet = false }
            )
        }
        .alert(updateAlertTitle, isPresented: $showUpdateAlert) {
            if let updateReleaseURL {
                Button("前往下载") {
                    NSWorkspace.shared.open(updateReleaseURL)
                }
                Button("稍后再说", role: .cancel) {}
            } else {
                Button("好", role: .cancel) {}
            }
        } message: {
            Text(updateAlertMessage)
        }
    }

    private var floatingControlPill: some View {
        HStack(spacing: 10) {
            LiquidGlassSegmentedControl(options: MosaicTool.allCases, selection: $state.tool) { tool in
                HStack(spacing: 3.5) {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 11))
                    Text(tool.title)
                }
            }
            .frame(width: 170)

            Rectangle()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 1, height: 16)

            HStack(spacing: 6) {
                Text("笔刷")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))

                Circle()
                    .fill(state.tool == .eraser ? Color.primary.opacity(0.28) : Color.primary.opacity(0.85))
                    .overlay {
                        if state.tool == .eraser {
                            Circle()
                                .strokeBorder(
                                    Color.primary.opacity(0.85),
                                    style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                                )
                        }
                    }
                    .frame(width: indicatorDiameter, height: indicatorDiameter)
                    .frame(width: 18, height: 18)

                Slider(
                    value: $state.brushSize,
                    in: MosaicDocumentState.minBrushSize...MosaicDocumentState.maxBrushSize
                )
                .frame(width: 84)
                .help("拖动无极调节笔刷大小（\(shortcutStore.combo(for: .brushSmaller).displayString) / \(shortcutStore.combo(for: .brushLarger).displayString) 快捷键）")

                BrushSizeInputView(state: state)
            }
            .disabled(state.tool == .rectangle)
            .opacity(state.tool == .rectangle ? 0.42 : 1.0)

            Rectangle()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 1, height: 16)

            HStack(spacing: 6) {
                Menu {
                    ForEach(MosaicEffectStyle.allCases) { style in
                        Button {
                            state.setEffectStyle(style)
                        } label: {
                            HStack {
                                Label(style.title, systemImage: style.systemImage)
                                if state.effectStyle == style {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: state.effectStyle.systemImage)
                            .font(.system(size: 11))
                        Text(state.effectStyle.shortTitle)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.primary.opacity(0.88))
                    .frame(width: 60, height: 24)
                    .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .help("切换打码样式（马赛克 / 高斯模糊 / 纯色遮挡）")

                LiquidGlassSegmentedControl(
                    options: MosaicGranularity.allCases,
                    selection: Binding(
                        get: { state.granularity },
                        set: { state.setGranularity($0) }
                    )
                ) { item in
                    Text(item.title(for: state.effectStyle))
                }
                .frame(width: 86)
                .help(state.effectStyle == .solid ? "纯色预设（黑 / 灰 / 白）" : "打码强度（小 / 中 / 大）")
            }

            Rectangle()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 1, height: 16)

            LiquidGlassZoomControl(
                zoomLabel: zoomLabel,
                currentDisplayScale: currentDisplayedScale,
                onZoomOut: { state.zoomOut(currentScale: currentFitScale) },
                onZoomFit: { state.zoomFit() },
                onZoomIn: { state.zoomIn(currentScale: currentFitScale) },
                onScrubZoom: { scale in state.zoomMode = .custom(scale) },
                onInteractionChanged: { active in
                    isScrubbingZoom = active
                    state.isPointerOverFloatingControls = isHoveringBottomControls || active
                }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .floatingGlassCapsule()
    }

    private var floatingCropPill: some View {
        HStack(spacing: 10) {
            LiquidGlassSegmentedControl(
                options: CropAspectPreset.allCases,
                selection: Binding(
                    get: { state.cropAspectPreset },
                    set: { state.setCropAspectPreset($0) }
                )
            ) { preset in
                Text(preset.title)
            }
            .frame(width: 238)

            Rectangle()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 1, height: 16)

            Button {
                state.rotateClockwiseInCrop()
            } label: {
                Label("旋转 90°", systemImage: "rotate.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.primary.opacity(0.88))
            .help("顺时针旋转 90°")

            Button {
                state.resetDraftCrop()
            } label: {
                Text("还原")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(state.draftCropRect.isFull ? Color.primary.opacity(0.32) : Color.primary.opacity(0.88))
            .disabled(state.draftCropRect.isFull)

            Rectangle()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 1, height: 16)

            Button("取消") {
                state.cancelCrop()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.75))

            Button("完成") {
                state.applyCrop()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .floatingGlassCapsule()
    }

    private var indicatorDiameter: CGFloat {
        let ratio = (state.brushSize - MosaicDocumentState.minBrushSize)
            / (MosaicDocumentState.maxBrushSize - MosaicDocumentState.minBrushSize)
        return 6 + ratio * 11
    }

    private var emptyDropView: some View {
        let surfaceColor = colorScheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(red: 0.985, green: 0.985, blue: 0.992)

        return ZStack {
            surfaceColor

            VStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 84, height: 84)
                    .scaleEffect(isDropTargeted ? 1.06 : 1.0)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 12, y: 4)

                VStack(spacing: 6) {
                    Text(isDropTargeted ? "松开即可导入" : "拖放图片、PDF 或文件夹到此处开始打码")
                        .font(.title3.weight(.medium))

                    Text("支持单张或多张图片、PDF（含加密 PDF）和整个文件夹")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                FloatingGlassGroup(spacing: 14) {
                    HStack(spacing: 14) {
                        Button {
                            openImagePanel()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .frame(width: 16, height: 16)
                                    .foregroundStyle(Color.accentColor)
                                Text("打开文件…")
                                    .fontWeight(.medium)
                            }
                            .frame(width: 136)
                        }
                        .homeGlassButtonStyle()

                        Button {
                            state.pasteFromPasteboard()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .frame(width: 16, height: 16)
                                    .foregroundStyle(.secondary)
                                Text("粘贴剪贴板")
                                    .fontWeight(.medium)
                            }
                            .frame(width: 136)
                        }
                        .homeGlassButtonStyle()
                    }
                }
                .padding(.top, 2)
            }
            .offset(y: -4)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(0.68),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .background(
                        Color.accentColor.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .padding(.top, 56)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isDropTargeted)
    }

    private func openImagePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf]
        panel.prompt = "打开"

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            state.loadImages(from: panel.urls)
        }
    }

    private func performUpdateCheck() async {
        let result = await UpdateChecker.checkForUpdates()
        switch result {
        case .notConfigured(let currentVersion):
            updateAlertTitle = "当前版本 v\(currentVersion)"
            updateAlertMessage = "尚未绑定 GitHub 仓库。将仓库地址（如 owner/repo）填入 Info.plist 的 CatHideGitHubRepo 后，即可自动检查 GitHub Releases 更新。"
            updateReleaseURL = nil
        case .upToDate(let currentVersion):
            updateAlertTitle = "已是最新版本"
            updateAlertMessage = "当前版本 v\(currentVersion) 已经是最新版本。"
            updateReleaseURL = nil
        case .updateAvailable(let currentVersion, let latestVersion, let releaseURL, let releaseNotes):
            updateAlertTitle = "发现新版本 \(latestVersion)"
            let notesPreview = releaseNotes.isEmpty ? "" : "\n\n\(releaseNotes)"
            updateAlertMessage = "当前版本：v\(currentVersion)，最新版本：\(latestVersion)。\(notesPreview)"
            updateReleaseURL = releaseURL
        case .failed(let message):
            updateAlertTitle = "检查更新失败"
            updateAlertMessage = message
            updateReleaseURL = nil
        }
        showUpdateAlert = true
    }

    private func requestCloseToHome() {
        if state.hasUnsavedChanges {
            showUnsavedCloseAlert = true
        } else {
            state.closeAllImages()
        }
    }

    private func commitPendingDrop(append: Bool) {
        if !pendingDropURLs.isEmpty {
            let urls = pendingDropURLs
            pendingDropURLs.removeAll()
            pendingDropItems.removeAll()
            if append {
                state.appendImages(from: urls)
            } else {
                state.loadImages(from: urls)
            }
        } else if !pendingDropItems.isEmpty {
            let items = pendingDropItems
            pendingDropURLs.removeAll()
            pendingDropItems.removeAll()
            if append {
                state.appendQueueItems(items)
            } else if items.count == 1, let single = items.first, let img = single.inMemoryImage {
                state.loadImage(img, fileName: single.fileName)
            } else {
                state.loadQueue(items)
            }
        }
    }

    private func rememberedExportDirectoryURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.lastExportDirectoryKey),
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func saveImagePanel() {
        if let page = state.currentPDFPage {
            savePDFPanel(page: page)
            return
        }
        let initialFormat = preferredExportFormat
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = initialFormat == .jpeg ? [.jpeg] : [.png]
        panel.directoryURL = rememberedExportDirectoryURL() ?? state.sourceURL?.deletingLastPathComponent()
        panel.nameFieldStringValue = state.suggestedExportFileName(format: initialFormat)
        panel.prompt = "导出"

        let formatAccessory = ExportFormatAccessoryController(initialFormat: initialFormat) { selectedFormat in
            lastExportFormatRaw = selectedFormat.rawValue
            panel.allowedContentTypes = selectedFormat == .jpeg ? [.jpeg] : [.png]
            let currentName = panel.nameFieldStringValue
            let baseName = (currentName as NSString).deletingPathExtension
            let cleanBase = baseName.isEmpty ? "cathide" : baseName
            panel.nameFieldStringValue = "\(cleanBase).\(selectedFormat.fileExtension)"
        }
        panel.accessoryView = formatAccessory.view

        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.lastExportDirectoryKey)
            do {
                try state.exportImage(to: url)
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    /// A PDF exports whole (pictures only) or just the current page as PNG / JPEG.
    private func savePDFPanel(page: PDFPageRef) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = rememberedExportDirectoryURL() ?? page.url.deletingLastPathComponent()
        panel.nameFieldStringValue = state.suggestedExportFileName(fileExtension: "pdf", wholePDF: true)
        panel.prompt = "导出"
        panel.message = "导出的 PDF 只含图像：被遮住的文字不会留在文件里，也无法再被选中或搜索。"

        let total = state.pageNumber?.total ?? 1
        let accessory = PDFExportAccessoryController(pageCount: total) { choice in
            let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
            switch choice {
            case .wholePDF:
                panel.allowedContentTypes = [.pdf]
                panel.nameFieldStringValue = state.suggestedExportFileName(fileExtension: "pdf", wholePDF: true)
            case .pagePNG, .pageJPEG:
                let format: ExportFormat = choice == .pagePNG ? .png : .jpeg
                lastExportFormatRaw = format.rawValue
                panel.allowedContentTypes = [format == .png ? .png : .jpeg]
                let base = stem.isEmpty ? "cathide" : stem
                panel.nameFieldStringValue = base.contains("_p")
                    ? "\(base).\(format.fileExtension)"
                    : state.suggestedExportFileName(fileExtension: format.fileExtension, wholePDF: false)
            }
        }
        panel.accessoryView = accessory.view

        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.lastExportDirectoryKey)
            do {
                try state.exportImage(to: url)
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private func batchExportPanel() {
        guard state.modifiedCount > 0 else {
            state.showToast("当前没有已打码或编辑过的图片")
            return
        }

        let initialFormat = preferredExportFormat
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = rememberedExportDirectoryURL() ?? state.sourceURL?.deletingLastPathComponent()
        panel.prompt = "导出到此文件夹"
        panel.message = "将批量导出 \(state.batchExportCount) 个已编辑文件（编辑过的 PDF 各导出为一个只含图像的 PDF）"

        var chosenFormat: ExportFormat = initialFormat
        let formatAccessory = ExportFormatAccessoryController(initialFormat: initialFormat) { selectedFormat in
            chosenFormat = selectedFormat
            lastExportFormatRaw = selectedFormat.rawValue
        }
        panel.accessoryView = formatAccessory.view

        if panel.runModal() == .OK, let directoryURL = panel.url {
            UserDefaults.standard.set(directoryURL.path, forKey: Self.lastExportDirectoryKey)
            do {
                try state.batchExportModified(to: directoryURL, format: chosenFormat)
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let imageProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        guard !fileProviders.isEmpty || !imageProviders.isEmpty else { return false }

        Task { @MainActor in
            var droppedURLs: [URL] = []
            for provider in fileProviders {
                if let url = await loadDroppedFileURL(from: provider) {
                    droppedURLs.append(url)
                }
            }
            if !droppedURLs.isEmpty {
                if state.hasImage {
                    pendingDropURLs = droppedURLs
                    pendingDropItems.removeAll()
                    showDropChoiceDialog = true
                } else {
                    state.loadImages(from: droppedURLs)
                }
                return
            }

            var loadedItems: [(image: CGImage, fileName: String)] = []
            for provider in imageProviders {
                if let resolved = await loadDroppedImage(from: provider) {
                    loadedItems.append(resolved)
                }
            }

            if !loadedItems.isEmpty {
                let queueItems = loadedItems.map { entry in
                    MosaicQueueItem(
                        fileName: entry.fileName,
                        granularity: state.granularity,
                        effectStyle: state.effectStyle,
                        inMemoryImage: entry.image,
                        thumbnail: MosaicRenderer.makeThumbnail(from: entry.image)
                    )
                }
                if state.hasImage {
                    pendingDropURLs.removeAll()
                    pendingDropItems = queueItems
                    showDropChoiceDialog = true
                } else if loadedItems.count == 1, let single = loadedItems.first {
                    state.loadImage(single.image, fileName: single.fileName)
                } else {
                    state.loadQueue(queueItems)
                }
            } else if !imageProviders.isEmpty {
                state.errorMessage = MosaicRenderError.invalidImageFile.localizedDescription
            }
        }
        return true
    }

    private func preferredExtension(for provider: NSItemProvider) -> String {
        let types = provider.registeredTypeIdentifiers
        if types.contains(UTType.jpeg.identifier) { return "jpg" }
        if types.contains(UTType.heic.identifier) { return "heic" }
        if types.contains(UTType.webP.identifier) { return "webp" }
        return "png"
    }

    private func loadDroppedFileURL(from provider: NSItemProvider) async -> URL? {
        let dataURL: URL? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                let parsed = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: parsed)
            }
        }
        if let dataURL {
            return dataURL
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let parsed = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: parsed)
                } else if let str = item as? String {
                    let url = str.hasPrefix("file://") ? URL(string: str) : URL(fileURLWithPath: str)
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadDroppedImage(from provider: NSItemProvider) async -> (image: CGImage, fileName: String)? {
        let suggestedName = provider.suggestedName
        let fallbackExt = preferredExtension(for: provider)

        let fileResult: (CGImage, String)? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                guard let url,
                      let cgImage = try? MosaicRenderer.loadOrientedImage(from: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                let name = MosaicRenderer.resolvedImageFileName(
                    suggestedName: suggestedName,
                    fileURL: url,
                    preferredExtension: fallbackExt
                )
                continuation.resume(returning: (cgImage, name))
            }
        }
        if let fileResult {
            return fileResult
        }

        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data,
                      let cgImage = MosaicRenderer.loadOrientedImage(from: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                let name = MosaicRenderer.resolvedImageFileName(
                    suggestedName: suggestedName,
                    fileURL: nil,
                    preferredExtension: fallbackExt
                )
                continuation.resume(returning: (cgImage, name))
            }
        }
    }
}

@MainActor
private final class ExportFormatAccessoryController: NSObject {
    let view: NSView
    private let popup: NSPopUpButton
    private let onFormatChanged: (ExportFormat) -> Void

    init(initialFormat: ExportFormat = .png, onFormatChanged: @escaping (ExportFormat) -> Void) {
        self.onFormatChanged = onFormatChanged
        self.popup = NSPopUpButton(frame: .zero, pullsDown: false)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 36))
        let label = NSTextField(labelWithString: "导出格式：")
        label.translatesAutoresizingMaskIntoConstraints = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.addItems(withTitles: ["PNG（无损）", "JPEG（较小体积）"])
        popup.selectItem(at: initialFormat == .jpeg ? 1 : 0)

        container.addSubview(label)
        container.addSubview(popup)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12)
        ])

        self.view = container
        super.init()

        popup.target = self
        popup.action = #selector(formatChanged)
    }

    @objc private func formatChanged() {
        let selectedFormat: ExportFormat = popup.indexOfSelectedItem == 1 ? .jpeg : .png
        onFormatChanged(selectedFormat)
    }
}

private struct CollapsedFilmstripPill: View {
    let positionText: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 12, weight: .medium))
                Text(positionText)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(Color.primary.opacity(isHovering ? 1.0 : 0.88))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .floatingGlassCapsule()
            .overlay(
                Capsule()
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
                    .allowsHitTesting(false)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("点击展开多图预览栏")
    }
}

private extension View {
    @ViewBuilder
    func homeGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .controlSize(.large)
        } else {
            self
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }
}
