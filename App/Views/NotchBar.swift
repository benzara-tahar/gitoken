import GitokenCore
import SwiftUI

/// Geometry of the collapsed companion, from the prototype's `nbGeom()`.
struct BarGeometry {
    var width: CGFloat
    var height: CGFloat
    var top: CGFloat
    var wing: CGFloat

    @MainActor
    static func make(model: NotchModel) -> BarGeometry {
        let store = model.store
        let host = model.host
        let quiet = store.quietReason != nil
        let attention = store.unseenCount > 0 || quiet || isBlocked(store)
        let count = store.unseenCount
        // Extra room per digit beyond the first so the badge never truncates to "…".
        let digitExtra = CGFloat(max(0, String(count).count - 1)) * 8
        if model.isNotchAttached {
            let calmBanner = model.visibleArrival != nil && !model.theme.isFluid
            let wing: CGFloat = (attention || calmBanner) ? 42 + (count > 0 ? digitExtra : 0) : 30
            return BarGeometry(width: host.notchWidth + wing * 2, height: host.topInset, top: 0, wing: wing)
        }
        let cw: CGFloat = count > 0 ? 19 + digitExtra : 0
        let width = 18 + 18 + (cw > 0 ? 6 + cw : 0) + (quiet ? 6 + 12 : 0)
        // A pill on a notched screen would hide behind the camera housing, so it drops below the menu bar.
        let top = host.hasNotch ? host.topInset + 5 : max(2, (host.topInset - 24) / 2)
        return BarGeometry(width: width, height: 24, top: top, wing: 0)
    }

    @MainActor
    static func isBlocked(_ store: InboxStore) -> Bool {
        if case .blocked = store.phase { return true }
        return false
    }
}

/// Contents of the collapsed bar: left wing (glyph / arriving actor / snoozed bell), right wing (moon + unseen count).
struct NotchBarContent: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    var geometry: BarGeometry
    /// Calm shows the arriving actor in the wing; in Fluid the island itself becomes the banner.
    var arrivalActor: Actor?

    var body: some View {
        let store = model.store
        if model.isNotchAttached {
            HStack(spacing: 0) {
                leftWing.frame(width: geometry.wing)
                Spacer(minLength: 0)
                rightWing(store: store).frame(width: geometry.wing)
            }
            .frame(width: geometry.width, height: geometry.height)
        } else {
            HStack(spacing: 6) {
                leftWing
                rightWing(store: store)
            }
            .frame(width: geometry.width, height: geometry.height)
        }
    }

    @ViewBuilder
    private var leftWing: some View {
        let store = model.store
        if case .globalSnooze = store.quietReason {
            Image(systemName: "bell.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .transition(.opacity)
        } else if let arrivalActor {
            ArrivalRingAvatar(actor: arrivalActor, size: model.isNotchAttached ? 20 : 18)
                .id(arrivalActor.login)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        } else {
            GitokenMark(size: 15, color: .white.opacity(0.86))
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func rightWing(store: InboxStore) -> some View {
        HStack(spacing: 4) {
            if BarGeometry.isBlocked(store) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .accessibilityLabel("Needs GitHub sign-in")
            } else {
                if store.quietReason != nil, !isGlobalSnooze(store) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xC6B6FF))
                        .transition(.scale.combined(with: .opacity))
                }
                if store.unseenCount > 0 {
                    CountBadge(count: store.unseenCount, height: 19, glow: theme.isFluid)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(motion.pop, value: store.unseenCount)
    }

    private func isGlobalSnooze(_ store: InboxStore) -> Bool {
        if case .globalSnooze = store.quietReason { return true }
        return false
    }
}

/// Actor avatar with a pulsing ring, shown in the wing while an arrival is announced.
private struct ArrivalRingAvatar: View {
    @Environment(\.motion) private var motion
    var actor: Actor
    var size: CGFloat
    @State private var pulse = false

    var body: some View {
        AvatarView(actor: actor, size: size)
            .overlay {
                if !motion.isReduced {
                    Circle()
                        .strokeBorder(Color(hex: 0x4AA3FF), lineWidth: 1.5)
                        .padding(-3)
                        .scaleEffect(pulse ? 1.55 : 0.85)
                        .opacity(pulse ? 0 : 0.9)
                        .animation(.easeOut(duration: 1.3).repeatCount(2, autoreverses: false), value: pulse)
                }
            }
            .onAppear { pulse = true }
    }
}

/// The collapsed bar as a standalone control (Calm, and Fluid while nothing is expanded).
struct NotchBarButton: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    var geometry: BarGeometry
    var arrivalActor: Actor?
    @State private var hovering = false

    var body: some View {
        Button { model.toggleFromNotch() } label: {
            NotchBarContent(geometry: geometry, arrivalActor: arrivalActor)
                .background { background }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.035 : 1, anchor: .top)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .debugNotchMenu(model)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(model.route.isOpen ? "Closes the inbox" : "Opens the inbox")
        .help("\(model.store.unseenCount) unseen · \(model.store.pendingCount) pending")
    }

    @ViewBuilder
    private var background: some View {
        if model.isNotchAttached {
            IslandShape(ear: 9, topRadius: 0, bottomRadius: 13)
                .fill(Color.black)
                .padding(.horizontal, -9)
        } else if theme.isFluid {
            Capsule().fill(Color.black).shadow(color: .black.opacity(0.38), radius: 9, y: 6)
        } else {
            GlassBackground(shape: Capsule())
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
    }

    private var accessibilityLabel: String {
        var parts = ["\(model.store.unseenCount) unseen", "\(model.store.pendingCount) pending"]
        switch model.store.quietReason {
        case .globalSnooze: parts.append("snoozed")
        case .some: parts.append("quiet")
        case nil: break
        }
        return "Gitoken: " + parts.joined(separator: ", ")
    }
}
