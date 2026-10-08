import AppKit
import GitokenCore
import SwiftUI

// MARK: - Surfaces

/// Native glass: Liquid Glass on macOS 26, a behind-window visual effect view on macOS 15.
struct GlassBackground<S: Shape>: View {
    var shape: S

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            VisualEffect(material: .popover).clipShape(shape)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // The panel is rarely key; keep the vibrant (active) look regardless.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Fluid "island": flush with the top edge, concave ears blending into the menu bar when attached to the notch,
/// continuous rounded bottom corners.
struct IslandShape: Shape {
    var ear: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(ear, AnimatablePair(topRadius, bottomRadius)) }
        set {
            ear = newValue.first
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: ear, dy: 0)
        var path = Path(roundedRect: body, cornerRadii: RectangleCornerRadii(
            topLeading: topRadius, bottomLeading: bottomRadius, bottomTrailing: bottomRadius, topTrailing: topRadius
        ), style: .continuous)
        guard ear > 0.5 else { return path }
        var left = Path()
        left.move(to: CGPoint(x: body.minX - ear, y: rect.minY))
        left.addLine(to: CGPoint(x: body.minX + 1, y: rect.minY))
        left.addLine(to: CGPoint(x: body.minX + 1, y: rect.minY + ear))
        left.addLine(to: CGPoint(x: body.minX, y: rect.minY + ear))
        left.addQuadCurve(
            to: CGPoint(x: body.minX - ear, y: rect.minY), control: CGPoint(x: body.minX, y: rect.minY)
        )
        left.closeSubpath()
        var right = Path()
        right.move(to: CGPoint(x: body.maxX + ear, y: rect.minY))
        right.addLine(to: CGPoint(x: body.maxX - 1, y: rect.minY))
        right.addLine(to: CGPoint(x: body.maxX - 1, y: rect.minY + ear))
        right.addLine(to: CGPoint(x: body.maxX, y: rect.minY + ear))
        right.addQuadCurve(
            to: CGPoint(x: body.maxX + ear, y: rect.minY), control: CGPoint(x: body.maxX, y: rect.minY)
        )
        right.closeSubpath()
        path.addPath(left)
        path.addPath(right)
        return path
    }
}

// MARK: - Controls

struct IconButton: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var label: String
    var active = false
    var size: CGFloat = 26
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(theme.accent) : hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering || active ? Color.primary.opacity(0.07) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Rounded pill button used in the conversation header ("Mark done", "Snooze", …).
struct PillButton: View {
    @Environment(\.theme) private var theme
    enum Kind { case primary, normal, ghost, tinted(Color) }
    var title: String
    var symbol: String?
    var kind: Kind = .normal
    var trailingChevron = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if trailingChevron {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .normal: .primary
        case .ghost: theme.accent
        case .tinted(let c): c
        }
    }

    private var background: Color {
        switch kind {
        case .primary: theme.accent.opacity(hovering ? 0.88 : 1)
        case .normal: Color.primary.opacity(hovering ? 0.12 : theme.isFluid ? 0.09 : 0.06)
        case .ghost: hovering ? Color.primary.opacity(0.06) : .clear
        case .tinted(let c): c.opacity(hovering ? 0.2 : 0.14)
        }
    }
}

struct Chip: View {
    @Environment(\.theme) private var theme
    var text: String
    var symbol: String?
    var tone: Tone?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(tone.map { AnyShapeStyle($0.color(theme)) } ?? AnyShapeStyle(.secondary))
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(tone.map { $0.color(theme).opacity(0.14) } ?? theme.chipBackground))
        .fixedSize()
    }
}

/// Uppercase status tag ("BACK", "SNOOZE ENDED").
struct Tag: View {
    @Environment(\.theme) private var theme
    var text: String
    var tone: Tone

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.2)
            .foregroundStyle(tone.color(theme))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tone.color(theme).opacity(0.15)))
            .fixedSize()
    }
}

struct CountBadge: View {
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    var count: Int
    var height: CGFloat = 18
    var glow = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: height * 0.62, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText(value: Double(count)))
            .foregroundStyle(.white)
            .padding(.horizontal, height * 0.3)
            .frame(minWidth: height, minHeight: height)
            .background(
                Capsule().fill(
                    glow
                        ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x4AA3FF), Color(hex: 0x1F7CF5)], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(theme.accent)
                )
            )
            .shadow(color: glow ? Color(hex: 0x3D9BFF).opacity(0.55) : .clear, radius: 6)
            .keyframeAnimator(initialValue: 1.0, trigger: count) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                if motion.isReduced {
                    LinearKeyframe(1.0, duration: 0.01)
                } else {
                    SpringKeyframe(1.22, duration: 0.15)
                    SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
                }
            }
            .accessibilityLabel(Format.plural(count, "update"))
    }
}

/// Section header with optional disclosure.
struct SectionHeader: View {
    var title: String
    var count: Int
    var expanded: Bool?
    var toggle: (() -> Void)?

    var body: some View {
        let label = HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text("\(count)").font(.system(size: 11, weight: .regular))
            Spacer()
            if let expanded {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .contentShape(Rectangle())

        if let toggle {
            Button(action: toggle) { label }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(count)")
                .accessibilityValue(expanded == true ? "expanded" : "collapsed")
        } else {
            label.accessibilityAddTraits(.isHeader)
        }
    }
}

/// Header row for every open view. In Fluid notch mode the controls sit in the "wings" beside the camera
/// housing; elsewhere it is a normal 44pt toolbar.
struct SurfaceHeader<Leading: View, Trailing: View>: View {
    @Environment(\.theme) private var theme
    @Environment(NotchModel.self) private var model
    var width: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let wings = theme.isFluid && theme.notchAttached
        let wingWidth = max(60, (width - model.host.notchWidth) / 2 - 18)
        HStack(spacing: 8) {
            HStack(spacing: 2) { leading }
                .frame(maxWidth: wings ? wingWidth : .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 2) { trailing }
                .frame(maxWidth: wings ? wingWidth : .infinity, alignment: .trailing)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: wings ? max(32, model.host.topInset) : 44)
    }
}

/// Back control with an optional unseen badge.
struct BackButton: View {
    @Environment(\.theme) private var theme
    var title = "Inbox"
    var badge: Int = 0
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(theme.accent))
                        .padding(.leading, 5)
                }
            }
            .foregroundStyle(theme.accent)
            .padding(.leading, 3)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(badge > 0 ? "Back to \(title.lowercased()), \(badge) other unseen" : "Back to \(title.lowercased())")
        .help("Back to \(title.lowercased())")
    }
}

/// Button that opens an in-panel menu anchored to itself.
struct MenuIconButton: View {
    @Environment(NotchModel.self) private var model
    var id: String
    var symbol: String
    var label: String
    var active = false
    var items: () -> [PanelMenu.Item]
    @State private var frame: CGRect = .zero

    var body: some View {
        IconButton(symbol: symbol, label: label, active: active || model.menu?.anchorID == id) {
            model.presentMenu(PanelMenu(anchorID: id, anchor: frame, items: items()))
        }
        .menuAnchor($frame)
    }
}
