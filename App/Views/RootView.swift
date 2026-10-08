import GitokenCore
import SwiftUI

/// What the expanded surface is showing.
enum SurfaceContent: Equatable {
    case banner(Arrival)
    case list
    case conversation(ThreadID)
    case searchConversation(SearchItemID)
    case settings

    /// Identity for cross-fades: merged arrivals keep the same key so the banner updates in place.
    var key: String {
        switch self {
        case .banner(let a): "banner-\(a.id)"
        case .list: "list"
        case .conversation(let id): "convo-\(id.rawValue)"
        case .searchConversation(let id): "search-convo-\(id.rawValue)"
        case .settings: "settings"
        }
    }

    var isBanner: Bool {
        if case .banner = self { return true }
        return false
    }
}

extension NotchModel {
    var surfaceContent: SurfaceContent? {
        switch route {
        case .collapsed: visibleArrival.map(SurfaceContent.banner)
        case .list: .list
        case .conversation(let id): .conversation(id)
        case .searchConversation(let id): .searchConversation(id)
        case .settings: .settings
        }
    }

    /// Widths from the prototype's `VIEW_W` (Calm, Fluid); an expanded diff widens the conversation.
    func surfaceWidth(_ content: SurfaceContent) -> CGFloat {
        let fluid = theme.isFluid
        let width: CGFloat
        switch content {
        case .banner: width = fluid ? 424 : 376
        case .list, .settings: width = fluid ? 408 : 392
        case .conversation(let id): width = hasExpandedDiff(id) ? 720 : (fluid ? 436 : 420)
        case .searchConversation: width = fluid ? 436 : 420
        }
        return min(width, host.maxSurfaceWidth)
    }

    func surfaceMaxHeight(_ content: SurfaceContent) -> CGFloat {
        switch content {
        case .conversation, .searchConversation: host.maxSurfaceHeight
        case .settings: min(860, host.maxSurfaceHeight)
        default: min(640, host.maxSurfaceHeight)
        }
    }

    func hasExpandedDiff(_ id: ThreadID) -> Bool {
        guard !expandedDiffs.isEmpty, let items = store.conversations[id]?.detail?.items else { return false }
        for item in items {
            if case .review(_, _, let comments) = item.payload, comments.contains(where: { expandedDiffs.contains($0.id) }) {
                return true
            }
        }
        return false
    }
}

/// Root of the panel. Measures its natural size and reports it so the panel frame can follow.
struct RootView: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onSize: (CGSize) -> Void

    var body: some View {
        TimelineView(.everyMinute) { _ in
            Group {
                if model.theme.isFluid {
                    FluidComposition().environment(\.colorScheme, .dark)
                } else {
                    CalmComposition()
                }
            }
            .environment(\.theme, model.theme)
            .environment(\.motion, model.motion)
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.store.arrival?.id) {
            if model.route.isOpen { model.drainArrivals() }
        }
        .onChange(of: reduceMotion, initial: true) {
            model.systemReduceMotion = reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        .onChange(of: model.viewerLogin, initial: true) { model.syncSearchAccount() }
    }
}

/// Calm: the hardware-notch bar stays put; a glass card drops in beneath the menu bar.
private struct CalmComposition: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        let bar = BarGeometry.make(model: model)
        let content = model.surfaceContent
        let radius: CGFloat = content?.isBanner == true ? 20 : 16
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .top) {
            NotchBarButton(geometry: bar, arrivalActor: arrivalActor)
                .padding(.top, bar.top)
                .animation(motion.open, value: bar.width)
            if let content {
                SurfaceBody(content: content)
                    // Liquid Glass alone lets busy windows behind bleed through; a window-colored wash keeps text legible.
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.62))
                    .background(GlassBackground(shape: shape))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
                    .padding(.top, max(model.host.topInset, bar.top + bar.height) + 7)
                    .transition(
                        .scale(scale: motion.hiddenScale, anchor: .top)
                            .combined(with: .offset(y: motion.hiddenOffset))
                            .combined(with: .opacity)
                    )
                    .zIndex(1)
            }
        }
        .padding(.horizontal, content == nil ? 0 : 30)
        .padding(.bottom, content == nil ? 0 : 44)
    }

    private var arrivalActor: Actor? {
        guard let arrival = model.visibleArrival else { return nil }
        if let last = arrival.actors.last { return last }
        return arrival.groupID.flatMap { model.group($0)?.actors.last }
    }
}

