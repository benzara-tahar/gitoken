import GitokenCore
import SwiftUI

/// The resting PR Shelf: a glass orb with a pull-request glyph, the PR count, and a glow ring tinted by the shelf's
/// aggregate state. Click toggles the card stack, dragging moves it to another corner (handled by the controller),
/// and GitHub PR links dropped on it get pinned.
struct ShelfCircle: View {
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    let model: ShelfModel
    /// Drag tracking reads the pointer from `NSEvent.mouseLocation`, so the window can move under the gesture.
    var onDrag: () -> Void
    var onDragEnd: () -> Void
    @State private var hovering = false
    @State private var isDragging = false

    private let size = ShelfLayout.circleSize

    var body: some View {
        let count = model.items.count
        let tone = model.mood.color(theme)
        // The rim only turns while the pointer or a drop is on the orb; unseen events breathe for a bounded time.
        let alive = !motion.isReduced && (hovering || model.dropTargeted)
        ShelfOrb(tone: tone, alive: alive, breathing: model.hasUnseenEvents && !motion.isReduced, highlighted: model.dropTargeted)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.isFluid ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .shadow(color: tone.opacity(theme.isFluid ? 0.8 : 0.45), radius: 6)
                    .offset(y: count > 0 ? -1 : 0)
            }
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    CountBadge(count: count, height: 18, glow: true)
                        .offset(x: 5, y: -4)
                }
            }
            .scaleEffect(scale)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: model.dropTargeted)
            .keyframeAnimator(initialValue: BounceFrame(), trigger: model.bounceToken) { [isTop = model.corner.isTop] content, frame in
                content
                    .background {
                        // Flare: the halo blooms with the leap.
                        Circle()
                            .fill(tone.opacity(0.55 * frame.flare))
                            .blur(radius: 12)
                            .scaleEffect(1 + 0.35 * frame.flare)
                    }
                    .background {
                        // Ripple: one ring expanding outward from the orb.
                        Circle()
                            .strokeBorder(tone.opacity(frame.ripple > 0 ? 0.8 * (1 - frame.ripple) : 0), lineWidth: 2)
                            .scaleEffect(1 + 0.55 * frame.ripple)
                    }
                    .scaleEffect(x: frame.scaleX, y: frame.scaleY, anchor: isTop ? .top : .bottom)
                    .offset(y: isTop ? frame.lift : -frame.lift)
            } keyframes: { [amplitude = bounceAmplitude] _ in
                Self.bounceKeyframes(amplitude: amplitude)
            }
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard isDragging || hypot(value.translation.width, value.translation.height) >= 4 else { return }
                        isDragging = true
                        onDrag()
                    }
                    .onEnded { _ in
                        if isDragging { onDragEnd() } else { model.toggle() }
                        isDragging = false
                    }
            )
            .onDrop(of: ShelfTransfer.droppableTypes, isTargeted: Binding(get: { model.dropTargeted }, set: { model.dropTargeted = $0 })) {
                model.pin(from: $0)
            }
            .debugShelfMenu(model.notch)
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("PR Shelf, \(Format.plural(count, "pull request"))")
            .accessibilityValue(accessibilityState)
            .accessibilityHint("Shows your open pull requests. Drop a GitHub pull request link to pin it.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.toggle() }
    }

    private var scale: CGFloat {
        if model.dropTargeted { return 1.18 }
        if model.dragging { return 1.08 }
        return hovering ? 1.06 : 1
    }

    private var help: String { "PR Shelf · " + accessibilityState }

    private var accessibilityState: String {
        var parts = [Format.plural(model.items.count, "pull request")]
        if model.readyCount > 0 { parts.append("\(model.readyCount) ready to merge") }
        if model.failingCount > 0 { parts.append("\(model.failingCount) failing CI") }
        return parts.joined(separator: " · ")
    }

    /// One track set for every motion style; reduced motion flattens the amplitude to zero (the sound still plays).
    @KeyframesBuilder<BounceFrame>
    private nonisolated static func bounceKeyframes(amplitude a: CGFloat) -> some Keyframes<BounceFrame> {
        KeyframeTrack(\BounceFrame.lift) {
            CubicKeyframe(0, duration: 0.06)
            SpringKeyframe(18 * a, duration: 0.2, spring: .smooth)
            SpringKeyframe(0, duration: 0.22, spring: .snappy)
            SpringKeyframe(6 * a, duration: 0.16)
            SpringKeyframe(0, duration: 0.3, spring: .bouncy)
        }
        KeyframeTrack(\BounceFrame.scaleX) {
            CubicKeyframe(1 + 0.14 * a, duration: 0.06)
            CubicKeyframe(1 - 0.06 * a, duration: 0.2)
            CubicKeyframe(1 + 0.1 * a, duration: 0.22)
            SpringKeyframe(1, duration: 0.46, spring: .bouncy)
        }
        KeyframeTrack(\BounceFrame.scaleY) {
            CubicKeyframe(1 - 0.14 * a, duration: 0.06)
            CubicKeyframe(1 + 0.08 * a, duration: 0.2)
            CubicKeyframe(1 - 0.08 * a, duration: 0.22)
            SpringKeyframe(1, duration: 0.46, spring: .bouncy)
        }
        KeyframeTrack(\BounceFrame.flare) {
            CubicKeyframe(min(1, a), duration: 0.18)
            CubicKeyframe(0, duration: 0.9)
        }
        KeyframeTrack(\BounceFrame.ripple) {
            LinearKeyframe(0.001 * a, duration: 0.05)
            CubicKeyframe(a > 0 ? 1 : 0, duration: 0.75)
            LinearKeyframe(0, duration: 0.01)
        }
    }

    private var bounceAmplitude: CGFloat {
        switch motion.style {
        case .reduced: 0
        case .gentle: 1
        case .elastic: 1.45
        }
    }
}

