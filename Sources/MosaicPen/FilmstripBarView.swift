import MosaicCore
import SwiftUI

struct FilmstripBarView: View {
    var state: MosaicDocumentState
    var shortcutStore: ShortcutStore
    var useGlassDock: Bool = false
    var onCollapse: (() -> Void)? = nil

    @State private var hoverContentX: CGFloat?
    @State private var dragContentX: CGFloat?
    @State private var isDraggingStrip = false

    private let tileSize: CGFloat = 54
    private let tileSpacing: CGFloat = 10
    private let stripPadding: CGFloat = 8
    private let arrowWidth: CGFloat = 28
    private let counterWidth: CGFloat = 54

    private var activePointerX: CGFloat? {
        dragContentX ?? hoverContentX
    }

    var body: some View {
        GeometryReader { geo in
            let itemCount = state.queue.count
            let contentWidth = CGFloat(itemCount) * tileSize
                + CGFloat(max(0, itemCount - 1)) * tileSpacing
                + stripPadding * 2
            let reservedSides = useGlassDock
                ? (arrowWidth * 2 + 148)
                : (counterWidth * 2 + arrowWidth * 2 + 40)
            let maxStripWidth = max(180, geo.size.width - reservedSides)
            let stripWidth = min(contentWidth, maxStripWidth)
            let isOverflowing = contentWidth > maxStripWidth

            let topPad: CGFloat = useGlassDock ? 12 : 24
            let bottomPad: CGFloat = useGlassDock ? 10 : 16
            let stripHeight: CGFloat = tileSize + topPad + bottomPad + (isOverflowing ? 4 : 0)
            let sideControlTopPad: CGFloat = useGlassDock ? 2 : 8

            let stripRow = HStack(spacing: useGlassDock ? 8 : 10) {
                if !useGlassDock {
                    Color.clear
                        .frame(width: counterWidth, height: 1)
                }

                ChevronNavButton(
                    systemImage: "chevron.left",
                    enabled: state.canSelectPrevious,
                    helpText: "上一张 (\(shortcutStore.combo(for: .previousImage).displayString))"
                ) {
                    state.selectPrevious()
                }
                .padding(.top, sideControlTopPad)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: isOverflowing) {
                        LazyHStack(spacing: tileSpacing) {
                            ForEach(Array(state.queue.enumerated()), id: \.element.id) { index, item in
                                let tileTransform = cardTransform(for: index)
                                ThumbnailTile(
                                    item: item,
                                    size: tileSize,
                                    isSelected: index == state.currentIndex,
                                    isDragging: isDraggingStrip,
                                    transform: tileTransform
                                )
                                .id(item.id)
                                .zIndex(Double(tileTransform.scale * 10) + (index == state.currentIndex ? 1.0 : 0.0))
                                .contextMenu {
                                    Button(role: .destructive) {
                                        state.removeItem(at: index)
                                    } label: {
                                        Label("从列表移除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, stripPadding)
                        .padding(.top, topPad)
                        .padding(.bottom, bottomPad)
                        .contentShape(Rectangle())
                        .coordinateSpace(name: "filmstripContent")
                        .onContinuousHover(coordinateSpace: .named("filmstripContent")) { phase in
                            switch phase {
                            case let .active(location):
                                hoverContentX = location.x
                            case .ended:
                                hoverContentX = nil
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("filmstripContent"))
                                .onChanged { value in
                                    isDraggingStrip = true
                                    dragContentX = value.location.x
                                    selectTileIfNeeded(atContentX: value.location.x)
                                }
                                .onEnded { value in
                                    selectTileIfNeeded(atContentX: value.location.x)
                                    dragContentX = nil
                                    isDraggingStrip = false
                                    if state.queue.indices.contains(state.currentIndex) {
                                        withAnimation(.easeOut(duration: 0.18)) {
                                            proxy.scrollTo(state.queue[state.currentIndex].id, anchor: .center)
                                        }
                                    }
                                }
                        )
                    }
                    .scrollClipDisabled(!isOverflowing)
                    .onChange(of: state.currentIndex) { _, newIndex in
                        guard !isDraggingStrip, state.queue.indices.contains(newIndex) else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(state.queue[newIndex].id, anchor: .center)
                        }
                    }
                }
                .frame(width: stripWidth, height: stripHeight)

                ChevronNavButton(
                    systemImage: "chevron.right",
                    enabled: state.canSelectNext,
                    helpText: "下一张 (\(shortcutStore.combo(for: .nextImage).displayString))"
                ) {
                    state.selectNext()
                }
                .padding(.top, sideControlTopPad)

                if useGlassDock, let onCollapse {
                    FilmstripCollapsePill(
                        positionText: state.queuePositionText,
                        action: onCollapse
                    )
                    .padding(.top, sideControlTopPad)
                } else {
                    Text(state.queuePositionText)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: counterWidth, alignment: .leading)
                        .padding(.top, 8)
                }
            }

            if useGlassDock {
                stripRow
                    .padding(.horizontal, 12)
                    .floatingGlassRoundedRect(cornerRadius: 20)
                    .frame(width: geo.size.width, height: stripHeight, alignment: .center)
            } else {
                stripRow
                    .frame(width: geo.size.width, height: 94, alignment: .center)
            }
        }
        .frame(height: useGlassDock ? 80 : 94)
    }

    private func cardTransform(for index: Int) -> DockCardTransform {
        guard let pointerX = activePointerX else { return .identity }
        let centerX = stripPadding + CGFloat(index) * (tileSize + tileSpacing) + tileSize * 0.5
        return CanvasNavigationMath.dockCardTransform(
            distance: pointerX - centerX,
            influenceRadius: 108,
            maxScale: useGlassDock ? 1.12 : 1.22,
            maxLift: useGlassDock ? 2 : 8
        )
    }

    private func selectTileIfNeeded(atContentX x: CGFloat) {
        guard let targetIndex = CanvasNavigationMath.filmstripIndex(
            forContentX: x,
            itemCount: state.queue.count,
            tileSize: tileSize,
            spacing: tileSpacing,
            leadingPadding: stripPadding
        ), targetIndex != state.currentIndex else {
            return
        }
        state.selectItem(at: targetIndex)
    }
}

private struct ChevronNavButton: View {
    let systemImage: String
    let enabled: Bool
    let helpText: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary.opacity(0.88) : Color.primary.opacity(0.30))
                .frame(width: 28, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovering && enabled ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(helpText)
    }
}

