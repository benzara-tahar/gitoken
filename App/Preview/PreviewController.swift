import AppKit
import GitokenCore
import Observation
import SwiftUI

/// Owns the preview windows: one reusable window that follows the inbox selection / open conversation while it is
/// showing, plus any number of pinned copies that never retarget. Routes keyboard input aimed at them.
@MainActor
final class PreviewController {
    private let notch: NotchModel
    private weak var notchWindow: NSWindow?
    private var main: PreviewWindow?
    private var pinned: [PreviewWindow] = []
    /// Size the user last resized a preview to (this session).
    private var lastSize: CGSize?
    /// Inbox group the reusable window currently follows.
    private var followedGroup: ThreadID?
    private var monitor: Any?

    private enum Key {
        static let escape: UInt16 = 53
        static let up: UInt16 = 126
        static let down: UInt16 = 125
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
    }

    init(notch: NotchModel, notchWindow: NSWindow) {
        self.notch = notch
        self.notchWindow = notchWindow
        notch.previewController = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        observeFollow()
        observeAppearance()
    }

    var isOpen: Bool { main?.panel.isVisible == true }

    var hasKeyWindow: Bool {
        main?.panel.isKeyWindow == true || pinned.contains { $0.panel.isKeyWindow }
    }

    func containsVisibleWindow(at point: NSPoint) -> Bool {
        if let main, main.panel.isVisible, main.panel.frame.contains(point) { return true }
        return pinned.contains { $0.panel.isVisible && $0.panel.frame.contains(point) }
    }

    // MARK: Intents

    /// Space in the inbox or conversation.
    func toggle() {
        if isOpen {
            close()
            return
        }
        let group = focusedGroup
        followedGroup = group
        apply(followTarget(for: group), to: presentMain().model)
    }

    /// The Preview button / file chip on a review comment.
    func show(_ target: PreviewTarget) {
        followedGroup = target.threadID
        presentMain().model.show(target)
    }

    /// The conversation's Files button: the file list on, at the newest review comment's file or the first changed file.
    func showFiles(for group: ThreadID) {
        guard let g = notch.group(group), let ref = notch.pullRequestRef(g) else { return }
        followedGroup = group
        presentMain().model.showFiles(threadID: group, ref: ref, preferred: notch.newestPreviewTarget(for: group))
    }

    func close() {
        guard let main else { return }
        close(main)
    }

    // MARK: Windows

    private func presentMain() -> PreviewWindow {
        let window = main ?? makeWindow(pinned: false)
        main = window
        if !window.panel.isVisible {
            window.origin = notch.navigationState
            window.panel.setFrame(initialFrame(), display: false)
            window.panel.orderFrontRegardless()
        }
        notch.isPreviewOpen = true
        window.panel.makeKey()
        return window
    }

