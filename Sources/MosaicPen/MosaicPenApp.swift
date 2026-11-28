import AppKit
import MosaicCore
import SwiftUI

extension Notification.Name {
    static let catHideOpenImage = Notification.Name("CatHide.openImage")
    static let catHideExportImage = Notification.Name("CatHide.exportImage")
    static let catHideBatchExport = Notification.Name("CatHide.batchExport")
    static let catHideRequestCloseToHome = Notification.Name("CatHide.requestCloseToHome")
    static let catHideZoomIn = Notification.Name("CatHide.zoomIn")
    static let catHideZoomOut = Notification.Name("CatHide.zoomOut")
    static let catHideShowGuide = Notification.Name("CatHide.showGuide")
    static let catHideCheckUpdates = Notification.Name("CatHide.checkUpdates")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var documentState: MosaicDocumentState?
    static var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        applyStoredAppearance()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applyStoredAppearance() {
        let raw = UserDefaults.standard.string(forKey: "catHide.appearance") ?? AppAppearance.system.rawValue
        let mode = AppAppearance(rawValue: raw) ?? .system
        CatHideApp.applyAppearance(mode)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let state = Self.documentState {
            if state.hasImage {
                state.appendImages(from: urls)
            } else {
                state.loadImages(from: urls)
            }
        } else {
            Self.pendingURLs.append(contentsOf: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = Self.documentState, state.hasUnsavedChanges else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "还有 \(state.unsavedCount) 张已编辑图片尚未导出"
        alert.informativeText = "退出后未导出的打码或裁剪修改将会丢失。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "仍然退出")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct CatHideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("catHide.appearance") private var appearanceRawValue = AppAppearance.system.rawValue
    @State private var state = MosaicDocumentState()
    @State private var shortcutStore = ShortcutStore()

    private func isActionDisabled(_ action: AppShortcutAction, baseDisabled: Bool = false) -> Bool {
        if baseDisabled { return true }
        return shortcutStore.combo(for: action).isSingleKeyWithoutModifier && state.isEditingTextInput
    }

    static func applyAppearance(_ mode: AppAppearance) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var body: some Scene {
        Window("猫猫藏藏", id: "main") {
            ContentView(state: state, shortcutStore: shortcutStore)
                .frame(minWidth: 740, minHeight: 480)
                .onAppear {
                    Self.applyAppearance(AppAppearance(rawValue: appearanceRawValue) ?? .system)
                    AppDelegate.documentState = state
                    if !AppDelegate.pendingURLs.isEmpty {
                        let urls = AppDelegate.pendingURLs
                        AppDelegate.pendingURLs.removeAll()
                        state.loadImages(from: urls)
                    }
                }
                .onChange(of: appearanceRawValue) { _, newValue in
                    Self.applyAppearance(AppAppearance(rawValue: newValue) ?? .system)
                }
        }
        .defaultSize(width: 980, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()

                Button("使用说明与快捷键…") {
                    NotificationCenter.default.post(name: .catHideShowGuide, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)

                Button("检查更新…") {
                    NotificationCenter.default.post(name: .catHideCheckUpdates, object: nil)
                }
            }

            CommandGroup(replacing: .help) {
                Button("猫猫藏藏 使用说明与快捷键…") {
                    NotificationCenter.default.post(name: .catHideShowGuide, object: nil)
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("打开文件或文件夹…") {
                    NotificationCenter.default.post(name: .catHideOpenImage, object: nil)
                }
                .applyShortcut(shortcutStore.combo(for: .openImage))
                .disabled(isActionDisabled(.openImage))

                Button("从列表移除当前项") {
                    state.removeItem(at: state.currentIndex)
                }
                .applyShortcut(shortcutStore.combo(for: .removeCurrentImage))
                .disabled(isActionDisabled(.removeCurrentImage, baseDisabled: !state.hasImage || state.isCropping))

                Button("关闭图片并返回主界面") {
                    NotificationCenter.default.post(name: .catHideRequestCloseToHome, object: nil)
                }
                .applyShortcut(shortcutStore.combo(for: .closeToHome))
                .disabled(isActionDisabled(.closeToHome, baseDisabled: !state.hasImage))
            }

            CommandGroup(replacing: .saveItem) {
                Button("导出当前文件…") {
                    NotificationCenter.default.post(name: .catHideExportImage, object: nil)
                }
                .applyShortcut(shortcutStore.combo(for: .exportCurrent))
                .disabled(isActionDisabled(.exportCurrent, baseDisabled: !state.hasImage || state.isCropping))

                Button("批量导出已打码文件…") {
                    NotificationCenter.default.post(name: .catHideBatchExport, object: nil)
                }
                .applyShortcut(shortcutStore.combo(for: .batchExport))
                .disabled(isActionDisabled(.batchExport, baseDisabled: !state.isMultiImageMode || state.modifiedCount == 0 || state.isCropping))
            }

            CommandGroup(replacing: .undoRedo) {
                Button("撤销") {
                    state.undo()
                }
                .applyShortcut(shortcutStore.combo(for: .undo))
                .disabled(isActionDisabled(.undo, baseDisabled: !state.canUndo))

                Button("重做") {
                    state.redo()
                }
                .applyShortcut(shortcutStore.combo(for: .redo))
                .disabled(isActionDisabled(.redo, baseDisabled: !state.canRedo))
            }

            CommandGroup(replacing: .pasteboard) {
                Button("复制结果") {
                    state.copyToPasteboard()
                }
                .applyShortcut(shortcutStore.combo(for: .copyResult))
                .disabled(isActionDisabled(.copyResult, baseDisabled: !state.hasImage))

                Button("粘贴图片") {
                    state.pasteFromPasteboard()
                }
                .applyShortcut(shortcutStore.combo(for: .pasteImage))
                .disabled(isActionDisabled(.pasteImage))

                Divider()

                Button("清空打码") {
                    state.clearAll()
                }
                .applyShortcut(shortcutStore.combo(for: .clearAll))
                .disabled(isActionDisabled(.clearAll, baseDisabled: !state.canUndo))
            }

            CommandMenu("工具") {
                Button("涂抹打码") {
                    state.tool = .mosaic
                }
                .applyShortcut(shortcutStore.combo(for: .toolMosaic))
                .disabled(isActionDisabled(.toolMosaic, baseDisabled: state.isCropping))

                Button("框选打码") {
                    state.tool = .rectangle
                }
                .applyShortcut(shortcutStore.combo(for: .toolRectangle))
                .disabled(isActionDisabled(.toolRectangle, baseDisabled: state.isCropping))

                Button("橡皮擦") {
                    state.tool = .eraser
                }
                .applyShortcut(shortcutStore.combo(for: .toolEraser))
                .disabled(isActionDisabled(.toolEraser, baseDisabled: state.isCropping))

                Divider()

                Button(state.isCropping ? "取消裁剪" : "裁剪图片") {
                    if state.isCropping {
                        state.cancelCrop()
                    } else {
                        state.beginCrop()
                    }
                }
                .applyShortcut(shortcutStore.combo(for: .toggleCrop))
                .disabled(isActionDisabled(.toggleCrop, baseDisabled: !state.canCrop && !state.isCropping))

                Button(state.suggestions == nil ? "自动识别隐私信息" : "取消自动识别") {
                    if state.suggestions != nil {
                        state.cancelSuggestions()
                    } else {
                        Task { await state.startAutoDetect() }
                    }
                }
                .applyShortcut(shortcutStore.combo(for: .autoDetect))
                .disabled(isActionDisabled(.autoDetect, baseDisabled: !state.canAutoDetect))

                Divider()

                Button("增大笔刷") {
                    state.adjustBrushSize(by: 8)
                }
                .applyShortcut(shortcutStore.combo(for: .brushLarger))
                .disabled(isActionDisabled(.brushLarger, baseDisabled: state.isCropping || state.tool == .rectangle))

                Button("减小笔刷") {
                    state.adjustBrushSize(by: -8)
                }
                .applyShortcut(shortcutStore.combo(for: .brushSmaller))
                .disabled(isActionDisabled(.brushSmaller, baseDisabled: state.isCropping || state.tool == .rectangle))
            }

            CommandMenu("视图") {
                Button("上一张图片") {
                    state.selectPrevious()
                }
                .applyShortcut(shortcutStore.combo(for: .previousImage))
                .disabled(isActionDisabled(.previousImage, baseDisabled: !state.canSelectPrevious))

                Button("下一张图片") {
                    state.selectNext()
                }
                .applyShortcut(shortcutStore.combo(for: .nextImage))
                .disabled(isActionDisabled(.nextImage, baseDisabled: !state.canSelectNext))

                Button("上一页") {
                    state.selectPreviousPage()
                }
                .keyboardShortcut(.pageUp, modifiers: [])
                .disabled(state.currentPDFPage == nil ? !state.canSelectPrevious : !state.canSelectPreviousPage)

                Button("下一页") {
                    state.selectNextPage()
                }
                .keyboardShortcut(.pageDown, modifiers: [])
                .disabled(state.currentPDFPage == nil ? !state.canSelectNext : !state.canSelectNextPage)

                Divider()

                Button("放大") {
                    NotificationCenter.default.post(name: .catHideZoomIn, object: nil)
                }
                .applyShortcut(shortcutStore.combo(for: .zoomIn))
                .disabled(isActionDisabled(.zoomIn, baseDisabled: !state.hasImage))

                Button("缩小") {
                    NotificationCenter.default.post(name: .catHideZoomOut, object: nil)
                }
                .applyShortcut(shortcutStore.combo(for: .zoomOut))
                .disabled(isActionDisabled(.zoomOut, baseDisabled: !state.hasImage))

                Divider()

                Button("适应窗口") {
                    state.zoomFit()
                }
                .applyShortcut(shortcutStore.combo(for: .zoomFit))
                .disabled(isActionDisabled(.zoomFit, baseDisabled: !state.hasImage))

                Button("实际大小") {
                    state.zoomActualSize()
                }
                .applyShortcut(shortcutStore.combo(for: .zoomActual))
                .disabled(isActionDisabled(.zoomActual, baseDisabled: !state.hasImage))

                Divider()

                Picker("外观主题", selection: $appearanceRawValue) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            }
        }

        Settings {
            ShortcutSettingsView(state: state, store: shortcutStore)
        }
    }
}
