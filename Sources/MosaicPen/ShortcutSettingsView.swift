import AppKit
import MosaicCore
import SwiftUI

extension ShortcutCombo {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case "leftArrow": .leftArrow
        case "rightArrow": .rightArrow
        case "upArrow": .upArrow
        case "downArrow": .downArrow
        case "return": .return
        case "space": .space
        case "delete": .delete
        default:
            if let first = key.first {
                KeyEquivalent(first)
            } else {
                KeyEquivalent(" ")
            }
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    static func from(event: NSEvent) -> ShortcutCombo? {
        if event.keyCode == 53 { // Escape
            return nil
        }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        var mods: ShortcutModifierSet = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }

        let keyName: String?
        switch event.keyCode {
        case 123: keyName = "leftArrow"
        case 124: keyName = "rightArrow"
        case 125: keyName = "downArrow"
        case 126: keyName = "upArrow"
        case 36, 76: keyName = "return"
        case 49: keyName = "space"
        case 51, 117: keyName = "delete"
        default:
            if let chars = event.charactersIgnoringModifiers?.lowercased(),
               let scalar = chars.unicodeScalars.first,
               chars.count == 1,
               !CharacterSet.controlCharacters.contains(scalar) {
                keyName = chars
            } else {
                keyName = nil
            }
        }

        guard let keyName else { return nil }
        return ShortcutCombo(key: keyName, modifiers: mods)
    }
}

extension View {
    func applyShortcut(_ combo: ShortcutCombo) -> some View {
        keyboardShortcut(combo.keyEquivalent, modifiers: combo.eventModifiers)
    }
}

struct ShortcutSettingsView: View {
    @Bindable var state: MosaicDocumentState
    var store: ShortcutStore

    @AppStorage("catHide.lastExportFormat") private var lastExportFormatRaw = ExportFormat.png.rawValue
    @State private var recordingAction: AppShortcutAction?
    @State private var conflictMessage: String?
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("应用内快捷键（不会抢占全局/其他软件快捷键）")
                        .font(.callout.weight(.semibold))
                    Text("所有快捷键仅在猫猫藏藏窗口处于前台时生效。点击右侧按键即可重新录制，按 Esc 取消。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.035))

            if let conflictMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(conflictMessage)
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("隐私与导出")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        VStack(spacing: 0) {
                            Toggle(isOn: $state.stripExifOnExport) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("导出时清除 EXIF / GPS 等隐私元数据")
                                        .font(.system(size: 13))
                                    Text("默认开启，移除设备型号、拍摄时间与位置信息")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)

                            Divider()
                                .padding(.leading, 12)

                            HStack {
                                Text("默认导出格式")
                                    .font(.system(size: 13))
                                Spacer()
                                Picker("", selection: $lastExportFormatRaw) {
                                    Text("PNG（无损）").tag(ExportFormat.png.rawValue)
                                    Text("JPEG（较小体积）").tag(ExportFormat.jpeg.rawValue)
                                }
                                .labelsHidden()
                                .frame(width: 150)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        }
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                        )
                    }

                    ForEach(AppShortcutGroup.allCases) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

                            VStack(spacing: 0) {
                                let actions = AppShortcutAction.allCases.filter { $0.group == group }
                                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                                    shortcutRow(for: action)
                                    if index < actions.count - 1 {
                                        Divider()
                                            .padding(.leading, 12)
                                    }
                                }
                            }
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                            )
                        }
                    }
                }
                .padding(18)
            }

            Divider()

            HStack {
                Text("菜单路径：猫猫藏藏 → 设置…（⌘,）")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("恢复全部默认") {
                    stopRecording()
                    conflictMessage = nil
                    store.resetAll()
                }
                .disabled(!store.hasCustomShortcuts)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 500)
        .onDisappear {
            stopRecording()
        }
    }

    @ViewBuilder
    private func shortcutRow(for action: AppShortcutAction) -> some View {
        let currentCombo = store.combo(for: action)
        let isRecording = recordingAction == action
        let isModified = currentCombo != action.defaultCombo

        HStack(spacing: 10) {
            Text(action.title)
                .font(.system(size: 13))

            Spacer()

            if isModified && !isRecording {
                Button("恢复默认") {
                    conflictMessage = nil
                    store.reset(action)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording(for: action)
                }
            } label: {
                Text(isRecording ? "请按下快捷键…" : currentCombo.displayString)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 74)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isRecording ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                isRecording ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: isRecording ? 1.2 : 0.6
                            )
                    )
            }
            .buttonStyle(.plain)
            .help("点击重新设置「\(action.title)」快捷键")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func startRecording(for action: AppShortcutAction) {
        stopRecording()
        conflictMessage = nil
        recordingAction = action

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape cancels recording
                Task { @MainActor in
                    stopRecording()
                }
                return nil
            }

            guard let combo = ShortcutCombo.from(event: event) else {
                return event
            }

            Task { @MainActor in
                if let conflict = store.setCombo(combo, for: action) {
                    conflictMessage = "「\(combo.displayString)」已被「\(conflict.title)」占用，请换一个组合键。"
                } else {
                    conflictMessage = nil
                    stopRecording()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        recordingAction = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
