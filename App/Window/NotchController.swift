import AppKit
import GitokenCore
import SwiftUI

/// Owns the notch panel: keeps its frame matched to the SwiftUI content, tracks the host screen and
/// fullscreen spaces, closes on outside clicks, and routes keyboard input while the inbox is open.
@MainActor
final class NotchController {
    let model: NotchModel
    private let panel = NotchPanel()
    private let hosting: NSHostingView<PanelRoot>
    private var frameSize = CGSize(width: 300, height: 40)
    private var contentSize = CGSize(width: 300, height: 40)
    private var shrinkTask: Task<Void, Never>?
    private var frameUpdateScheduled = false
    private var fullscreenRecheck: Task<Void, Never>?
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var soundPolicy = SoundPolicy()
    private var hotKey: GlobalHotKey?

    init(store: InboxStore) {
        model = NotchModel(store: store)
        hosting = NSHostingView(rootView: PanelRoot(model: model, onSize: { _ in }))
        hosting.rootView = PanelRoot(model: model, onSize: { [weak self] in self?.contentSizeChanged($0) })
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        // A plain container owns the window's content size; the hosting view just fills it.
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.setAccessibilityLabel("Gitoken")

        refreshHost()
        installMonitors()
        installObservers()
        observeRoute()
        observeArrival()
        hotKey = GlobalHotKey(model: model) { [model] in model.toggleFromHotKey() }
        panel.orderFrontRegardless()
        updateFullscreen()
    }

    // MARK: Frame

