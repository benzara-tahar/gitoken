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

    private(set) var route: Route = .collapsed
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
    var selectedRow: ThreadID?
    var menu: PanelMenu?
    var menuHighlight: Int?
    var toast: Toast?
    var composerFocused = false
    /// Bumped to move keyboard focus into the reply composer.
    private(set) var composerFocusToken = 0

    func requestComposerFocus() { composerFocusToken += 1 }
    /// Last known frames (surface space) of menu-opening controls, keyed by menu anchor id.
    @ObservationIgnored var anchorFrames: [String: CGRect] = [:]

    private var toastTask: Task<Void, Never>?

    init(store: InboxStore) {
        self.store = store
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

    var viewerLogin: String? {
        if case .ready(let viewer) = store.phase { return viewer.login }
        return nil
    }

    // MARK: Navigation

    func toggleFromNotch() {
        if route.isOpen { close() } else { open(.list) }
    }

    func open(_ next: Route) {
        let previous = route
        menu = nil
        menuHighlight = nil
        if previous == next { return }
        if case .conversation(let old) = previous { store.closeConversation(old) }
        if next.isOpen { drainArrivals() }
        withAnimation(motion.open) { route = next }
        if case .conversation(let id) = next {
            selectedRow = id
            Task { await store.openConversation(id) }
        }
    }

    func close() {
        guard route.isOpen else { return }
        if case .conversation(let id) = route { store.closeConversation(id) }
        menu = nil
        menuHighlight = nil
        composerFocused = false
        withAnimation(motion.close) { route = .collapsed }
    }

    func back() {
        open(.list)
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
