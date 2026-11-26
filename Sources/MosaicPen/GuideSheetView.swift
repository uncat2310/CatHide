import AppKit
import MosaicCore
import SwiftUI

struct GuideSheetView: View {
    var shortcutStore: ShortcutStore
    @Binding var suppressLaunchGuide: Bool
    let isLaunchPresentation: Bool
    let onClose: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text("欢迎使用猫猫藏藏")
                        .font(.title3.weight(.semibold))
                    Text("轻量简洁的 macOS 原生图片打码工具")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                GuideRow(
                    symbol: "photo.on.rectangle.angled",
                    title: "导入与粘贴",
                    detail: "拖入单张、多张图片或整个文件夹即可开始；也支持直接粘贴剪贴板截图，完成后可一键返回主页。",
                    keycaps: [
                        shortcutStore.combo(for: .openImage).displayString,
                        shortcutStore.combo(for: .pasteImage).displayString,
                        shortcutStore.combo(for: .closeToHome).displayString
                    ]
                )

                GuideRow(
                    symbol: "paintbrush.pointed",
                    title: "涂抹、框选、模糊与裁剪",
                    detail: "支持马赛克 / 高斯模糊 / 纯色遮挡三种风格，可用涂抹、框选或橡皮精准处理，还支持 90° 旋转与自由/比例裁剪。",
                    keycaps: [
                        shortcutStore.combo(for: .toolMosaic).displayString,
                        shortcutStore.combo(for: .toolRectangle).displayString,
                        shortcutStore.combo(for: .toolEraser).displayString,
                        shortcutStore.combo(for: .toggleCrop).displayString
                    ]
                )

                GuideRow(
                    symbol: "hand.draw",
                    title: "缩放、对比原图与多图管理",
                    detail: "滚轮、双指捏合或拖动右下角缩放胶囊均可缩放（放大后多图条自动收成底部胶囊），按住「\\」可随时透视原图对比。",
                    keycaps: [
                        shortcutStore.combo(for: .previousImage).displayString,
                        shortcutStore.combo(for: .nextImage).displayString,
                        "\\"
                    ]
                )

                GuideRow(
                    symbol: "square.and.arrow.up",
                    title: "单张与批量导出",
                    detail: "导出单张后自动切到下一张未处理图片，也支持将已打码图片一键批量导出。",
                    keycaps: [
                        shortcutStore.combo(for: .exportCurrent).displayString,
                        shortcutStore.combo(for: .batchExport).displayString
                    ]
                )
            }

            Text("提示：跳过或关闭后，可随时在左上角菜单栏「猫猫藏藏 → 使用说明与快捷键」再次查看，或在「设置… (⌘,)」中自定义按键（仅应用内生效，不抢占系统快捷键）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Divider()

            HStack {
                if !suppressLaunchGuide || isLaunchPresentation {
                    Button("今后永不提醒") {
                        suppressLaunchGuide = true
                        onClose()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button("自定义快捷键…") {
                    onClose()
                    DispatchQueue.main.async {
                        openSettings()
                    }
                }
                .buttonStyle(.bordered)

                Button("关闭") {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

private struct GuideRow: View {
    let symbol: String
    let title: String
    let detail: String
    let keycaps: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.semibold))

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        ForEach(keycaps, id: \.self) { cap in
                            Text(cap)
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.primary.opacity(0.78))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.primary.opacity(0.07))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                                )
                        }
                    }
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
