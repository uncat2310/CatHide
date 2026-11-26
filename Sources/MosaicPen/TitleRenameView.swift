import MosaicCore
import SwiftUI

struct TitleRenameView: View {
    @Bindable var state: MosaicDocumentState
    @State private var draftName = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if state.isRenamingTitle {
                HStack(spacing: 3) {
                    TextField("输入新文件名", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .frame(width: 196)
                        .focused($isFocused)
                        .onSubmit {
                            commitRename()
                        }
                        .onExitCommand {
                            cancelRename()
                        }
                        .onChange(of: isFocused) { _, focused in
                            if !focused && state.isRenamingTitle {
                                commitRename()
                            }
                        }

                    if !state.currentFileExtension.isEmpty {
                        Text(".\(state.currentFileExtension)")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.55))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            } else {
                Button {
                    startRename()
                } label: {
                    HStack(spacing: 6) {
                        if state.isMultiImageMode {
                            Text(state.queuePositionText)
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.primary.opacity(0.75))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }

                        Text(state.fileName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if !state.imageDimensionsText.isEmpty {
                            Text("·")
                                .foregroundStyle(Color.primary.opacity(0.35))
                            Text(state.imageDimensionsText)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Color.primary.opacity(0.65))
                        }

                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.65))
                            .opacity(isHovering ? 1.0 : 0.0)
                            .frame(width: 12)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.14)) {
                        isHovering = hovering
                    }
                }
                .help("点击重命名文件")
            }
        }
    }

    private func startRename() {
        draftName = state.currentFileStem
        state.isRenamingTitle = true
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func commitRename() {
        state.renameCurrentImage(to: draftName)
        state.isRenamingTitle = false
        isFocused = false
    }

    private func cancelRename() {
        state.isRenamingTitle = false
        isFocused = false
    }
}
