import SwiftUI

struct LiquidGlassSegmentedControl<Option: Hashable & Identifiable, LabelContent: View>: View {
    let options: [Option]
    @Binding var selection: Option
    @ViewBuilder let label: (Option) -> LabelContent

    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false
    @State private var dragThumbX: CGFloat = 0
    @State private var hoverIndex: Int?

    private let trackPadding: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, options.count)
            let innerWidth = max(1, proxy.size.width - trackPadding * 2)
            let segmentWidth = innerWidth / CGFloat(count)
            let selectedIndex = options.firstIndex(of: selection) ?? 0
            let maxOffset = CGFloat(max(0, count - 1)) * segmentWidth
            let currentThumbX = isDragging ? dragThumbX : CGFloat(selectedIndex) * segmentWidth
            let activeIndex = min(
                count - 1,
                max(0, Int(((currentThumbX + segmentWidth / 2.0) / segmentWidth).rounded(.down)))
            )

            let trackFill = colorScheme == .dark
                ? Color.white.opacity(0.09)
                : Color.black.opacity(0.075)
            let trackStroke = Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.11)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackFill)
                    .overlay(
                        Capsule()
                            .strokeBorder(trackStroke, lineWidth: 0.5)
                    )
                    .zIndex(0)

                // Resting thumb is a crisp elevated pill behind text so borders & labels stay razor-sharp;
                // dragging lifts a crystal-clear Liquid Glass lens OVER the text for real optical refraction.
                if !isDragging {
                    restingThumb(width: segmentWidth, height: max(18, proxy.size.height - trackPadding * 2))
                        .offset(x: trackPadding + currentThumbX)
                        .zIndex(1)
                }

                HStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        let isActive = index == activeIndex
                        let isHovered = hoverIndex == index && !isActive
                        label(option)
                            .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                            .foregroundStyle(
                                isActive
                                    ? Color.primary
                                    : (isHovered ? Color.primary.opacity(0.92) : Color.primary.opacity(0.78))
                            )
                            .frame(width: segmentWidth, height: proxy.size.height)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                hoverIndex = hovering ? index : (hoverIndex == index ? nil : hoverIndex)
                            }
                    }
                }
                .padding(.horizontal, trackPadding)
                .zIndex(2)

                if isDragging {
                    LiquidGlassDragLens(
                        width: segmentWidth,
                        height: max(18, proxy.size.height - trackPadding * 2),
                        glassScale: 1.14,
                        fallbackScale: 1.10,
                        shadowOpacity: 0.18,
                        shadowRadius: 8
                    )
                    .offset(x: trackPadding + currentThumbX)
                    .allowsHitTesting(false)
                    .zIndex(3)
                }
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let proposed = value.location.x - trackPadding - segmentWidth / 2.0
                        let clamped = min(maxOffset, max(0, proposed))
                        if !isDragging && abs(value.translation.width) >= 3 {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                                isDragging = true
                                dragThumbX = clamped
                            }
                        } else if isDragging {
                            dragThumbX = clamped
                        }

                        if isDragging {
                            let previewIdx = min(
                                count - 1,
                                max(0, Int(((clamped + segmentWidth / 2.0) / segmentWidth).rounded(.down)))
                            )
                            if selection != options[previewIdx] {
                                selection = options[previewIdx]
                            }
                        }
                    }
                    .onEnded { value in
                        let targetIdx: Int
                        if abs(value.translation.width) < 3 {
                            let clickX = value.location.x - trackPadding
                            targetIdx = min(count - 1, max(0, Int((clickX / segmentWidth).rounded(.down))))
                        } else {
                            let proposed = value.location.x - trackPadding - segmentWidth / 2.0
                            let clamped = min(maxOffset, max(0, proposed))
                            targetIdx = min(
                                count - 1,
                                max(0, Int(((clamped + segmentWidth / 2.0) / segmentWidth).rounded(.down)))
                            )
                        }

                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            selection = options[targetIdx]
                            isDragging = false
                        }
                    }
            )
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private func restingThumb(width: CGFloat, height: CGFloat) -> some View {
        let fillColor = colorScheme == .dark ? Color.white.opacity(0.22) : Color.white
        let strokeColor = colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.08)

        Capsule()
            .fill(fillColor)
            .frame(width: width, height: height)
            .overlay(
                Capsule()
                    .strokeBorder(strokeColor, lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 3, y: 1)
    }
}

struct LiquidGlassDragLens: View {
    let width: CGFloat
    let height: CGFloat
    let glassScale: CGFloat
    let fallbackScale: CGFloat
    let shadowOpacity: Double
    let shadowRadius: CGFloat

    var body: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(Color.clear)
                .frame(width: width, height: height)
                .glassEffect(.clear.interactive(), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.65),
                                    Color.white.opacity(0.14)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.0
                        )
                )
                .scaleEffect(glassScale)
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: 2)
        } else {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: width, height: height)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 1.0)
                )
                .scaleEffect(fallbackScale)
        }
    }
}

extension View {
    @ViewBuilder
    private func floatingGlass<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
                .overlay(
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.45),
                                    Color.primary.opacity(0.10)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.65
                        )
                )
                .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        }
    }

    func floatingGlassCapsule() -> some View {
        floatingGlass(in: Capsule())
    }

    func floatingGlassRoundedRect(cornerRadius: CGFloat = 18) -> some View {
        floatingGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    func transparentWindowToolbar() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

struct FloatingGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}
