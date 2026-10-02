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

    var body: some View {
        let store = model.store
        let now = store.now.now()
        let buckets = Buckets(store: store, now: now)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                summary(buckets)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }

            ScrollViewReader { proxy in
                ScrollView {
                    sections(buckets, now: now)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollIndicators(.automatic)
                .frame(height: max(60, min(contentHeight, maxHeight - chromeHeight - footerHeight)))
                .onChange(of: model.selectedRow) { _, id in
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
    }

    private var footerHeight: CGFloat {
        var h: CGFloat = 0
        if model.quietStatus != nil { h += 36 }
        if model.store.lastSyncError != nil { h += 30 }
        return h
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
            if b.new.isEmpty && b.pending.isEmpty {
                EmptyInbox()
            }
            section(.new, title: "New", groups: b.new, now: now)
            section(.pending, title: "Pending", groups: b.pending, now: now)
            if !b.snoozed.isEmpty {
                SectionHeader(title: "Snoozed", count: b.snoozed.count, expanded: model.showSnoozed) {
                    withAnimation(motion.open) { model.showSnoozed.toggle() }
                }
                .id("section-snoozed")
                if model.showSnoozed {
                    ForEach(b.snoozed) { InboxRow(group: $0, bucket: .snoozed, now: now).id($0.id) }
                }
            }
            if !b.done.isEmpty {
                SectionHeader(title: "Done", count: b.done.count, expanded: model.showDone) {
                    withAnimation(motion.open) { model.showDone.toggle() }
                }
                .id("section-done")
                if model.showDone {
                    ForEach(b.done) { InboxRow(group: $0, bucket: .done, now: now).id($0.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ bucket: InboxBucket, title: String, groups: [InboxGroup], now: Date) -> some View {
        if !groups.isEmpty {
            SectionHeader(title: title, count: groups.count, expanded: nil, toggle: nil)
                .id("section-\(bucket.rawValue)")
            ForEach(groups) { InboxRow(group: $0, bucket: bucket, now: now).id($0.id) }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let error = model.store.lastSyncError {
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

/// Groups split into the four buckets, sorted like the prototype.
struct Buckets {
    var new: [InboxGroup]
    var pending: [InboxGroup]
    var snoozed: [InboxGroup]
    var done: [InboxGroup]

    @MainActor
    init(store: InboxStore, now: Date) {
        new = store.groups(in: .new).sorted { $0.lastActivityAt > $1.lastActivityAt }
        pending = store.groups(in: .pending).sorted { $0.lastActivityAt > $1.lastActivityAt }
        snoozed = store.groups(in: .snoozed).sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
        done = store.groups(in: .done).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

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
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.success)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.chipBackground))
                .padding(.bottom, 6)
            Text("All caught up").font(.system(size: 13, weight: .semibold))
            Text("New activity will land here.").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }
}
