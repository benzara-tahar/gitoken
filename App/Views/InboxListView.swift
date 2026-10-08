import GitokenCore
import SwiftUI

struct InboxListView: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    var width: CGFloat
    var maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0
    @State private var atTop = true
    @State private var lastScrollAt: Date = .distantPast
    @State private var visibleRows: Set<ThreadID> = []
    /// Rows that just moved up with new activity; flash-highlighted briefly.
    @State private var flashed: Set<ThreadID> = []
    /// Topmost updated row while it is off screen and the user is mid-scroll.
    @State private var pendingUpdate: (id: ThreadID, count: Int)?

    /// The list follows new activity only after the user stopped scrolling for this long.
    private static let idleBeforeFollowing: TimeInterval = 1.5

    var body: some View {
        let store = model.store
        let now = store.now.now()
        let buckets = model.buckets()
        let viewportHeight = max(60, maxHeight - chromeHeight - footerHeight)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                InboxSearchField()
                summary(buckets)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }

            ScrollViewReader { proxy in
                ScrollView {
                    sections(buckets, now: now)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .onGeometryChange(for: CGFloat.self) { min($0.size.height, viewportHeight) } action: { contentHeight = $0 }
                }
                .scrollIndicators(.automatic)
                .frame(height: max(60, min(contentHeight, viewportHeight)))
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top < 24 } action: { _, top in
                    atTop = top
                    if top { pendingUpdate = nil }
                }
                .onScrollPhaseChange { _, phase in
                    if phase != .idle { lastScrollAt = Date() }
                }
                .overlay(alignment: .top) {
                    if let pending = pendingUpdate, !visibleRows.contains(pending.id) {
                        NewActivityPill(label: "\(pending.count) updated", symbol: "arrow.up") {
                            follow(pending.id, proxy: proxy)
                        }
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .onChange(of: Self.activity(buckets)) { old, new in
                    updated(old: old, new: new, order: (buckets.new + buckets.pending).map(\.id), proxy: proxy)
                }
                .onChange(of: model.selectedRow) { _, id in
                    guard let id else { return }
                    model.prefetchPreview(for: id)
                    withAnimation(motion.fade) { proxy.scrollTo(id, anchor: nil) }
                }
                .onChange(of: model.selectedSearchRow) { _, id in
                    guard let id else { return }
                    withAnimation(motion.fade) { proxy.scrollTo(id, anchor: nil) }
                }
                .environment(\.listScroll, ListScrollAction { section in
                    withAnimation(motion.open) { proxy.scrollTo("section-\(section.rawValue)", anchor: .top) }
                })
            }
            footer
        }
        .frame(width: width)
        .task(id: model.settings.customSections.map { "\($0.id):\($0.query)" }.joined(separator: "\n")) {
            guard !model.settings.customSections.isEmpty else { return }
            await model.store.customSections.refreshAll()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                await model.store.customSections.refreshAll()
            }
        }
    }

    private var footerHeight: CGFloat {
        var h: CGFloat = 0
        if model.quietStatus != nil { h += 36 }
        if model.store.lastSyncError != nil, !showsConnectionEmpty { h += 30 }
        return h
    }

    private var showsConnectionEmpty: Bool {
        model.store.lastSyncError != nil && model.store.groups.isEmpty &&
            !model.settings.customSections.contains {
                !(model.store.customSections.results[$0.id]?.page.items.isEmpty ?? true)
            }
    }

    private var quietEmptyTitle: String {
        if case .globalSnooze = model.store.quietReason { return "Notifications are snoozed" }
        return "Quiet inbox"
    }

    // MARK: Following new activity

    private static func activity(_ b: Buckets) -> [ThreadID: Date] {
        Dictionary((b.new + b.pending).map { ($0.id, $0.lastActivityAt) }, uniquingKeysWith: max)
    }

    /// A group got new activity (it moves to the top): flash it, and bring it into view — right away when the user
    /// isn't scrolling, otherwise via the "updated ↑" pill.
    private func updated(old: [ThreadID: Date], new: [ThreadID: Date], order: [ThreadID], proxy: ScrollViewProxy) {
        let changed = order.filter { id in
            guard let at = new[id] else { return false }
            return old[id].map { $0 < at } ?? !old.isEmpty
        }
        guard let top = changed.first else { return }
        flash(Set(changed))
        guard !atTop, !visibleRows.contains(top) else { return }
        if Date().timeIntervalSince(lastScrollAt) >= Self.idleBeforeFollowing {
            follow(top, proxy: proxy)
        } else {
            withAnimation(motion.isReduced ? nil : .easeOut(duration: 0.2)) {
                pendingUpdate = (top, (pendingUpdate?.count ?? 0) + changed.count)
            }
        }
    }

    private func follow(_ id: ThreadID, proxy: ScrollViewProxy) {
        withAnimation(motion.isReduced ? nil : motion.open) {
            proxy.scrollTo(id, anchor: .top)
            pendingUpdate = nil
        }
        flash([id])
    }

    private func flash(_ ids: Set<ThreadID>) {
        flashed.formUnion(ids)
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(motion.isReduced ? nil : .easeOut(duration: 0.5)) { flashed.subtract(ids) }
        }
    }

    private func row(_ group: InboxGroup, bucket: InboxBucket, now: Date) -> some View {
        InboxRow(group: group, bucket: bucket, now: now)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.accent.opacity(flashed.contains(group.id) ? 0.14 : 0))
            }
            .id(group.id)
            .onScrollVisibilityChange(threshold: 0.5) { visible in
                if visible {
                    visibleRows.insert(group.id)
                    if pendingUpdate?.id == group.id { pendingUpdate = nil }
                } else {
                    visibleRows.remove(group.id)
                }
            }
    }

    // MARK: Header

    private var header: some View {
        SurfaceHeader(width: width) {
            if !(theme.isFluid && theme.notchAttached) {
                GitokenMark(size: 15, color: theme.accent).padding(.trailing, 5)
            }
            Text("Inbox").font(.system(size: 13.5, weight: .semibold))
        } trailing: {
            MenuIconButton(
                id: "global-snooze", symbol: bellSymbol, label: "Snooze and quiet options",
                active: model.store.quietReason != nil
            ) { model.globalMenuItems() }
            IconButton(symbol: "rectangle.stack.badge.plus", label: "Custom sections") { model.openSectionSettings() }
            IconButton(symbol: "slider.horizontal.3", label: "Settings") { model.open(.settings) }
        }
    }

    private var bellSymbol: String {
        switch model.store.quietReason {
        case .globalSnooze: "bell.slash"
        case .some: "moon"
        case nil: "bell"
        }
    }

    private func summary(_ b: Buckets) -> some View {
        HStack(spacing: 5) {
            SummaryChip(count: b.new.count, label: "new", dot: true, section: .new)
            SummaryChip(count: b.pending.count, label: "pending", section: .pending)
            if !b.snoozed.isEmpty {
                SummaryChip(count: b.snoozed.count, label: "snoozed", symbol: "clock", section: .snoozed)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: Sections

    @ViewBuilder
    private func sections(_ b: Buckets, now: Date) -> some View {
        LazyVStack(alignment: .leading, spacing: theme.isFluid ? 6 : 1) {
            ForEach(model.settings.customSections) { CustomInboxSection(section: $0) }
            if showsConnectionEmpty, let error = model.store.lastSyncError {
                VStack(spacing: 0) {
                    EmptyInbox(artwork: .connectionError, title: "Unable to load your inbox", message: syncErrorText(error))
                    PillButton(title: "Retry", symbol: "arrow.clockwise", kind: .primary) {
                        Task { await model.store.refresh() }
                    }
                    .padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity)
            } else if model.searchQuery.isEmpty {
                if b.new.isEmpty, b.pending.isEmpty, model.settings.customSections.isEmpty,
                   !(model.showSnoozed && !b.snoozed.isEmpty), !(model.showDone && !b.done.isEmpty) {
                    if model.store.quietReason != nil || !b.snoozed.isEmpty {
                        EmptyInbox(
                            artwork: .quiet,
                            title: quietEmptyTitle,
                            message: model.store.quietReason == nil
                                ? "Snoozed conversations will return when their timers end."
                                : "New activity will collect silently.")
                    } else if b.done.isEmpty {
                        EmptyInbox(artwork: .empty, title: "Your inbox is empty")
                    } else {
                        EmptyInbox()
                    }
                }
            } else if b.isEmpty, !model.settings.customSections.contains(where: { !model.customItems(in: $0.id).isEmpty }) {
                NoMatches()
            }
            section(.new, title: "New", groups: b.new, now: now)
            section(.pending, title: "Pending", groups: b.pending, now: now)
            if !b.snoozed.isEmpty {
                SectionHeader(title: "Snoozed", count: b.snoozed.count, expanded: model.showSnoozed) {
                    withAnimation(motion.open) { model.showSnoozed.toggle() }
                }
                .id("section-snoozed")
                if model.showSnoozed {
                    ForEach(b.snoozed) { row($0, bucket: .snoozed, now: now) }
                }
            }
            if !b.done.isEmpty {
                SectionHeader(title: "Done", count: b.done.count, expanded: model.showDone) {
                    withAnimation(motion.open) { model.showDone.toggle() }
                }
                .id("section-done")
                if model.showDone {
                    ForEach(b.done) { row($0, bucket: .done, now: now) }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ bucket: InboxBucket, title: String, groups: [InboxGroup], now: Date) -> some View {
        if !groups.isEmpty {
            SectionHeader(title: title, count: groups.count, expanded: nil, toggle: nil)
                .id("section-\(bucket.rawValue)")
            ForEach(groups) { row($0, bucket: bucket, now: now) }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let error = model.store.lastSyncError, !showsConnectionEmpty {
            HStack(spacing: 7) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(theme.warn)
                Text(syncErrorText(error)).lineLimit(1)
                Spacer(minLength: 4)
                Button("Retry") { Task { await model.store.refresh() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .overlay(alignment: .top) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
        }
        if let status = model.quietStatus, let reason = model.store.quietReason {
            HStack(spacing: 7) {
                Image(systemName: "moon.fill").font(.system(size: 11)).foregroundStyle(theme.quiet)
                Text(status).lineLimit(1)
                Spacer(minLength: 4)
                Button(footerAction(reason).title) { footerAction(reason).run() }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: 36)
            .overlay(alignment: .top) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
        }
    }

    private func footerAction(_ reason: QuietReason) -> (title: String, run: () -> Void) {
        switch reason {
        case .globalSnooze: ("Resume", { model.resumeAll() })
        case .manual: ("Turn off", { model.toggleQuiet() })
        case .quietHours: ("Settings", { model.open(.settings) })
        }
    }

    private func syncErrorText(_ error: GitHubError) -> String {
        switch error {
        case .rateLimited(let reset?): "Rate limited until \(Format.time(reset))"
        case .rateLimited: "Rate limited by GitHub"
        case .transport: "Offline — will retry"
        default: "Couldn't sync with GitHub"
        }
    }
}

/// A reference snapshot keeps SwiftUI from recursively comparing every group's payload in view closures.
final class Buckets {
    let new: [InboxGroup]
    let pending: [InboxGroup]
    let snoozed: [InboxGroup]
    let done: [InboxGroup]

    @MainActor
    init(store: InboxStore, now: Date, include: (InboxGroup) -> Bool = { _ in true }) {
        new = store.groups(in: .new).filter(include).sorted { $0.lastActivityAt > $1.lastActivityAt }
        pending = store.groups(in: .pending).filter(include).sorted { $0.lastActivityAt > $1.lastActivityAt }
        snoozed = store.groups(in: .snoozed).filter(include).sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
        done = store.groups(in: .done).filter(include).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    var isEmpty: Bool { new.isEmpty && pending.isEmpty && snoozed.isEmpty && done.isEmpty }

    /// Rows in visual order, honoring collapsed sections (keyboard navigation order).
    func visible(showSnoozed: Bool, showDone: Bool) -> [InboxGroup] {
        new + pending + (showSnoozed ? snoozed : []) + (showDone ? done : [])
    }
}

struct ListScrollAction {
    var scroll: (InboxBucket) -> Void
    init(_ scroll: @escaping (InboxBucket) -> Void) { self.scroll = scroll }
    func callAsFunction(_ bucket: InboxBucket) { scroll(bucket) }
}

nonisolated private struct ListScrollKey: EnvironmentKey {
    static let defaultValue: ListScrollAction? = nil
}

extension EnvironmentValues {
    var listScroll: ListScrollAction? {
        get { self[ListScrollKey.self] }
        set { self[ListScrollKey.self] = newValue }
    }
}

private struct SummaryChip: View {
    @Environment(\.theme) private var theme
    @Environment(\.listScroll) private var scroll
    var count: Int
    var label: String
    var dot = false
    var symbol: String?
    var section: InboxBucket
    @State private var hovering = false

    var body: some View {
        Button { scroll?(section) } label: {
            HStack(spacing: 4) {
                if dot { Circle().fill(theme.accent).frame(width: 6, height: 6) }
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text("\(count)")
                    .fontWeight(.semibold)
                    .foregroundStyle(dot ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText(value: Double(count)))
                Text(label)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(hovering ? Color.primary.opacity(0.1) : theme.chipBackground))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(count) \(label)")
        .accessibilityHint("Scrolls to the \(label) section")
    }
}

private struct EmptyInbox: View {
    var artwork: InboxArtwork = .caughtUp
    var title = "All caught up"
    var message = "New activity will land here."

    var body: some View {
        VStack(spacing: 4) {
            InboxIllustration(artwork).padding(.bottom, 6)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }
}

/// Inbox search (`/` focuses it). Esc clears the text first; Down / Return move to the first result (NotchController).
private struct InboxSearchField: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(focused ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.tertiary))
                TextField("Search", text: $model.searchText, prompt: Text("Search inbox"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .accessibilityLabel("Search inbox")
                if !model.searchText.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", label: "Clear search", size: 20) { model.searchText = "" }
                } else if !focused {
                    Text("/")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(theme.hairline))
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 4)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: theme.isFluid ? 14 : 8, style: .continuous).fill(theme.inputBackground))
            .overlay(
                RoundedRectangle(cornerRadius: theme.isFluid ? 14 : 8, style: .continuous)
                    .strokeBorder(focused ? theme.accent.opacity(0.7) : theme.hairline, lineWidth: focused ? 1 : 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            if focused && model.searchText.isEmpty {
                SearchHints()
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onChange(of: model.searchFocusToken) { focused = true }
        .onChange(of: focused) { _, now in model.searchFocused = now }
    }
}

/// Qualifier cheat sheet shown while the search field is focused and empty.
private struct SearchHints: View {
    @Environment(\.theme) private var theme
    private static let hints = ["repo:", "author:", "reason:", "is:unread", "is:pr", "-negate"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.hints, id: \.self) { hint in
                Text(hint)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.chipBackground))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search qualifiers: repo, author, reason, is unread, is pr; prefix with a dash to exclude")
    }
}

private struct NoMatches: View {
    @Environment(NotchModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            InboxIllustration(.noSearchResults).padding(.bottom, 6)
            Text("No matches").font(.system(size: 13, weight: .semibold))
            Text("Nothing in your inbox matches this search.").font(.system(size: 12)).foregroundStyle(.tertiary)
            PillButton(title: "Clear", kind: .ghost) { model.searchText = "" }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }
}