private struct FilmstripCollapsePill: View {
    let positionText: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 11.5, weight: .medium))
                Text(positionText)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(Color.primary.opacity(isHovering ? 1.0 : 0.86))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(isHovering ? 0.12 : 0.06))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("点击收起预览栏")
    }
}

private struct ThumbnailTile: View {
    let item: MosaicQueueItem
    let size: CGFloat
    let isSelected: Bool
    let isDragging: Bool
    let transform: DockCardTransform

    private var effectiveScale: CGFloat {
        max(transform.scale, isSelected ? 1.05 : 1.0)
    }

    private var isWaveActive: Bool {
        transform.scale > 1.01
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = item.thumbnail {
                    Image(decorative: thumb, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.14)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .opacity(isSelected || isWaveActive ? 1.0 : 0.78)
            .shadow(
                color: .black.opacity(isSelected || isWaveActive ? 0.18 : 0.08),
                radius: isWaveActive ? 6 : (isSelected ? 5 : 2.5),
                y: isWaveActive ? 3 : (isSelected ? 2 : 1)
            )

            if item.isExported {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white, .green)
                    .offset(x: 4, y: -4)
            } else if item.hasEdits {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
                    .offset(x: 3, y: -3)
            }
        }
        .scaleEffect(effectiveScale, anchor: .bottom)
        .offset(y: transform.liftY)
        .animation(isDragging ? nil : .interactiveSpring(response: 0.20, dampingFraction: 0.80), value: transform)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .contentShape(Rectangle())
        .help(item.fileName)
    }
}
