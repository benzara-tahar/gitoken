import GitokenCore
import SwiftUI

/// Root of the shelf panel: the circle (plus a transient feedback capsule) and, when expanded, the card stack growing
/// away from the corner. Measures its natural size so the controller can fit the panel to it.
struct ShelfRootView: View {
    let model: ShelfModel
    var maxStackHeight: CGFloat
    var onSize: (CGSize) -> Void
    var onDrag: () -> Void
    var onDragEnd: () -> Void

    var body: some View {
        let corner = model.corner
        let theme = model.theme
        Group {
            VStack(alignment: corner.horizontalAlignment, spacing: 10) {
                if model.expanded, !corner.isTop { stack }
                circleRow
                if model.expanded, corner.isTop { stack }
            }
            .padding(ShelfLayout.contentPadding)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
        }
        .environment(\.theme, theme)
        .environment(\.motion, model.motion)
        .environment(\.colorScheme, theme.isFluid ? .dark : colorSchemeFallback)
    }

    @Environment(\.colorScheme) private var colorSchemeFallback

    private var circleRow: some View {
        HStack(spacing: 10) {
            if !model.corner.isLeft { feedback }
            ShelfCircle(model: model, onDrag: onDrag, onDragEnd: onDragEnd)
            if model.corner.isLeft { feedback }
        }
        .zIndex(1)
        // The bounce leaps away from the screen edge; keep room for it so the panel never clips the circle.
        .padding(model.corner.isTop ? .bottom : .top, model.expanded ? 0 : ShelfLayout.bounceRoom)
    }

    @ViewBuilder
    private var feedback: some View {
        if let feedback = model.feedback {
            ShelfFeedbackView(feedback: feedback)
                .id(feedback.id)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: model.corner.isLeft ? .leading : .trailing)))
        }
    }

    /// Rows reveal themselves one by one (see `ShelfModel.expand()`), so the stack itself appears without a transition.
    private var stack: some View {
        ShelfStackView(model: model, maxHeight: maxStackHeight)
            .transition(.identity)
    }
}

extension View {
    /// One row of the staggered reveal: springs out of the orb (offset toward it, slightly smaller, transparent) and
    /// folds back the same way. Reduced motion only fades.
    func shelfReveal(_ shown: Bool, fromTop: Bool, motion: Motion) -> some View {
        let distance: CGFloat = motion.isReduced ? 0 : 18
        return opacity(shown ? 1 : 0)
            .scaleEffect(shown || motion.isReduced ? 1 : 0.94, anchor: fromTop ? .top : .bottom)
            .offset(y: shown ? 0 : (fromTop ? -distance : distance))
            .allowsHitTesting(shown)
    }
}

struct ShelfFeedbackView: View {
    @Environment(\.theme) private var theme
    let feedback: ShelfModel.Feedback

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(feedback.tone.color(theme)).frame(width: 7, height: 7)
            Text(feedback.message).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(ShelfCapsuleBackground())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct ShelfCapsuleBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = Capsule()
        if theme.isFluid {
            shape.fill(Color.black)
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        } else {
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.62))
                .background(GlassBackground(shape: shape))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
    }
}

/// Vertical stack of PR cards. The newest PR sits next to the circle; the list scrolls when taller than the screen allows.
struct ShelfStackView: View {
    @Environment(\.theme) private var theme
    let model: ShelfModel
    var maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let fromBottom = !model.corner.isTop
        let items = fromBottom ? Array(model.items.reversed()) : model.items
        VStack(alignment: .leading, spacing: 8) {
            if fromBottom { revealedHeader(fromTop: false) }
            if items.isEmpty {
                empty.shelfReveal(model.isRevealed(0), fromTop: !fromBottom, motion: model.motion)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(items) { item in
                            ShelfCard(model: model, item: item)
                                .shelfReveal(model.isRevealed(model.revealIndex(of: item)), fromTop: !fromBottom, motion: model.motion)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(fromBottom ? .bottom : .top)
                .frame(width: ShelfLayout.cardWidth + 28, height: min(max(contentHeight, 1), maxHeight - 24))
                // The extra room keeps card shadows from being clipped by the scroll view.
                .padding(.horizontal, -14)
                .padding(.vertical, -10)
                .animation(model.motion.open, value: items.map(\.id))
            }
            if !fromBottom { revealedHeader(fromTop: true) }
        }
    }

    private func revealedHeader(fromTop: Bool) -> some View {
        header.shelfReveal(model.isRevealed(model.headerRevealIndex), fromTop: fromTop, motion: model.motion)
    }

    private var header: some View {
        let shelf = model.shelf
        return HStack(spacing: 8) {
            Text("PR Shelf").font(.system(size: 12.5, weight: .semibold))
            Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if shelf.lastSyncError != nil {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.warn)
                    .help(shelf.lastSyncError.map { "Couldn't refresh: \(ShelfModel.describe($0))" } ?? "")
                    .accessibilityLabel("Couldn't refresh")
            }
            Button {
                Task { await shelf.refresh() }
            } label: {
                ZStack {
                    if shelf.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(shelf.isRefreshing)
            .help("Refresh")
            .accessibilityLabel("Refresh pull requests")
            Button { model.collapse() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close")
            .accessibilityLabel("Close PR Shelf")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(width: ShelfLayout.cardWidth, height: 32)
        .background(ShelfCapsuleBackground())
    }

    private var summary: String {
        var parts = [Format.plural(model.items.count, "pull request")]
        if model.readyCount > 0 { parts.append("\(model.readyCount) ready") }
        return parts.joined(separator: " · ")
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 18, weight: .semibold)).foregroundStyle(.tertiary)
            Text("No open pull requests").font(.system(size: 12.5, weight: .semibold))
            Text("Drop a GitHub pull request link on the circle to pin it here.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: ShelfLayout.cardWidth)
        .background(ShelfCardBackground())
    }
}
