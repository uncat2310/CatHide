import Foundation
import Observation

public struct ShortcutModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifierSet(rawValue: 1 << 0)
    public static let shift = ShortcutModifierSet(rawValue: 1 << 1)
    public static let option = ShortcutModifierSet(rawValue: 1 << 2)
    public static let control = ShortcutModifierSet(rawValue: 1 << 3)
}

public struct ShortcutCombo: Codable, Hashable, Sendable {
    public let key: String
    public let modifiers: ShortcutModifierSet

    public init(key: String, modifiers: ShortcutModifierSet = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public var isSingleKeyWithoutModifier: Bool {
        modifiers.isEmpty
    }

    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += Self.displayKey(for: key)
        return result
    }

    private static func displayKey(for key: String) -> String {
        switch key {
        case "leftArrow": return "←"
        case "rightArrow": return "→"
        case "upArrow": return "↑"
        case "downArrow": return "↓"
        case "return": return "↩"
        case "space": return "Space"
        case "delete": return "⌫"
        case "=": return "+"
        default:
            return key.count == 1 ? key.uppercased() : key
        }
    }
}

public enum AppShortcutGroup: String, CaseIterable, Identifiable, Sendable {
    case tools
    case file
    case edit
    case view

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tools: "工具与笔刷"
        case .file: "文件与导出"
        case .edit: "编辑"
        case .view: "画布与切图"
        }
    }
}

public enum AppShortcutAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case toolMosaic
    case toolRectangle
    case toolEraser
    case toggleCrop
    case brushSmaller
    case brushLarger

    case openImage
    case removeCurrentImage
    case closeToHome
    case exportCurrent
    case batchExport

    case undo
    case redo
    case clearAll
    case copyResult
    case pasteImage

    case previousImage
    case nextImage
    case zoomIn
    case zoomOut
    case zoomFit
    case zoomActual

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toolMosaic: "涂抹打码"
        case .toolRectangle: "框选打码"
        case .toolEraser: "橡皮擦"
        case .toggleCrop: "裁剪图片"
        case .brushSmaller: "减小笔刷"
        case .brushLarger: "增大笔刷"
        case .openImage: "打开图片或文件夹"
        case .removeCurrentImage: "从列表移除当前图片"
        case .closeToHome: "关闭图片并返回主界面"
        case .exportCurrent: "导出当前图片"
        case .batchExport: "批量导出已打码图片"
        case .undo: "撤销"
        case .redo: "重做"
        case .clearAll: "清空打码"
        case .copyResult: "复制结果"
        case .pasteImage: "粘贴图片"
        case .previousImage: "上一张图片"
        case .nextImage: "下一张图片"
        case .zoomIn: "放大"
        case .zoomOut: "缩小"
        case .zoomFit: "适应窗口"
        case .zoomActual: "实际大小"
        }
    }

    public var group: AppShortcutGroup {
        switch self {
        case .toolMosaic, .toolRectangle, .toolEraser, .toggleCrop, .brushSmaller, .brushLarger:
            .tools
        case .openImage, .removeCurrentImage, .closeToHome, .exportCurrent, .batchExport:
            .file
        case .undo, .redo, .clearAll, .copyResult, .pasteImage:
            .edit
        case .previousImage, .nextImage, .zoomIn, .zoomOut, .zoomFit, .zoomActual:
            .view
        }
    }

    public var defaultCombo: ShortcutCombo {
        switch self {
        case .toolMosaic: ShortcutCombo(key: "b")
        case .toolRectangle: ShortcutCombo(key: "r")
        case .toolEraser: ShortcutCombo(key: "e")
        case .toggleCrop: ShortcutCombo(key: "c")
        case .brushSmaller: ShortcutCombo(key: "[")
        case .brushLarger: ShortcutCombo(key: "]")
        case .openImage: ShortcutCombo(key: "o", modifiers: .command)
        case .removeCurrentImage: ShortcutCombo(key: "delete", modifiers: .command)
        case .closeToHome: ShortcutCombo(key: "w", modifiers: [.command, .shift])
        case .exportCurrent: ShortcutCombo(key: "s", modifiers: .command)
        case .batchExport: ShortcutCombo(key: "s", modifiers: [.command, .shift])
        case .undo: ShortcutCombo(key: "z", modifiers: .command)
        case .redo: ShortcutCombo(key: "z", modifiers: [.command, .shift])
        case .clearAll: ShortcutCombo(key: "k", modifiers: [.command, .shift])
        case .copyResult: ShortcutCombo(key: "c", modifiers: .command)
        case .pasteImage: ShortcutCombo(key: "v", modifiers: .command)
        case .previousImage: ShortcutCombo(key: "leftArrow", modifiers: .command)
        case .nextImage: ShortcutCombo(key: "rightArrow", modifiers: .command)
        case .zoomIn: ShortcutCombo(key: "=", modifiers: .command)
        case .zoomOut: ShortcutCombo(key: "-", modifiers: .command)
        case .zoomFit: ShortcutCombo(key: "0", modifiers: .command)
        case .zoomActual: ShortcutCombo(key: "1", modifiers: .command)
        }
    }
}

@MainActor
@Observable
public final class ShortcutStore {
    public private(set) var overrides: [AppShortcutAction: ShortcutCombo]

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let storageKey = "catHide.customShortcuts.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: ShortcutCombo].self, from: data) {
            var loaded: [AppShortcutAction: ShortcutCombo] = [:]
            for (raw, combo) in decoded {
                if let action = AppShortcutAction(rawValue: raw) {
                    loaded[action] = combo
                }
            }
            self.overrides = loaded
        } else {
            self.overrides = [:]
        }
    }

    public var hasCustomShortcuts: Bool {
        !overrides.isEmpty
    }

    public func combo(for action: AppShortcutAction) -> ShortcutCombo {
        overrides[action] ?? action.defaultCombo
    }

    public func conflictingAction(
        for combo: ShortcutCombo,
        excluding action: AppShortcutAction
    ) -> AppShortcutAction? {
        for candidate in AppShortcutAction.allCases where candidate != action {
            if self.combo(for: candidate) == combo {
                return candidate
            }
        }
        return nil
    }

    @discardableResult
    public func setCombo(_ combo: ShortcutCombo, for action: AppShortcutAction) -> AppShortcutAction? {
        if let conflict = conflictingAction(for: combo, excluding: action) {
            return conflict
        }
        if combo == action.defaultCombo {
            overrides.removeValue(forKey: action)
        } else {
            overrides[action] = combo
        }
        save()
        return nil
    }

    public func reset(_ action: AppShortcutAction) {
        overrides.removeValue(forKey: action)
        save()
    }

    public func resetAll() {
        overrides.removeAll()
        save()
    }

    private func save() {
        if overrides.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let encodedDict = Dictionary(
            uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }
        )
        if let data = try? JSONEncoder().encode(encodedDict) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