    private func makeWindow(pinned: Bool, frame: NSRect? = nil) -> PreviewWindow {
        let window = PreviewWindow(notch: notch, pinned: pinned, frame: frame ?? initialFrame())
        window.model.onPin = { [weak self, weak window] in
            guard let self, let window else { return }
            self.pin(window)
        }
        window.model.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.close(window)
        }
        window.onClose = { [weak self] in self?.close($0) }
        window.onResize = { [weak self] in self?.lastSize = $0 }
        window.applyAppearance(isFluid: notch.theme.isFluid)
        return window
    }

    private func pin(_ source: PreviewWindow) {
        let frame = source.panel.frame.offsetBy(dx: 28, dy: -28)
        let window = makeWindow(pinned: true, frame: frame)
        window.origin = source.origin
        window.model.adopt(source.model)
        pinned.append(window)
        window.panel.orderFrontRegardless()
        window.panel.makeKey()
    }

    private func close(_ window: PreviewWindow) {
        guard window.panel.isVisible else { return }
        lastSize = window.panel.frame.size
        window.panel.orderOut(nil)
        if window === main {
            window.model.cancelReply()
            window.model.cancelNewComment()
            window.model.popover = nil
            notch.isPreviewOpen = false
        } else {
            pinned.removeAll { $0 === window }
        }
        notch.restoreNavigation(window.origin)
        notch.requestPanelFocus()
    }

    /// Use side space when it fits; otherwise overlap the notch at a usable, centered width.
    private func initialFrame() -> NSRect {
        let screen = notchWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        let margin: CGFloat = 8, gap: CGFloat = 12
        var size = lastSize ?? CGSize(width: 780, height: (visible.height * 0.7).rounded())
        size.width = min(max(size.width, PreviewPanel.minSize.width), visible.width - 2 * margin)
        size.height = min(max(size.height, PreviewPanel.minSize.height), visible.height - 2 * margin)
        let anchor = notchWindow?.frame ?? NSRect(x: visible.midX, y: visible.maxY, width: 0, height: 0)
        let rightRoom = visible.maxX - margin - (anchor.maxX + gap)
        let leftRoom = anchor.minX - gap - (visible.minX + margin)
        var x: CGFloat
        if size.width <= rightRoom {
            x = anchor.maxX + gap
        } else if size.width <= leftRoom {
            x = anchor.minX - gap - size.width
        } else {
            x = visible.midX - size.width / 2
        }
        x = min(max(x, visible.minX + margin), visible.maxX - margin - size.width)
        return NSRect(x: x.rounded(), y: (visible.maxY - margin - size.height).rounded(), width: size.width, height: size.height)
    }

    // MARK: Following the selection

    /// The open conversation, else the selected inbox row.
    private var focusedGroup: ThreadID? { notch.conversationID ?? notch.selectedRow }

    private enum Follow {
        case target(PreviewTarget)
        /// A review request without review comments: its changed files.
        case files(ThreadID, PullRequestRef)
        case empty(String)
    }

    private func followTarget(for group: ThreadID?) -> Follow {
        guard let group else { return .empty("Select a conversation with review comments") }
        guard let g = notch.group(group), let ref = notch.pullRequestRef(g) else {
            return .empty("Only pull requests have file previews")
        }
        if let target = notch.newestPreviewTarget(for: group) { return .target(target) }
        if g.thread.reason == .reviewRequested { return .files(group, ref) }
        guard notch.store.detail(for: group) != nil else {
            return .empty("Open this conversation once to load its review comments")
        }
        return .empty("No review comments in this pull request")
    }

    private func apply(_ follow: Follow, to model: PreviewModel) {
        switch follow {
        case .target(let target): model.show(target)
        case .files(let group, let ref): model.showFiles(threadID: group, ref: ref, preferred: nil)
        case .empty(let message): model.show(nil, emptyMessage: message)
        }
    }

    private func observeFollow() {
        withObservationTracking {
            let group = focusedGroup
            if notch.isPreviewOpen { _ = followTarget(for: group) }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.follow()
                self.observeFollow()
            }
        }
    }

    /// Retargets the reusable window when the focused group changes, or when the followed group's review comments
    /// arrive while it shows the empty state. New comments in the same group never yank the view.
    private func follow() {
        guard isOpen, let main, let group = focusedGroup else { return }
        if group != followedGroup {
            followedGroup = group
            apply(followTarget(for: group), to: main.model)
        } else if main.model.target == nil, main.model.pullRequest == nil {
            apply(followTarget(for: group), to: main.model)
        }
    }

    private func observeAppearance() {
        withObservationTracking {
            _ = notch.theme.isFluid
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let fluid = self.notch.theme.isFluid
                for window in [self.main].compactMap({ $0 }) + self.pinned { window.applyAppearance(isFluid: fluid) }
                self.observeAppearance()
            }
        }
    }

    // MARK: Keyboard

    /// Returns nil when the event was consumed.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let window: PreviewWindow
        if let main, main.panel === event.window {
            window = main
        } else if let copy = pinned.first(where: { $0.panel === event.window }) {
            window = copy
        } else {
            return event
        }
        let model = window.model
        let panel = window.panel
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let responder = panel.firstResponder as? NSView
        let editing = (responder as? NSTextView)?.isEditable == true
        let code = model.codeTextView
        // Reply and new-comment composers live inside cards, which are subviews of the code view; the find field and
        // the popovers are not.
        let inComposer = editing && code.map { responder?.isDescendant(of: $0) == true } == true

        if event.keyCode == Key.escape, flags.isEmpty {
            if (responder as? NSTextView)?.hasMarkedText() == true { return event }
            if model.popover != nil {
                model.popover = nil
                if let code { panel.makeFirstResponder(code) }
            } else if inComposer {
                if model.newCommentFocused { model.cancelNewComment() } else { model.cancelReply() }
                if let code { panel.makeFirstResponder(code) }
            } else if let code, code.isFindBarVisible {
                code.performFind(.hideFindInterface)
            } else {
                close(window)
            }
            return nil
        }
        if flags == .command, event.keyCode == Key.returnKey || event.keyCode == Key.enter, inComposer, model.newCommentFocused {
            if model.hasPendingReview {
                NSSound.beep()
            } else {
                Task { await model.postNewComment(now: true) }
            }
            return nil
        }
        if flags == .command {
            switch chars {
            case "f": code?.performFind(.showFindInterface)
            case "g": code?.performFind(.nextMatch)
            case "w": close(window)
            default: return event
            }
            return nil
        }
        if flags == [.command, .shift], chars == "g" {
            code?.performFind(.previousMatch)
            return nil
        }
        if editing || !flags.isEmpty { return event }
        if event.keyCode == Key.down || chars == "j" {
            model.moveFocus(1)
        } else if event.keyCode == Key.up || chars == "k" {
            model.moveFocus(-1)
        } else {
            switch chars {
            case "d": model.setMode(.diff)
            case "f": model.setMode(.file)
            case " ": close(window)
            case "r": if !model.startReply() { NSSound.beep() }
            case "b": if model.isPinned || model.pullRequest == nil { NSSound.beep() } else { model.toggleSidebar() }
            case "n": if !model.moveFile(1) { NSSound.beep() }
            case "p": if !model.moveFile(-1) { NSSound.beep() }
            default: return event
            }
        }
        return nil
    }
}

