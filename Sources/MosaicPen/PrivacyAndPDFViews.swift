import AppKit
import MosaicCore
import SwiftUI

/// Bottom bar while 自动识别 suggestions are shown: per-kind switches, the effect, cancel / apply.
struct SuggestionPill: View {
    var state: MosaicDocumentState
    let session: MosaicDocumentState.SuggestionSession

    private var docPages: Int { state.pageNumber?.total ?? 0 }
    private var wholeDoc: Bool { docPages > 1 && session.wholeDocument }

    private var applyTitle: String {
        if wholeDoc { return "打码全部页面" }
        return session.pickedCount > 0 ? "打码 \(session.pickedCount) 处" : "未选择"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("识别到 \(session.list.count) 处")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .fixedSize()

            HStack(spacing: 5) {
                ForEach(session.kinds) { kind in
                    let ids = session.ids(of: kind)
                    let on = ids.filter { !session.off.contains($0) }.count
                    SuggestionChip(
                        title: kind.title,
                        count: on > 0 && on < ids.count ? "\(on)/\(ids.count)" : "\(ids.count)",
                        isOn: on > 0
                    ) {
                        state.toggleSuggestions(ids, on: on == 0)
                    }
                    .help(on > 0 ? "这一类全部不打码" : "这一类全部打码")
                }
            }

            if docPages > 1 {
                divider
                SuggestionChip(title: "全部 \(docPages) 页", count: nil, isOn: session.wholeDocument, showsCheck: true) {
                    state.setSuggestionsWholeDocument(!session.wholeDocument)
                }
                .help(session.wholeDocument
                      ? "其余 \(docPages - 1) 页也会自动识别并打码（关掉的类别除外），之后可以逐页检查"
                      : "只打码当前页")
            }

            divider

            LiquidGlassSegmentedControl(
                options: MosaicEffectStyle.allCases,
                selection: Binding(get: { state.effectStyle }, set: { state.setEffectStyle($0) })
            ) { style in
                Text(style.shortTitle)
            }
            .frame(width: 150)
            .help("打码效果")

            divider

            Button("取消") {
                state.cancelSuggestions()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.75))
            .keyboardShortcut(.cancelAction)
            .help("取消 (Esc)")

            Button(applyTitle) {
                Task { await state.applySuggestions() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(session.pickedCount == 0 && !wholeDoc)
            .help("应用 (↩)，撤销一次即可全部还原")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .floatingGlassCapsule()
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(width: 1, height: 16)
    }
}

private struct SuggestionChip: View {
    let title: String
    let count: String?
    let isOn: Bool
    var showsCheck = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if showsCheck && isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                if let count {
                    Text(count)
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .opacity(0.75)
                }
            }
            .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.7))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(isHovering ? 0.12 : 0.07))
            )
            .overlay(
                Capsule().strokeBorder(isOn ? Color.clear : Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// ‹ 3 / 12 › next to the title for a PDF.
struct PDFPagerView: View {
    var state: MosaicDocumentState
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 2) {
            pagerButton("chevron.left", enabled: state.canSelectPreviousPage, help: "上一页 (Page Up)") {
                state.selectPreviousPage()
            }
            Text("\(current) / \(total)")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(minWidth: 44)
            pagerButton("chevron.right", enabled: state.canSelectNextPage, help: "下一页 (Page Down)") {
                state.selectNextPage()
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 22)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .help("PDF 第 \(current) 页，共 \(total) 页")
    }

    private func pagerButton(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary.opacity(0.85) : Color.primary.opacity(0.25))
        .disabled(!enabled)
        .help(help)
    }
}

/// Asks for the password of an encrypted PDF. The password is used only to open the file.
@MainActor
enum PDFPasswordPrompt {
    static func ask(fileName: String, wrongBefore: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = wrongBefore ? "密码不正确，请重试" : "「\(fileName)」已加密"
        alert.informativeText = "请输入打开这个 PDF 的密码。密码只用于在本机打开文件，不会保存。"
        alert.alertStyle = wrongBefore ? .warning : .informational
        alert.addButton(withTitle: "打开")
        alert.addButton(withTitle: "跳过此文件")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "密码"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

enum PDFExportChoice {
    case wholePDF
    case pagePNG
    case pageJPEG
}

@MainActor
final class PDFExportAccessoryController: NSObject {
    let view: NSView
    private let popup: NSPopUpButton
    private let onChange: (PDFExportChoice) -> Void

    init(pageCount: Int, onChange: @escaping (PDFExportChoice) -> Void) {
        self.onChange = onChange
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: [
            "PDF（整个文件，共 \(pageCount) 页）",
            "PNG（仅当前页）",
            "JPEG（仅当前页）",
        ])
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
        let label = NSTextField(labelWithString: "导出为：")
        label.translatesAutoresizingMaskIntoConstraints = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(popup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
        ])
        view = container
        super.init()
        popup.target = self
        popup.action = #selector(changed)
    }

    @objc private func changed() {
        switch popup.indexOfSelectedItem {
        case 1: onChange(.pagePNG)
        case 2: onChange(.pageJPEG)
        default: onChange(.wholePDF)
        }
    }
}