    /// SwiftUI reports final (post-animation) layout sizes. Growing applies immediately; shrinking waits for the
    /// closing animation so it never gets clipped. Frames are applied on the next main-queue turn: resizing the
    /// window from inside SwiftUI's update pass re-enters AppKit's constraint pass and eventually throws.
    private func contentSizeChanged(_ size: CGSize) {
        let target = CGSize(width: ceil(size.width / 2) * 2, height: ceil(size.height))
        guard target.width > 0, target.height > 0, target != contentSize else { return }
        contentSize = target
        guard !frameUpdateScheduled else { return }
        frameUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameUpdateScheduled = false
            self.syncFrameToContent()
        }
    }

    private func syncFrameToContent() {
        let target = contentSize
        shrinkTask?.cancel()
        let grown = CGSize(width: max(frameSize.width, target.width), height: max(frameSize.height, target.height))
        if grown != frameSize { applyFrame(grown) }
        if grown != target {
            let settle = model.motion.settle
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: settle)
                guard !Task.isCancelled, let self else { return }
                self.applyFrame(self.contentSize)
            }
        }
    }

    private func applyFrame(_ size: CGSize) {
        frameSize = size
        let screen = model.host.frame
        let frame = NSRect(
            x: (screen.midX - size.width / 2).rounded(), y: screen.maxY - size.height,
            width: size.width, height: size.height
        )
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    // MARK: Host screen & fullscreen

    private func refreshHost() {
        let (host, _) = HostScreen.current()
        if host != model.host { model.host = host }
        applyFrame(frameSize)
    }

    private func updateFullscreen() {
        let covered = model.host.isCoveredByFullscreenWindow()
        if covered != model.hiddenForFullscreen {
            model.hiddenForFullscreen = covered
            if covered { model.close() }
        }
        if covered {
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// The window list settles after the space-switch animation; look again shortly after.
    private func scheduleFullscreenCheck() {
        updateFullscreen()
        fullscreenRecheck?.cancel()
        fullscreenRecheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.updateFullscreen()
        }
    }

    // MARK: Key focus

    private func observeRoute() {
        withObservationTracking {
            _ = model.route
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.routeChanged()
                self?.observeRoute()
            }
        }
    }

    private func routeChanged() {
        let open = model.route.isOpen
        panel.allowsKey = open
        if open {
            if !panel.isKeyWindow { panel.makeKey() }
        } else if panel.isKeyWindow {
            // Hand keyboard focus back to whatever app the user was typing in.
            panel.resignKey()
            panel.orderOut(nil)
            if !model.hiddenForFullscreen { panel.orderFrontRegardless() }
        }
    }

    // MARK: Arrival sound

    private func observeArrival() {
        withObservationTracking {
            _ = model.store.arrival
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.arrivalChanged()
                self?.observeArrival()
            }
        }
    }

    private func arrivalChanged() {
        let store = model.store
        guard let arrival = store.arrival else { return }
        let context = SoundPolicy.Context(
            settings: store.settings, quietReason: store.quietReason, hiddenForFullscreen: model.hiddenForFullscreen,
            panelOpen: model.route.isOpen)
        if let cue = soundPolicy.cue(for: arrival, context: context, now: store.now.now()) {
            model.sounds.play(cue.sound, volume: cue.volume, reason: "arrival \(arrival.id) ×\(arrival.updateCount)")
        } else {
            SoundPlayer.log.info("Silent: arrival \(arrival.id, privacy: .public) ×\(arrival.updateCount)")
        }
    }

    // MARK: Event monitors

    private func installMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.outsideClick()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleKey(event) ?? event
        }) {
            monitors.append(local)
        }
    }

    private func outsideClick() {
        if model.menu != nil { model.dismissMenu() }
        guard model.route.isOpen, !model.pinned else { return }
        model.close()
    }

    private enum Key {
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let up: UInt16 = 126
        static let down: UInt16 = 125
        static let left: UInt16 = 123
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
    }

    /// Returns nil when the event was consumed.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if model.isRecordingHotKey { return recordHotKey(event) }
        if event.keyCode == Key.escape {
            if model.menu != nil { model.dismissMenu() } else { model.close() }
            return nil
        }
        if model.menu != nil {
            switch event.keyCode {
            case Key.down: model.moveMenuHighlight(1)
            case Key.up: model.moveMenuHighlight(-1)
            case Key.returnKey, Key.enter: model.activateMenuHighlight()
            default: return event
            }
            return nil
        }
        if panel.firstResponder is NSTextView { return event }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let backShortcut = (flags == .command && chars == "[") || (flags.isEmpty && event.keyCode == Key.left)
        switch model.route {
        case .list:
            return handleListKey(event, chars: chars, flags: flags) ? nil : event
        case .conversation(let id):
            if backShortcut { model.back(); return nil }
            if flags.isEmpty, chars == "r" { model.requestComposerFocus(); return nil }
            if flags.isEmpty, chars == "d" || chars == "e" {
                if model.group(id)?.doneAt != nil { model.undoDone(id) } else { model.markDone(id) }
                return nil
            }
            if flags.isEmpty, chars == "u", model.toast?.undo != nil { model.performToastUndo(); return nil }
            return event
        case .settings:
            if backShortcut { model.back(); return nil }
            return event
        case .collapsed:
            return event
        }
    }

    /// Settings' shortcut recorder: Esc cancels, Delete disables the shortcut, a key with ⌘/⌥/⌃ becomes it.
    private func recordHotKey(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case Key.escape where flags.isEmpty:
            model.isRecordingHotKey = false
        case Key.delete, Key.forwardDelete:
            model.store.updateSettings { $0.hotKey = nil }
            model.isRecordingHotKey = false
        default:
            guard let hotKey = HotKey(event: event) else {
                NSSound.beep()
                return nil
            }
            model.store.updateSettings { $0.hotKey = hotKey }
            model.isRecordingHotKey = false
        }
        return nil
    }

    private func handleListKey(_ event: NSEvent, chars: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.subtracting(.numericPad).subtracting(.function).isEmpty else { return false }
        let store = model.store
        let rows = Buckets(store: store, now: store.now.now()).visible(showSnoozed: model.showSnoozed, showDone: model.showDone)
        let index = model.selectedRow.flatMap { id in rows.firstIndex { $0.id == id } }
        if event.keyCode == Key.down || chars == "j" {
            guard !rows.isEmpty else { return true }
            model.selectedRow = rows[min(rows.count - 1, (index ?? -1) + 1)].id
            return true
        }
        if event.keyCode == Key.up || chars == "k" {
            guard !rows.isEmpty else { return true }
            model.selectedRow = rows[max(0, (index ?? rows.count) - 1)].id
            return true
        }
        if event.keyCode == Key.returnKey || event.keyCode == Key.enter {
            if let index { model.open(.conversation(rows[index].id)) }
            return true
        }
        // U undoes the last action (done, snooze, mute) while its toast is up, else unsnoozes / restores the row.
        if chars == "u", model.toast?.undo != nil {
            model.performToastUndo()
            return true
        }
        guard let index else { return false }
        let group = rows[index]
        let bucket = group.bucket(at: store.now.now())
        switch chars {
        case "e", "d":
            let next = rows.indices.contains(index + 1) ? rows[index + 1].id : (index > 0 ? rows[index - 1].id : nil)
            if bucket == .done { model.undoDone(group.id) } else { model.markDone(group.id) }
            model.selectedRow = next
            return true
        case "s":
            if bucket == .new || bucket == .pending { model.presentSnoozeMenu(for: group.id) }
            return true
        case "u":
            if bucket == .snoozed { model.unsnooze(group.id) } else if bucket == .done { model.undoDone(group.id) }
            return true
        default:
            return false
        }
    }

    // MARK: Notifications

    private func installObservers() {
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.refreshHost(); $0.scheduleFullscreenCheck() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.scheduleFullscreenCheck() }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.scheduleFullscreenCheck() }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.model.systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (NotchController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }
}

/// Root of the hosting view: injects the UI model into the SwiftUI environment.
struct PanelRoot: View {
    let model: NotchModel
    var onSize: (CGSize) -> Void

    var body: some View {
        RootView(onSize: onSize).environment(model)
    }
}
