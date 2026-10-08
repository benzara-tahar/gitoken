import AppKit
import GitokenCore
import Observation
import SwiftUI

/// UI-only state for the notch surface. Inbox data and all GitHub-facing intents live in `InboxStore`.
@MainActor
@Observable
final class NotchModel {
    enum Route: Equatable {
        case collapsed
        case list
        case conversation(ThreadID)
        case searchConversation(SearchItemID)
        case settings

        var isOpen: Bool { self != .collapsed }
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var undo: (@MainActor () -> Void)?

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    let store: InboxStore
    let sounds = SoundPlayer()
    let previews: FilePreviewStore
    /// Set by `PreviewController` at launch.
    @ObservationIgnored weak var previewController: PreviewController?
    /// The reusable preview window is showing. Maintained by `PreviewController`.
    var isPreviewOpen = false

    private(set) var route: Route = .collapsed
    struct NavigationState {
        let history: [Route]
        let selectedRow: ThreadID?
        let selectedSearchRow: SearchRowID?
        let searchText: String
    }

    /// Open routes survive collapse; Back never removes the root inbox.
    @ObservationIgnored private var history: [Route] = [.list]
    @ObservationIgnored private var activeConversation: ThreadID?
    @ObservationIgnored private var visitStarted = false
    @ObservationIgnored private var visitGeneration = 0
    @ObservationIgnored private var conversationLoads: [ThreadID: (generation: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var activeSearchConversation: SearchItemID?
    @ObservationIgnored private var searchVisitGeneration = 0
    @ObservationIgnored private var searchLoads: [SearchItemID: (generation: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var searchSubjects: [SearchItemID: SearchItem] = [:]
    private var searchAccountLogin: String?
    private(set) var panelFocusToken = 0
    var host: HostScreen = .fallback
    var hiddenForFullscreen = false
    var systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var pinned = false
    var bannerHovered = false
    var showDone = false
    var showSnoozed = true
    var expandedDiffs: Set<String> = []
    var olderShown: Set<ThreadID> = []
    var drafts: [ThreadID: String] = [:]
    var replyTargets: [ThreadID: ReviewComment] = [:]
    var selectedRow: ThreadID? {
        didSet { if selectedRow != nil { selectedSearchRow = nil } }
    }
    var selectedSearchRow: SearchRowID? {
        didSet { if selectedSearchRow != nil { selectedRow = nil } }
    }
    var settingsTab: SettingsTab = .general
    var sectionDraft: CustomSection?
    var sectionPendingDeletion: CustomSection?
    var sectionQueryPreview: (id: UUID, query: String, page: SearchPage)?
    /// Inbox search text; preserved with the opened route when the panel collapses.
    var searchText = "" {
        didSet { if searchText != oldValue { searchChanged() } }
    }
    /// `searchText` parsed; empty when it holds no terms.
    private(set) var searchQuery = InboxQuery("")
    /// Bumped to move keyboard focus into the inbox search field.
    private(set) var searchFocusToken = 0
    /// The search field has keyboard focus (Down / Return move to the first result).
    var searchFocused = false
    var menu: PanelMenu?
    var menuHighlight: Int?
    var toast: Toast?
    var composerFocused = false
    /// Bumped to move keyboard focus into the reply composer.
    private(set) var composerFocusToken = 0
    /// Settings is capturing a new global shortcut; the current one is unregistered meanwhile.
    var isRecordingHotKey = false
    /// Another app already owns `settings.hotKey`.
    var hotKeyUnavailable = false

    func requestComposerFocus() { composerFocusToken += 1 }
    func requestSearchFocus() { searchFocusToken += 1 }
    /// Last known frames (surface space) of menu-opening controls, keyed by menu anchor id.
    @ObservationIgnored var anchorFrames: [String: CGRect] = [:]

    private var toastTask: Task<Void, Never>?

    init(store: InboxStore) {
        self.store = store
        previews = store.makeFilePreviewStore()
    }

    // MARK: Derived presentation

    var settings: AppSettings { store.settings }

    /// Pill when the user asks for it or the host screen has no notch.
    var isNotchAttached: Bool { host.hasNotch && settings.display == .notch }

    var motion: Motion {
        Motion(style: systemReduceMotion ? .reduced : settings.motion)
    }

    var theme: Theme { Theme(appearance: settings.appearance, notchAttached: isNotchAttached) }

    /// The arrival banner shows only while the surface is otherwise closed.
    var visibleArrival: Arrival? {
        guard route == .collapsed, !hiddenForFullscreen else { return nil }
        if case .blocked = store.phase { return nil }
        return store.arrival
    }

    var conversationID: ThreadID? {
        if case .conversation(let id) = route { return id }
        return nil
    }

    func group(_ id: ThreadID) -> InboxGroup? { store.groups.first { $0.id == id } }

    /// Inbox buckets filtered by the search; the list view and keyboard navigation both read this.
    func buckets() -> Buckets {
        let query = searchQuery
        return Buckets(store: store, now: store.now.now()) { group in
            query.isEmpty || query.matches(group, author: query.needsDetail ? self.subjectAuthor(group) : nil)
        }
    }

    /// Rows in keyboard-navigation order (filtered, honoring collapsed sections).
    var listRows: [InboxGroup] { buckets().visible(showSnoozed: showSnoozed, showDone: showDone) }

    /// A query change keeps the selection on a visible result.
    private func searchChanged() {
        searchQuery = InboxQuery(searchText)
        guard route == .list else { return }
        let rows = keyboardRows
        if let selection = listSelection, rows.contains(selection) { return }
        selectListRow(rows.first)
    }

    /// Subject authors read from the detail cache for `author:`, per thread activity, so renders don't hit the
    /// database; reset when the panel closes.
    @ObservationIgnored private var authorCache: [ThreadID: (activity: Date, author: Actor?)] = [:]

    private func subjectAuthor(_ group: InboxGroup) -> Actor? {
        if let author = store.conversations[group.id]?.detail?.author { return author }
        if let hit = authorCache[group.id], hit.activity == group.lastActivityAt { return hit.author }
        let author = store.detail(for: group.id)?.author
        authorCache[group.id] = (group.lastActivityAt, author)
        return author
    }

    var viewerLogin: String? {
        if case .ready(let viewer) = store.phase { return viewer.login }
        return nil
    }

    // MARK: Navigation

    var navigationState: NavigationState {
        NavigationState(history: history, selectedRow: selectedRow, selectedSearchRow: selectedSearchRow, searchText: searchText)
    }

    func toggleFromNotch() {
        if route.isOpen { close() } else { reopen() }
    }

    func reopen() {
        guard !route.isOpen, !hiddenForFullscreen else { return }
        transition(to: history.last ?? .list)
    }

    func open(_ next: Route) {
        guard next.isOpen else { close(); return }
        if let index = history.lastIndex(of: next) {
            history.removeSubrange((index + 1)..<history.count)
        } else {
            history.append(next)
        }
        transition(to: next)
    }

    func restoreNavigation(_ state: NavigationState) {
        history = state.history
        searchText = state.searchText
        selectedRow = state.selectedRow
        selectedSearchRow = state.selectedSearchRow
        guard !hiddenForFullscreen else { return }
        transition(to: history.last ?? .list)
    }

    func requestPanelFocus() { panelFocusToken += 1 }

    func close() {
        guard route.isOpen else { return }
        transition(to: .collapsed)
        authorCache = [:]
    }

    func back() {
        guard route.isOpen, history.count > 1 else { return }
        history.removeLast()
        transition(to: history.last ?? .list)
    }

    private func transition(to next: Route) {
        menu = nil
        menuHighlight = nil
        guard route != next else { syncConversationVisit(); return }
        composerFocused = false
        searchFocused = false
        isRecordingHotKey = false
        if next.isOpen { drainArrivals() }
        withAnimation(next.isOpen ? motion.open : motion.close) { route = next }
        if case .conversation(let id) = next { selectedRow = id }
        syncConversationVisit()
    }

    private func syncConversationVisit() {
        // Settings keeps its originating conversation's visit alive.
        var next: ThreadID?
        var nextSearch: SearchItemID?
        if route.isOpen {
            for candidate in history.reversed() {
                switch candidate {
                case .conversation(let id): next = id
                case .searchConversation(let id): nextSearch = id
                case .settings: continue
                case .list, .collapsed: break
                }
                break
            }
        }
        syncSearchVisit(nextSearch)
        guard next != activeConversation else { return }
        if let activeConversation, visitStarted { store.closeConversation(activeConversation) }
        activeConversation = next
        visitStarted = false
        visitGeneration += 1
        guard let next else { return }
        let generation = visitGeneration
        // A new visit waits for this thread's previous load to finish before hydrating again.
        let previousLoad = conversationLoads[next]?.task
        let task = Task { [weak self] in
            await previousLoad?.value
            guard let self else { return }
            guard self.activeConversation == next, self.visitGeneration == generation else {
                if self.conversationLoads[next]?.generation == generation { self.conversationLoads[next] = nil }
                return
            }
            self.visitStarted = true
            await self.store.openConversation(next)
            if self.conversationLoads[next]?.generation == generation { self.conversationLoads[next] = nil }
        }
        conversationLoads[next] = (generation, task)
    }

    private func syncSearchVisit(_ next: SearchItemID?) {
        if next == activeSearchConversation {
            if case .searchConversation = route, let next, let state = store.customSections.conversations[next],
               !state.isLoading, state.detail == nil, state.error == nil, let item = searchItem(next) {
                Task { await store.customSections.openConversation(item) }
            }
            return
        }
        if let activeSearchConversation { store.customSections.closeConversation(activeSearchConversation) }
        activeSearchConversation = next
        searchVisitGeneration += 1
        guard let next, let item = searchItem(next) else { return }
        let generation = searchVisitGeneration
        let previous = searchLoads[next]?.task
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.activeSearchConversation == next, self.searchVisitGeneration == generation else { return }
            await self.store.customSections.openConversation(item)
            if self.searchLoads[next]?.generation == generation { self.searchLoads[next] = nil }
        }
        searchLoads[next] = (generation, task)
    }

    func searchItem(_ id: SearchItemID) -> SearchItem? { store.customSections.item(id) ?? searchSubjects[id] }

    func openSearch(_ item: SearchItem) {
        searchSubjects[item.id] = item
        closePreview()
        open(.searchConversation(item.id))
    }

    func syncSearchAccount() {
        guard let login = viewerLogin, login != searchAccountLogin else { return }
        searchAccountLogin = login
        searchSubjects = [:]
        sectionQueryPreview = nil
        selectedSearchRow = nil
        history.removeAll { if case .searchConversation = $0 { true } else { false } }
        if case .searchConversation = route { transition(to: history.last ?? .list) }
    }

    func openSectionSettings() {
        settingsTab = .sections
        open(.settings)
    }

    /// Arrivals are announced only while the panel is closed; opening it consumes the queue.
    func drainArrivals() {
        var guardCount = 0
        while store.arrival != nil, guardCount < 50 {
            store.dismissArrival()
            guardCount += 1
        }
    }

    func openArrival(_ arrival: Arrival) {
        if let id = arrival.groupID {
            open(.conversation(id))
        } else {
            open(.list)
        }
    }

    // MARK: Group actions (store intent + UI feedback)

    func markDone(_ id: ThreadID) {
        withAnimation(motion.open) { store.markDone(id) }
        if conversationID == id { open(.list) }
        showToast("Marked done") { [weak self] in
            guard let self else { return }
            withAnimation(self.motion.open) { self.store.undoDone(id) }
        }
    }

    func undoDone(_ id: ThreadID) {
        withAnimation(motion.open) { store.undoDone(id) }
        showToast("Moved to Inbox")
    }

    func snooze(_ id: ThreadID, _ option: SnoozeOption) {
        let until = option.deadline(from: store.now.now())
        withAnimation(motion.open) { store.snooze(id, option) }
        if conversationID == id { open(.list) }
        showToast("Snoozed until \(Format.until(until, now: store.now.now()))") { [weak self] in
            guard let self else { return }
            withAnimation(self.motion.open) { self.store.unsnooze(id) }
        }
    }

    func unsnooze(_ id: ThreadID) {
        withAnimation(motion.open) { store.unsnooze(id) }
        showToast("Snooze removed")
    }

    func snoozeAll(_ option: SnoozeOption) {
        store.snoozeAll(option)
        let until = option.deadline(from: store.now.now())
        showToast("Notifications snoozed until \(Format.until(until, now: store.now.now()))")
    }

    func resumeAll() {
        store.endGlobalSnooze()
        showToast("Notifications resumed")
    }

    func toggleQuiet() {
        store.setManualQuiet(!store.manualQuiet)
        showToast(store.manualQuiet ? "Quiet mode on" : "Quiet mode off")
    }

    func openOnGitHub(_ id: ThreadID) {
        guard let g = group(id) else { return }
        NSWorkspace.shared.open(store.conversations[id]?.detail?.htmlURL ?? g.thread.htmlURL)
    }

    func copyLink(_ id: ThreadID) {
        guard let g = group(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(g.thread.htmlURL.absoluteString, forType: .string)
        showToast("Link copied")
    }

    // MARK: Toast

    func showToast(_ message: String, undo: (@MainActor () -> Void)? = nil) {
        toastTask?.cancel()
        withAnimation(motion.pop) { toast = Toast(message: message, undo: undo) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.2))
            guard !Task.isCancelled, let self else { return }
            withAnimation(self.motion.fade) { self.toast = nil }
        }
    }

    func performToastUndo() {
        guard let undo = toast?.undo else { return }
        toastTask?.cancel()
        withAnimation(motion.fade) { toast = nil }
        undo()
    }

    // MARK: File preview

    func previewTarget(for comment: ReviewComment, in group: InboxGroup) -> PreviewTarget? {
        guard let ref = pullRequestRef(group) else { return nil }
        return PreviewTarget(threadID: group.id, ref: ref, path: comment.path, commentID: comment.id)
    }

    /// The group's newest review comment, from conversation detail already in memory (never hydrates).
    func newestPreviewTarget(for id: ThreadID) -> PreviewTarget? {
        guard let g = group(id), let ref = pullRequestRef(g), let detail = store.detail(for: id) else { return nil }
        return PreviewTarget.newest(in: detail, threadID: id, ref: ref)
    }

    func openPreview(_ comment: ReviewComment, in group: InboxGroup) {
        guard let target = previewTarget(for: comment, in: group) else { return }
        previewController?.show(target)
    }

    func togglePreview() { previewController?.toggle() }

    func closePreview() { previewController?.close() }

    /// Hover / selection warm-up for the group's newest review comment.
    func prefetchPreview(for id: ThreadID) {
        guard let target = newestPreviewTarget(for: id) else { return }
        previews.prefetch(target)
    }

    func prefetchPreview(_ comment: ReviewComment, in group: InboxGroup) {
        guard let target = previewTarget(for: comment, in: group) else { return }
        previews.prefetch(target)
    }

    // MARK: Menus

    func presentMenu(_ menu: PanelMenu) {
        if self.menu?.anchorID == menu.anchorID {
            dismissMenu()
            return
        }
        withAnimation(motion.pop) {
            self.menu = menu
            menuHighlight = nil
        }
    }

    func dismissMenu() {
        withAnimation(.easeOut(duration: 0.12)) {
            menu = nil
            menuHighlight = nil
        }
    }

    func moveMenuHighlight(_ delta: Int) {
        guard let menu else { return }
        let actionable = menu.items.indices.filter { menu.items[$0].isActionable }
        guard !actionable.isEmpty else { return }
        if let current = menuHighlight, let pos = actionable.firstIndex(of: current) {
            menuHighlight = actionable[(pos + delta + actionable.count) % actionable.count]
        } else {
            menuHighlight = delta > 0 ? actionable.first : actionable.last
        }
    }

    func activateMenuHighlight() {
        guard let menu, let index = menuHighlight, menu.items.indices.contains(index) else { return }
        menu.items[index].perform(dismiss: dismissMenu)
    }

    static func snoozeMenuID(_ id: ThreadID) -> String { "row-snooze-\(id.rawValue)" }

    func presentSnoozeMenu(for id: ThreadID) {
        let key = Self.snoozeMenuID(id)
        presentMenu(PanelMenu(anchorID: key, anchor: anchorFrames[key] ?? .zero, items: snoozeMenuItems(for: id)))
    }

    // MARK: Menu builders

    func snoozeMenuItems(for id: ThreadID) -> [PanelMenu.Item] {
        let now = store.now.now()
        var items: [PanelMenu.Item] = []
        if let g = group(id), let until = g.snoozedUntil, until > now {
            items.append(.label("Snoozed until \(Format.until(until, now: now))"))
            items.append(.action("Unsnooze", symbol: "bell") { [weak self] in self?.unsnooze(id) })
            items.append(.separator)
        }
        items.append(.label("Snooze this conversation"))
        for option in SnoozeOption.allCases {
            items.append(.action(option.title, subtitle: Format.until(option.deadline(from: now), now: now), symbol: "clock") {
                [weak self] in self?.snooze(id, option)
            })
        }
        return items
    }

    func globalMenuItems() -> [PanelMenu.Item] {
        let now = store.now.now()
        var items: [PanelMenu.Item] = []
        if let until = store.globalSnoozeUntil, until > now {
            items.append(.label("Snoozed until \(Format.until(until, now: now))"))
            items.append(.action("Resume notifications", symbol: "bell") { [weak self] in self?.resumeAll() })
            items.append(.separator)
        }
        items.append(.label("Snooze all notifications"))
        for option in SnoozeOption.allCases {
            items.append(.action(option.title, subtitle: Format.until(option.deadline(from: now), now: now), symbol: "clock") {
                [weak self] in self?.snoozeAll(option)
            })
        }
        items.append(.separator)
        items.append(.action("Quiet mode", symbol: "moon", checked: store.manualQuiet) { [weak self] in self?.toggleQuiet() })
        let qh = settings.quietHours
        items.append(.action(
            "Quiet hours…", subtitle: qh.enabled ? "\(Format.clock(qh.start))–\(Format.clock(qh.end))" : "Off",
            symbol: "slider.horizontal.3"
        ) { [weak self] in self?.open(.settings) })
        return items
    }

    /// Status line for the list footer / settings while arrivals are suppressed.
    var quietStatus: String? {
        guard let reason = store.quietReason else { return nil }
        let now = store.now.now()
        switch reason {
        case .globalSnooze(let until): return "Notifications snoozed until \(Format.until(until, now: now))"
        case .manual: return "Quiet mode is on — activity collects silently"
        case .quietHours(let until): return "Quiet hours until \(Format.clock(until))"
        }
    }
}
