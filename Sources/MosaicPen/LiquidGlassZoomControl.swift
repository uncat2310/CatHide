import MosaicCore
import SwiftUI

struct LiquidGlassZoomControl: View {
    let zoomLabel: String
    let currentDisplayScale: CGFloat
    let onZoomOut: () -> Void
    let onZoomFit: () -> Void
    let onZoomIn: () -> Void
    let onScrubZoom: (CGFloat) -> Void
    var onInteractionChanged: ((Bool) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverZone: Zone?
    @State private var pressedZone: Zone?
    @State private var isDragging = false
    @State private var dragThumbX: CGFloat = 0
    @State private var dragStartScale: CGFloat = 1.0

    private enum Zone: Equatable {
        case minus
        case fit
        case plus
    }

    private let totalWidth: CGFloat = 104
    private let trackPadding: CGFloat = 2
    private let sideWidth: CGFloat = 28
    private let centerWidth: CGFloat = 44
    private let lensWidth: CGFloat = 34

    var body: some View {
        let trackFill = colorScheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.075)
        let trackStroke = Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.11)
        let innerHeight: CGFloat = 24

        ZStack(alignment: .leading) {
            Capsule()
                .fill(trackFill)
                .overlay(
                    Capsule()
                        .strokeBorder(trackStroke, lineWidth: 0.5)
                )
                .zIndex(0)

            HStack(spacing: 0) {
                zoneView(zone: .minus, width: sideWidth, height: innerHeight) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                }

                zoneView(zone: .fit, width: centerWidth, height: innerHeight) {
                    Text(zoomLabel)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }

                zoneView(zone: .plus, width: sideWidth, height: innerHeight) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .padding(.horizontal, trackPadding)
            .zIndex(1)

            if isDragging {
                LiquidGlassDragLens(
                    width: lensWidth,
                    height: innerHeight,
                    glassScale: 1.06,
                    fallbackScale: 1.04,
                    shadowOpacity: 0.16,
                    shadowRadius: 6
                )
                .offset(x: trackPadding + dragThumbX)
                .allowsHitTesting(false)
                .zIndex(2)
            }
        }
        .frame(width: totalWidth, height: 28)
        .contentShape(Capsule())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                hoverZone = zone(forX: location.x)
            case .ended:
                hoverZone = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let innerWidth = totalWidth - trackPadding * 2
                    let maxOffset = max(0, innerWidth - lensWidth)
                    let clamped = min(maxOffset, max(0, value.location.x - trackPadding - lensWidth * 0.5))

                    if !isDragging && abs(value.translation.width) >= 4 {
                        dragStartScale = max(0.1, currentDisplayScale)
                        onInteractionChanged?(true)
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                            isDragging = true
                            pressedZone = nil
                            dragThumbX = clamped
                        }
                    } else if isDragging {
                        dragThumbX = clamped
                        let targetScale = CanvasNavigationMath.zoomScaleForDrag(
                            baseScale: dragStartScale,
                            translationX: value.translation.width
                        )
                        onScrubZoom(targetScale)
                    } else {
                        pressedZone = zone(forX: value.startLocation.x)
                    }
                }
                .onEnded { value in
                    if !isDragging && abs(value.translation.width) < 4 {
                        switch zone(forX: value.location.x) {
                        case .minus:
                            onZoomOut()
                        case .fit:
                            onZoomFit()
                        case .plus:
                            onZoomIn()
                        }
                    }
                    onInteractionChanged?(false)
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.80)) {
                        isDragging = false
                        pressedZone = nil
                    }
                }
        )
        .help("点击 - / + 缩放，点击中间适应窗口，或按住左右拖动无极缩放")
    }

    private func zone(forX x: CGFloat) -> Zone {
        if x < trackPadding + sideWidth {
            return .minus
        } else if x > totalWidth - trackPadding - sideWidth {
            return .plus
        } else {
            return .fit
        }
    }

    @ViewBuilder
    private func zoneView<Content: View>(
        zone: Zone,
        width: CGFloat,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isHovered = !isDragging && hoverZone == zone
        let isPressed = !isDragging && pressedZone == zone
        let pressFill: Color = isPressed
            ? Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08)
            : .clear

        content()
            .foregroundStyle(Color.primary.opacity(isHovered || isPressed ? 1.0 : 0.76))
            .frame(width: width, height: height)
            .background(
                Capsule()
                    .fill(pressFill)
            )
            .scaleEffect(isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.10), value: isPressed)
    }
}