struct BounceFrame {
    var lift: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var flare: CGFloat = 0
    var ripple: CGFloat = 0
}

/// Layered glass orb: tinted halo, slowly turning gradient rim, glass body, inner state tint, specular highlight and
/// rim light. The rim only turns while `alive` (hover, drop, unseen events) so a resting orb costs no frames.
struct ShelfOrb: View {
    @Environment(\.theme) private var theme
    var tone: Color
    var alive: Bool
    var breathing: Bool
    var highlighted: Bool
    @State private var spin = false
    @State private var breathe = false

    var body: some View {
        let fluid = theme.isFluid
        ZStack {
            Circle()
                .fill(tone.opacity(fluid ? 0.5 : 0.32))
                .blur(radius: 7)
                .scaleEffect(breathe ? 1.12 : 1)
                .opacity(breathe ? 1 : (breathing ? 0.85 : 0.6))
            glassBody
            Circle()
                .fill(RadialGradient(colors: [tone.opacity(fluid ? 0.42 : 0.26), .clear], center: UnitPoint(x: 0.5, y: 1.05), startRadius: 2, endRadius: 30))
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(fluid ? 0.32 : 0.55), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: ShelfLayout.circleSize * 0.66, height: ShelfLayout.circleSize * 0.4)
                .offset(y: -ShelfLayout.circleSize * 0.2)
                .blendMode(.plusLighter)
            Circle()
                .strokeBorder(
                    AngularGradient(colors: [tone, tone.opacity(0.15), tone.opacity(0.8), tone.opacity(0.1), tone], center: .center),
                    lineWidth: highlighted ? 2.5 : 1.6
                )
                .rotationEffect(.degrees(spin ? 360 : 0))
                .shadow(color: tone.opacity(0.7), radius: 3)
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(fluid ? 0.45 : 0.75), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                .padding(1.5)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(fluid ? 0.5 : 0.25), radius: 8, y: 5)
        .onChange(of: alive, initial: true) {
            if alive {
                withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) { spin = true }
            } else {
                withAnimation(.easeOut(duration: 0.6)) { spin = false }
            }
        }
        .task(id: breathing) {
            guard breathing else {
                withAnimation(.easeOut(duration: 0.4)) { breathe = false }
                return
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
            // Breathe for a few cycles, then settle into a steady brighter glow so an unattended orb stops animating.
            try? await Task.sleep(for: .seconds(17))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.8)) { breathe = false }
        }
    }

    @ViewBuilder
    private var glassBody: some View {
        let circle = Circle()
        if theme.isFluid {
            circle.fill(RadialGradient(colors: [Color(white: 0.16), Color(white: 0.03)], center: UnitPoint(x: 0.5, y: 0.25), startRadius: 1, endRadius: 30))
        } else {
            circle.fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                .background(GlassBackground(shape: circle))
        }
    }
}
