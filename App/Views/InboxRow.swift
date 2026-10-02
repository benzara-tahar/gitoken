import GitokenCore
import SwiftUI

/// One PR/issue group. Quick actions appear on hover and are always reachable through the context menu,
/// keyboard shortcuts (D / S / U / Return when selected), and VoiceOver actions.
struct InboxRow: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    let group: InboxGroup
    let bucket: InboxBucket
    let now: Date
    @State private var hovering = false

    private var selected: Bool { model.selectedRow == group.id }
    private var menuOpen: Bool { model.menu?.anchorID == menuID }
    private var menuID: String { NotchModel.snoozeMenuID(group.id) }
    private var showActions: Bool { hovering || menuOpen || selected }

    var body: some View {
        Button { model.open(.conversation(group.id)) } label: { content }
            .buttonStyle(RowButtonStyle(hovering: hovering || selected, theme: theme))
            .overlay(alignment: .topTrailing) {
                if showActions {
                    quickActions
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: theme.isFluid ? 18 : 11, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.9), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: showActions)
            .onHover { hovering = $0 }
            .contextMenu { contextMenu }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityAction(named: bucket == .done ? "Move to Inbox" : "Mark done") { primaryQuickAction() }
            .accessibilityAction(named: bucket == .snoozed ? "Unsnooze" : "Snooze 1 hour") {
                if bucket == .snoozed { model.unsnooze(group.id) } else { model.snooze(group.id, .oneHour) }
            }
            .accessibilityAction(named: "Open on GitHub") { model.openOnGitHub(group.id) }
    }

    // MARK: Layout

    private var content: some View {
        HStack(alignment: .top, spacing: theme.isFluid ? 12 : 11) {
            avatarCluster
            VStack(alignment: .leading, spacing: 2) {
                metaLine
                Text(group.thread.title)
                    .font(.system(size: theme.isFluid ? 13.5 : 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                previewLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(bucket == .done ? 0.62 : 1)
            side
                .frame(minWidth: 24, alignment: .trailing)
                .opacity(showActions ? 0 : 1)
        }
        .padding(.top, theme.isFluid ? 12 : 9)
        .padding(.bottom, theme.isFluid ? 12 : 10)
        .padding(.leading, theme.isFluid ? 12 : 18)
        .padding(.trailing, theme.isFluid ? 12 : 10)
        .overlay(alignment: .topLeading) {
            if bucket == .new && !theme.isFluid {
                Circle().fill(theme.accent).frame(width: 7, height: 7).offset(x: 6, y: 20)
            }
        }
        .contentShape(Rectangle())
    }

    private var avatarCluster: some View {
        let size = theme.rowAvatar
        let actors = group.actors
        let primary = actors.last ?? group.preview?.actor
        let secondary = actors.count > 1 ? actors[actors.count - 2] : nil
        return AvatarView(actor: primary, size: size)
            .overlay {
                if theme.isFluid && bucket == .new {
                    Circle().strokeBorder(theme.accent, lineWidth: 1.5).padding(-3.5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let secondary {
                    AvatarView(actor: secondary, size: 17)
                        .background(Circle().fill(theme.isFluid ? theme.groupBackground : Color(nsColor: .windowBackgroundColor)).padding(-2))
                        .offset(x: 5, y: 4)
                }
            }
            .frame(width: size, height: size)
            .padding(.top, 1)
    }

    /// Repo name never yields to tags: the reason drops out first (QA: "BACK" / "SNOOZE ENDED" used to truncate it).
    private var metaLine: some View {
        let repo = "\(group.thread.repo.fullName)\(group.thread.number.map { " #\($0)" } ?? "")"
        return ViewThatFits(in: .horizontal) {
            metaContent(repo: repo, reason: true)
            metaContent(repo: repo, reason: false)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }

    private func metaContent(repo: String, reason: Bool) -> some View {
        HStack(spacing: 5) {
            KindIcon(kind: group.thread.kind, state: group.state)
            Text(repo)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if reason {
                Text("·")
                Text(group.thread.reason.shortLabel).lineLimit(1).fixedSize()
            }
            tag
        }
        .fixedSize(horizontal: reason, vertical: false)
    }

    @ViewBuilder
    private var tag: some View {
        switch group.resurfaced {
        case .reopenedFromDone?: Tag(text: "Back", tone: .warn)
        case .snoozeEnded?: Tag(text: "Snooze ended", tone: .accent)
        case nil: EmptyView()
        }
    }

    @ViewBuilder
    private var previewLine: some View {
        if let preview = group.preview {
            let s = preview.sentence(viewer: model.viewerLogin)
            let snippet = preview.snippet.map { Format.plain($0, limit: 110) } ?? ""
            Text("\(Text(s.who.map { "\($0) " } ?? "").fontWeight(.semibold).foregroundStyle(.primary))\(s.what)\(Text(snippet.isEmpty ? "" : " — \(snippet)").foregroundStyle(.tertiary))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var side: some View {
        VStack(alignment: .trailing, spacing: 5) {
            switch bucket {
            case .snoozed:
                Label {
                    Text(group.snoozedUntil.map { Format.time($0) } ?? "")
                } icon: {
                    Image(systemName: "clock")
                }
                .labelStyle(CompactLabelStyle())
            case .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
            case .new, .pending:
                Text(Format.ago(group.lastActivityAt, now: now)).monospacedDigit()
                if bucket == .new {
                    if group.unseenCount > 0 {
                        CountBadge(count: group.unseenCount)
                    } else {
                        Circle().fill(theme.accent).frame(width: 8, height: 8).padding(.top, 4)
                            .accessibilityLabel("Unseen")
                    }
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }

    // MARK: Actions

    @ViewBuilder
    private var quickActions: some View {
        HStack(spacing: 2) {
            switch bucket {
            case .snoozed:
                IconButton(symbol: "bell", label: "Unsnooze", size: 24) { model.unsnooze(group.id) }
            case .done:
                IconButton(symbol: "tray.and.arrow.up", label: "Move to Inbox (D)", size: 24) { model.undoDone(group.id) }
            case .new, .pending:
                IconButton(symbol: "clock", label: "Snooze (S)", active: menuOpen, size: 24) {
                    model.presentSnoozeMenu(for: group.id)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PanelMenu.space)) } action: {
                    model.anchorFrames[menuID] = $0
                }
                IconButton(symbol: "checkmark", label: "Mark done (D)", size: 24) { model.markDone(group.id) }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.isFluid ? Color(white: 0.165) : Color(nsColor: .windowBackgroundColor).opacity(0.95))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
    }

    private func primaryQuickAction() {
        if bucket == .done { model.undoDone(group.id) } else { model.markDone(group.id) }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open") { model.open(.conversation(group.id)) }
        Divider()
        if bucket == .done {
            Button("Move to Inbox") { model.undoDone(group.id) }
        } else {
            Button("Mark Done") { model.markDone(group.id) }
        }
        if bucket == .snoozed {
            Button("Unsnooze") { model.unsnooze(group.id) }
        } else if bucket != .done {
            Menu("Snooze") {
                ForEach(SnoozeOption.allCases) { option in
                    Button("\(option.title) (\(Format.until(option.deadline(from: now), now: now)))") {
                        model.snooze(group.id, option)
                    }
                }
            }
        }
        Divider()
        Button("Open on GitHub") { model.openOnGitHub(group.id) }
        Button("Copy Link") { model.copyLink(group.id) }
    }

    private var accessibilityText: String {
        let ref = "\(group.thread.repo.fullName) \(group.thread.number.map { "#\($0)" } ?? "")"
        var parts = ["\(ref): \(group.thread.title)"]
        if bucket == .new { parts.append(group.unseenCount > 0 ? "\(group.unseenCount) new" : "unseen") }
        if let r = group.resurfaced { parts.append(r == .reopenedFromDone ? "back in inbox" : "snooze ended") }
        if let p = group.preview {
            let s = p.sentence(viewer: model.viewerLogin)
            parts.append("\(s.who ?? "") \(s.what)")
        }
        return parts.joined(separator: ". ")
    }
}

private struct RowButtonStyle: ButtonStyle {
    var hovering: Bool
    var theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: theme.isFluid ? 18 : 11, style: .continuous)
                    .fill(configuration.isPressed || hovering ? theme.groupHover : theme.groupBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: theme.isFluid ? 18 : 11, style: .continuous))
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10))
            configuration.title.monospacedDigit()
        }
    }
}
