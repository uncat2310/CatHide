import AppKit
import MosaicCore
import SwiftUI

struct BrushSizeInputView: View {
    @Bindable var state: MosaicDocumentState

    @State private var draftText = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if state.isEditingBrushSize {
                TextField("", text: $draftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(width: 34, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.2)
                    )
                    .focused($isFocused)
                    .focusEffectDisabled()
                    .onChange(of: draftText) { _, newValue in
                        let digitsOnly = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(3))
                        if digitsOnly != newValue {
                            draftText = digitsOnly
                        }
                    }
                    .onSubmit {
                        commitEdit()
                    }
                    .onExitCommand {
                        cancelEdit()
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused && state.isEditingBrushSize {
                            commitEdit()
                        }
                    }
            } else {
                Button {
                    startEditing()
                } label: {
                    Text("\(Int(state.brushSize.rounded()))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.88))
                        .frame(width: 34, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovering = hovering
                }
                .help("点击输入笔刷大小（8–120）")
            }
        }
    }

    private func startEditing() {
        draftText = "\(Int(state.brushSize.rounded()))"
        state.isEditingBrushSize = true
        DispatchQueue.main.async {
            isFocused = true
            DispatchQueue.main.async {
                if isFocused {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        }
    }

    private func commitEdit() {
        state.setBrushSize(fromInput: draftText)
        state.isEditingBrushSize = false
        isFocused = false
    }

    private func cancelEdit() {
        state.isEditingBrushSize = false
        isFocused = false
    }
}