/// One preview panel with its model and hosting view.
@MainActor
final class PreviewWindow: NSObject, NSWindowDelegate {
    let panel: PreviewPanel
    let model: PreviewModel
    var origin: NotchModel.NavigationState
    private let hosting: PreviewHostingView
    var onClose: ((PreviewWindow) -> Void)?
    var onResize: ((CGSize) -> Void)?

    init(notch: NotchModel, pinned: Bool, frame: NSRect) {
        model = PreviewModel(notch: notch, pinned: pinned)
        origin = notch.navigationState
        panel = PreviewPanel(contentRect: frame)
        hosting = PreviewHostingView(rootView: PreviewWindowRoot(model: model))
        super.init()
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.delegate = self
        panel.setAccessibilityLabel(pinned ? "Pinned file preview" : "File preview")
        observeSidebar()
    }

    /// The file list adds to the minimum width; a narrower window grows, staying on its screen.
    private func observeSidebar() {
        withObservationTracking {
            _ = model.isSidebarVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyMinimumWidth()
                self.observeSidebar()
            }
        }
    }

    /// The window's current minimum (the file list widens it).
    private var minimumSize: NSSize {
        let extra = model.isSidebarVisible ? PreviewModel.sidebarWidth : 0
        return NSSize(width: PreviewPanel.minSize.width + extra, height: PreviewPanel.minSize.height)
    }

    private func applyMinimumWidth() {
        let minimum = minimumSize
        var frame = panel.frame
        guard frame.width < minimum.width, let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let margin: CGFloat = 8
        frame.size.width = min(minimum.width, visible.width - 2 * margin)
        frame.origin.x = min(max(frame.origin.x, visible.minX + margin), visible.maxX - margin - frame.width)
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    /// Enforced here rather than with `minSize`, which the hosting view resets when its content changes.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = minimumSize
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

    func applyAppearance(isFluid: Bool) {
        panel.appearance = isFluid ? NSAppearance(named: .darkAqua) : nil
        panel.backgroundColor = isFluid ? NSColor(white: 0.06, alpha: 1) : .windowBackgroundColor
    }

    /// The close button hides through the controller (focus hand-back, pinned bookkeeping).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?(self)
        return false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        onResize?(panel.frame.size)
    }
}