/// Fluid: one near-black island. Collapsed it is the notch bar; it stretches elastically into the banner,
/// inbox, conversation, or settings.
private struct FluidComposition: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var hovering = false

    var body: some View {
        let bar = BarGeometry.make(model: model)
        let content = model.surfaceContent
        let attached = model.isNotchAttached
        let ear: CGFloat = attached ? (content == nil ? 9 : 10) : 0
        let bottom: CGFloat = content == nil ? (attached ? 13 : 12) : (attached ? 32 : (content?.isBanner == true ? 35 : 30))
        let top: CGFloat = attached ? 0 : bottom
        let island = IslandShape(ear: ear, topRadius: top, bottomRadius: bottom)
        ZStack(alignment: .top) {
            if let content {
                SurfaceBody(content: content)
                    .transition(.asymmetric(insertion: .opacity.animation(motion.fade.delay(0.08)), removal: .identity))
            } else {
                Button { model.toggleFromNotch() } label: {
                    NotchBarContent(geometry: bar, arrivalActor: nil).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .debugNotchMenu(model)
                .accessibilityLabel("Gitoken: \(model.store.unseenCount) unseen, \(model.store.pendingCount) pending")
                .help("\(model.store.unseenCount) unseen · \(model.store.pendingCount) pending")
                .transition(.asymmetric(insertion: .opacity.animation(motion.fade.delay(0.05)), removal: .identity))
            }
        }
        .padding(.horizontal, ear)
        .background(island.fill(Color.black))
        .clipShape(island)
        .overlay { NotchStatusRim(shape: island) }
        .shadow(color: .black.opacity(content == nil ? (attached ? 0 : 0.38) : 0.55), radius: content == nil ? 9 : 28, y: content == nil ? 6 : 14)
        .scaleEffect(hovering && content == nil ? 1.035 : 1, anchor: .top)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
        .animation(motion.open, value: bar.width)
        .padding(.top, attached ? 0 : (content == nil ? bar.top : (model.host.hasNotch ? model.host.topInset + 5 : 5)))
        .padding(.horizontal, content == nil ? 0 : 30)
        .padding(.bottom, content == nil ? 0 : 44)
    }
}

/// The open surface's content plus its in-panel menu and toast layers.
struct SurfaceBody: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.motion) private var motion
    let content: SurfaceContent

    var body: some View {
        let width = model.surfaceWidth(content)
        let maxHeight = model.surfaceMaxHeight(content)
        inner(width: width, maxHeight: maxHeight)
            .id(content.isBanner ? "banner" : content.key)
            .transition(.asymmetric(
                insertion: .opacity.animation(motion.fade.delay(motion.isReduced ? 0 : 0.07)),
                removal: .identity
            ))
            .frame(minHeight: model.menu == nil ? nil : requiredHeight(for: model.menu), alignment: .top)
            .coordinateSpace(.named(PanelMenu.space))
            .overlay(alignment: .bottom) {
                if let toast = model.toast, !content.isBanner {
                    ToastView(toast: toast)
                        .padding(.bottom, toastInset)
                        .transition(.offset(y: 12).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in PanelMenuLayer(surfaceSize: geo.size) }
            }
    }

    @ViewBuilder
    private func inner(width: CGFloat, maxHeight: CGFloat) -> some View {
        switch content {
        case .banner(let arrival):
            ArrivalBannerView(arrival: arrival, width: width)
        case .list:
            switch model.store.phase {
            case .blocked(let error): BlockedView(error: error, width: width)
            case .starting where model.store.lastSyncError == nil && model.store.groups.isEmpty
                && model.settings.customSections.allSatisfy({ model.store.customSections.items(in: $0.id).isEmpty }):
                StartingView(width: width)
            default: InboxListView(width: width, maxHeight: maxHeight)
            }
        case .conversation(let id):
            ConversationView(id: id, width: width, maxHeight: maxHeight)
        case .searchConversation(let id):
            SearchConversationView(id: id, width: width, maxHeight: maxHeight)
        case .settings:
            SettingsView(width: width, maxHeight: maxHeight)
        }
    }

    private var toastInset: CGFloat {
        if case .conversation = content { return 96 }
        return 12
    }
}

private struct ToastView: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    let toast: NotchModel.Toast

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message).lineLimit(1)
            if toast.undo != nil {
                Button("Undo") { model.performToastUndo() }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(hex: 0x6DB7FF))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, toast.undo == nil ? 12 : 6)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.isFluid ? Color(white: 0.17) : Color(white: 0.11, opacity: 0.94))
                .shadow(color: .black.opacity(0.28), radius: 12, y: 8)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
