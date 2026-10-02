import GitokenCore
import SwiftUI

/// Conversation panel: header, title block, timeline with "since your last visit" divider, reply composer.
/// The timeline is only as tall as its content (capped by the screen), so short threads get a short panel.
struct ConversationView: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    let id: ThreadID
    var width: CGFloat
    var maxHeight: CGFloat

    @State private var timelineHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0
    @State private var composerHeight: CGFloat = 0
    @State private var landedOnDivider = false
    @State private var scrollToEndAfterSend = false
    @State private var snoozeAnchor: CGRect = .zero
    /// Hidden AI reviews revealed for this visit only.
    @State private var revealAI = false
    @State private var nearBottom = true
    /// Entries currently on screen, so the "new ↓" pill can disappear once its target scrolls into view.
    @State private var visibleEntries: Set<String> = []
    /// First new entry below the viewport, offered by the "new ↓" pill.
    @State private var pendingNew: (id: String, count: Int)?
    @State private var highlighted: String?

    var body: some View {
        if let group = model.group(id) {
            let state = model.store.conversations[id]
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    titleBlock(group, detail: state?.detail)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }

                timeline(group, state: state)

                ComposerView(group: group, onSent: { scrollToEndAfterSend = true })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
            .frame(width: width)
            .onChange(of: id) {
                // Per-visit state belongs to the conversation, not to this view instance.
                revealAI = false
                pendingNew = nil
                highlighted = nil
                visibleEntries = []
                landedOnDivider = false
            }
        } else {
            VStack(spacing: 0) {
                header
                Text("This conversation is no longer in your inbox.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(24)
            }
            .frame(width: width)
        }
    }

    // MARK: Header

    private var header: some View {
        let others = model.store.groups(in: .new).filter { $0.id != id }.count
        return SurfaceHeader(width: width) {
            BackButton(badge: others) { model.back() }
        } trailing: {
            IconButton(
                symbol: model.pinned ? "pin.fill" : "pin", label: model.pinned ? "Unpin panel" : "Pin panel open",
                active: model.pinned
            ) { model.pinned.toggle() }
            IconButton(symbol: "xmark", label: "Close (Esc)") { model.close() }
        }
    }

    private func titleBlock(_ g: InboxGroup, detail: ThreadDetail?) -> some View {
        let now = model.store.now.now()
        let snoozed = g.snoozedUntil.map { $0 > now } ?? false
        let state = detail?.state ?? g.state
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                KindIcon(kind: g.thread.kind, state: state, size: 12)
                Text(g.thread.repo.fullName).lineLimit(1).truncationMode(.middle)
                if let n = g.thread.number { Text("#\(n)").foregroundStyle(.tertiary).fixedSize() }
                Text("·").foregroundStyle(.tertiary)
                Text(g.thread.reason.longLabel).lineLimit(1)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            Text(detail?.title ?? g.thread.title)
                .font(.system(size: theme.isFluid ? 16 : 15.5, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 4)
                .padding(.bottom, 8)

            FlowLayout(spacing: 5) {
                stateChip(kind: g.thread.kind, state: state)
                if let checks = detail?.checks { checksChip(checks) }
                if let review = latestReview(detail) { review }
                if g.doneAt != nil { Chip(text: "Done", symbol: "checkmark") }
            }
            .padding(.bottom, 10)

            HStack(spacing: 6) {
                if g.doneAt != nil {
                    PillButton(title: "Move to Inbox", symbol: "tray.and.arrow.up") { model.undoDone(id) }
                } else {
                    PillButton(title: "Mark done", symbol: "checkmark", kind: .primary) { model.markDone(id) }
                }
                PillButton(
                    title: snoozed ? "Until \(Format.until(g.snoozedUntil!, now: now))" : "Snooze", symbol: "clock",
                    kind: snoozed ? .tinted(theme.quiet) : .normal, trailingChevron: true
                ) {
                    model.presentMenu(PanelMenu(anchorID: "convo-snooze", anchor: snoozeAnchor, items: model.snoozeMenuItems(for: id)))
                }
                .menuAnchor($snoozeAnchor)
                Spacer(minLength: 4)
                PillButton(title: "Open on GitHub", symbol: "arrow.up.right.square", kind: .ghost) { model.openOnGitHub(id) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
    }

    private func stateChip(kind: SubjectKind, state: SubjectState) -> Chip {
        let pr = kind == .pullRequest
        switch state {
        case .merged: return Chip(text: "Merged", symbol: "arrow.triangle.merge", tone: .merged)
        case .closed: return Chip(text: "Closed", symbol: pr ? "arrow.triangle.pull" : "checkmark.circle", tone: pr ? .danger : .merged)
        case .draft: return Chip(text: "Draft", symbol: "arrow.triangle.pull", tone: .neutral)
        case .open, .unknown: return Chip(text: "Open", symbol: pr ? "arrow.triangle.pull" : "smallcircle.filled.circle", tone: .success)
        }
    }

    private func checksChip(_ c: CheckSummary) -> Chip {
        switch c.status {
        case .failure: Chip(text: "Checks failing", symbol: "xmark", tone: .danger)
        case .success: Chip(text: "Checks passing", symbol: "checkmark", tone: .success)
        case .pending: Chip(text: "Checks running", symbol: "clock", tone: .warn)
        case .neutral: Chip(text: "Checks done", symbol: "minus")
        }
    }

    private func latestReview(_ detail: ThreadDetail?) -> Chip? {
        guard let detail else { return nil }
        for item in detail.items.reversed() {
            if case .review(let state, _, _) = item.payload {
                switch state {
                case .approved: return Chip(text: "Approved", tone: .success)
                case .changesRequested: return Chip(text: "Changes requested", tone: .danger)
                default: continue
                }
            }
        }
        return nil
    }

    // MARK: Timeline

    @ViewBuilder
    private func timeline(_ g: InboxGroup, state: ConversationState?) -> some View {
        let available = max(120, maxHeight - chromeHeight - composerHeight)
        if let detail = state?.detail {
            let aiMode = model.store.settings.aiReviews
            let hiddenAI = aiMode == .hide && !revealAI ? detail.items.filter(AIReviewers.isAIActivity) : []
            let items = hiddenAI.isEmpty ? detail.items : detail.items.filter { !AIReviewers.isAIActivity($0) }
            let split = TimelineSplit(
                items: items, lastVisitAt: state?.lastVisitAt, viewer: model.viewerLogin,
                showAllOlder: model.olderShown.contains(id)
            )
            let older = TimelineEntry.entries(for: split.older, collapseAI: aiMode == .collapse)
            let newer = TimelineEntry.entries(for: split.newer, collapseAI: aiMode == .collapse)
            let context = TimelineContext(
                group: g, viewer: model.viewerLogin, now: model.store.now.now(),
                reviewComments: Self.reviewComments(detail.items)
            )
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !split.hiddenOlder.isEmpty {
                            Button {
                                withAnimation(motion.open) { _ = model.olderShown.insert(id) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                                    Text("Show \(Format.plural(split.hiddenOlder.count, "earlier event"))")
                                }
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 7)
                                .padding(.trailing, 10)
                                .frame(height: 24)
                                .background(Capsule().fill(theme.chipBackground))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        ForEach(older) { entryRow($0, context: context) }
                        if let label = split.dividerLabel {
                            SinceDivider(label: label).id(Self.dividerID)
                            ForEach(newer) {
                                entryRow($0, context: context)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        if !hiddenAI.isEmpty {
                            Button { withAnimation(motion.open) { revealAI = true } } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                                    Text("\(Format.plural(hiddenAI.count, "AI review")) hidden · \(Text("Show").foregroundStyle(theme.accent).fontWeight(.semibold))")
                                }
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(Capsule().fill(theme.chipBackground))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                        }
                        Color.clear.frame(height: 1).id(Self.endID)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { timelineHeight = $0 }
                }
                .frame(height: min(timelineHeight, available))
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
                } action: { _, isNear in
                    nearBottom = isNear
                }
                .overlay(alignment: .bottom) {
                    if let pending = pendingNew, !visibleEntries.contains(pending.id) {
                        NewActivityPill(label: pending.count == 0 ? "Newest" : "\(pending.count) new", symbol: "arrow.down") {
                            reveal(pending.id, proxy: proxy)
                        }
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .onAppear { land(proxy, split: split, entries: older + newer) }
                .onChange(of: detail.items.map(\.id)) { old, new in
                    if scrollToEndAfterSend || old.isEmpty {
                        scrollToEndAfterSend = false
                        withAnimation(motion.open) { proxy.scrollTo(Self.endID, anchor: .bottom) }
                        return
                    }
                    arrived(Set(new).subtracting(old), in: older + newer, proxy: proxy)
                }
            }
        } else if let error = state?.error {
            VStack(spacing: 8) {
                Text("Couldn't load this conversation").font(.system(size: 13, weight: .semibold))
                Text(errorText(error)).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                PillButton(title: "Retry", symbol: "arrow.clockwise") { Task { await model.store.openConversation(id) } }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading conversation…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func entryRow(_ entry: TimelineEntry, context: TimelineContext) -> some View {
        TimelineEntryView(entry: entry, context: context)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.accent.opacity(highlighted == entry.id ? 0.12 : 0))
                    .padding(.horizontal, -6)
            }
            .id(entry.id)
            .onScrollVisibilityChange(threshold: 0.2) { visible in
                if visible {
                    visibleEntries.insert(entry.id)
                    if pendingNew?.id == entry.id { pendingNew = nil }
                } else {
                    visibleEntries.remove(entry.id)
                }
            }
    }

    /// New items appended while the panel is open: follow them when the reader is at the bottom, otherwise offer
    /// them with the "new ↓" pill instead of yanking the scroll position.
    private func arrived(_ newIDs: Set<String>, in entries: [TimelineEntry], proxy: ScrollViewProxy) {
        let fresh = entries.filter { entry in
            entry.itemIDs.contains(where: newIDs.contains) && !Self.isViewer(entry, model.viewerLogin)
        }
        guard let first = fresh.first else { return }
        if nearBottom {
            reveal(first.id, proxy: proxy)
        } else {
            withAnimation(motion.isReduced ? nil : .easeOut(duration: 0.2)) {
                pendingNew = (pendingNew?.id ?? first.id, (pendingNew?.count ?? 0) + fresh.count)
            }
        }
    }

    private func reveal(_ entryID: String, proxy: ScrollViewProxy) {
        withAnimation(motion.isReduced ? nil : motion.open) {
            proxy.scrollTo(entryID, anchor: .top)
            pendingNew = nil
        }
        highlighted = entryID
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(motion.isReduced ? nil : .easeOut(duration: 0.5)) {
                if highlighted == entryID { highlighted = nil }
            }
        }
    }

    private static func isViewer(_ entry: TimelineEntry, _ viewer: String?) -> Bool {
        let actor: Actor = switch entry {
        case .item(let item), .aiReview(let item): item.actor
        case .reviewRequests(let group): group.actor
        }
        return actor.login.caseInsensitiveCompare(viewer ?? "") == .orderedSame
    }

    /// Opens at the visit boundary so the newest unseen activity is the first thing read; when the newest item
    /// is far below, the "new ↓" pill offers it.
    private func land(_ proxy: ScrollViewProxy, split: TimelineSplit, entries: [TimelineEntry]) {
        guard !landedOnDivider else { return }
        landedOnDivider = true
        DispatchQueue.main.async {
            if split.dividerLabel != nil {
                proxy.scrollTo(Self.dividerID, anchor: .top)
                let fresh = entries.filter { entry in
                    !Self.isViewer(entry, model.viewerLogin)
                        && split.newer.contains { entry.itemIDs.contains($0.id) }
                }
                // Count 0 labels the pill "Newest": nothing arrived during this visit, it just sits far below.
                if fresh.count > 1, let newest = fresh.last { pendingNew = (newest.id, 0) }
            } else {
                proxy.scrollTo(Self.endID, anchor: .bottom)
            }
        }
    }

    private static let dividerID = "since-divider"
    private static let endID = "timeline-end"

    private static func reviewComments(_ items: [TimelineItem]) -> [String: ReviewComment] {
        var map: [String: ReviewComment] = [:]
        for item in items {
            if case .review(_, _, let comments) = item.payload {
                for c in comments { map[c.id] = c }
            }
        }
        return map
    }

    private func errorText(_ error: GitHubError) -> String {
        switch error {
        case .http(let status, let message): "GitHub returned \(status)\(message.map { ": \($0)" } ?? "")."
        case .transport(let message): message
        case .rateLimited: "Rate limited by GitHub. Try again shortly."
        case .auth(let auth): auth.instructions
        case .graphQL(let messages): messages.first ?? "GraphQL error."
        case .decoding: "Unexpected response from GitHub."
        }
    }
}

private struct SinceDivider: View {
    @Environment(\.theme) private var theme
    var label: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(theme.accent.opacity(0.45)).frame(width: 14, height: 1)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent).fixedSize()
            Rectangle().fill(theme.accent.opacity(0.45)).frame(height: 1)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Reply box. Return sends, Shift-Return adds a line; "Reply" on a review comment threads under it.
struct ComposerView: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    let group: InboxGroup
    var onSent: () -> Void
    @State private var height: CGFloat = 28
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        let target = model.replyTargets[group.id]
        let draft = Binding(get: { model.drafts[group.id] ?? "" }, set: { model.drafts[group.id] = $0 })
        let canSend = !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
        VStack(alignment: .leading, spacing: 0) {
            if let target {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left").font(.system(size: 11))
                    Text("Replying to \(Text(Format.firstName(target.author, viewer: model.viewerLogin)).fontWeight(.semibold).foregroundStyle(.primary)) on \(Format.basename(target.path))")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    IconButton(symbol: "xmark", label: "Cancel thread reply", size: 20) { model.replyTargets[group.id] = nil }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .padding(.trailing, 4)
                .padding(.bottom, 6)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ComposerTextView(
                    text: draft, height: $height, focusToken: model.composerFocusToken,
                    onSubmit: { send(draft: draft) },
                    onFocusChange: { model.composerFocused = $0 }
                )
                .frame(height: height)
                .overlay(alignment: .topLeading) {
                    if draft.wrappedValue.isEmpty {
                        Text(target != nil ? "Reply in thread…" : group.thread.kind == .pullRequest ? "Reply to the conversation…" : "Reply…")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 5)
                            .allowsHitTesting(false)
                    }
                }
                Button { send(draft: draft) } label: {
                    Group {
                        if sending {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.accent))
                    .opacity(canSend || sending ? 1 : 0.3)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send reply")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: theme.isFluid ? 18 : 14, style: .continuous).fill(theme.inputBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.isFluid ? 18 : 14, style: .continuous)
                    .strokeBorder(model.composerFocused ? theme.accent.opacity(0.7) : theme.hairline, lineWidth: model.composerFocused ? 1 : 0.5)
            )
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.danger)
                    .padding(.top, 5)
                    .padding(.horizontal, 6)
            }
            HStack {
                Text("Return to send · Shift-Return for a new line")
                Spacer()
                Text("Esc to close")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.top, 5)
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
    }

    private func send(draft: Binding<String>) {
        let body = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        let target = model.replyTargets[group.id]
        sending = true
        error = nil
        Task {
            do throws(GitHubError) {
                onSent()
                try await model.store.reply(to: group.id, body: body, inReplyTo: target)
                draft.wrappedValue = ""
                model.replyTargets[group.id] = nil
            } catch {
                self.error = message(for: error)
            }
            sending = false
        }
    }

    private func message(for error: GitHubError) -> String {
        switch error {
        case .http(let status, let message): "Couldn't send (\(status))\(message.map { ": \($0)" } ?? "")"
        case .transport: "Couldn't reach GitHub. Your reply is kept."
        case .rateLimited: "Rate limited by GitHub. Try again shortly."
        case .auth(let auth): auth.instructions
        case .graphQL(let messages): messages.first ?? "Couldn't send."
        case .decoding: "Sent, but GitHub's response was unexpected."
        }
    }
}
