import AppKit
import GitokenCore
import SwiftUI

/// Owns the PR Shelf panel: fits it to the SwiftUI content in its corner, moves it while the circle is dragged and
/// snaps it to the nearest corner, hides it during fullscreen spaces, and turns `ShelfStore.pulse` into a bounce
/// plus the arrival sound.
@MainActor
final class ShelfController {
    let model: ShelfModel
    private let panel = ShelfPanel()
    private let hosting: ShelfHostingView
    private var frameSize = CGSize(width: 80, height: 80)
    private var contentSize = CGSize(width: 80, height: 80)
    private var shrinkTask: Task<Void, Never>?
    private var frameUpdateScheduled = false
    private var drag: (mouse: CGPoint, origin: CGPoint)?
    private var snapping = false
    private var soundGate = ShelfSoundGate()
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private var store: InboxStore { model.notch.store }
    private var shelf: ShelfStore { model.shelf }

    init(notch: NotchModel) {
        model = ShelfModel(notch: notch)
        hosting = ShelfHostingView(rootView: ShelfRootView(model: model, maxStackHeight: 400, onSize: { _ in }, onDrag: {}, onDragEnd: {}))
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.setAccessibilityLabel("PR Shelf")
        refreshRootView()

        soundGate.skip(shelf.pulse)
        installMonitors()
        installObservers()
        observe({ $0.shelf.pulse?.id }) { $0.pulseChanged() }
        observe({ $0.model.expanded }) { $0.expandedChanged() }
        observe({ $0.model.notch.hiddenForFullscreen }) { $0.updateVisibility() }
        observe({ $0.store.settings.shelf.enabled }) { $0.enabledChanged() }
        observe({ $0.store.settings.shelf.corner }) { $0.applyFrame($0.frameSize, animated: false) }
        applyFrame(frameSize, animated: false)
        enabledChanged()
    }

    private func refreshRootView() {
        hosting.rootView = ShelfRootView(
            model: model,
            maxStackHeight: ShelfLayout.maxStackHeight(in: visibleFrame),
            onSize: { [weak self] in self?.contentSizeChanged($0) },
            onDrag: { [weak self] in self?.dragMoved() },
            onDragEnd: { [weak self] in self?.dragEnded() }
        )
    }

    // MARK: Screen

    /// The shelf lives on the same screen as the notch UI, inside its visible frame (clear of the menu bar and Dock).
    private var visibleFrame: CGRect {
        let (host, screen) = HostScreen.current()
        return screen?.visibleFrame ?? host.frame
    }

    // MARK: Frame

    /// Same contract as the notch panel: grow now, shrink after the closing animation, never resize inside SwiftUI's
    /// update pass.
    private func contentSizeChanged(_ size: CGSize) {
        let target = CGSize(width: ceil(size.width), height: ceil(size.height))
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
        guard drag == nil else { return }
        let target = contentSize
        shrinkTask?.cancel()
        let grown = CGSize(width: max(frameSize.width, target.width), height: max(frameSize.height, target.height))
        if grown != frameSize { applyFrame(grown, animated: false) }
        if grown != target {
            let settle = model.motion.settle
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: settle)
                guard !Task.isCancelled, let self, self.drag == nil else { return }
                self.applyFrame(self.contentSize, animated: false)
            }
        }
    }

    private func applyFrame(_ size: CGSize, animated: Bool) {
        frameSize = size
        let frame = ShelfLayout.frame(for: size, corner: model.corner, in: visibleFrame)
        guard panel.frame != frame else { return }
        if animated {
            snapping = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = model.motion.isReduced ? 0.12 : 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.05)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.snapping = false }
            }
        } else if !snapping {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: Dragging the circle

    private func dragMoved() {
        let mouse = NSEvent.mouseLocation
        if drag == nil {
            model.collapse(animated: false)
            shrinkTask?.cancel()
            drag = (mouse, panel.frame.origin)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { model.dragging = true }
        }
        guard let drag else { return }
        panel.setFrameOrigin(CGPoint(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y))
    }

    private func dragEnded() {
        guard drag != nil else { return }
        drag = nil
        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { model.dragging = false }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let corner = ShelfLayout.nearestCorner(to: center, in: visibleFrame)
        if corner != model.corner {
            store.updateSettings { $0.shelf.corner = corner }
        }
        // Only the circle is showing while dragging; land at the content's collapsed size.
        applyFrame(contentSize, animated: true)
    }

    // MARK: Visibility & key focus

    private func enabledChanged() {
        if store.settings.shelf.enabled {
            shelf.start()
        } else {
            model.collapse(animated: false)
            shelf.stop()
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = store.settings.shelf.enabled && !model.notch.hiddenForFullscreen
        if !visible { model.collapse(animated: false) }
        if visible, !panel.isVisible {
            applyFrame(frameSize, animated: false)
            panel.orderFrontRegardless()
        } else if !visible, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func expandedChanged() {
        let open = model.expanded
        panel.allowsKey = open
        if open {
            if !panel.isKeyWindow { panel.makeKey() }
        } else if panel.isKeyWindow {
            // Hand keyboard focus back to the app the user was in.
            panel.resignKey()
            panel.orderOut(nil)
            updateVisibility()
        }
    }

    // MARK: Pulse

    private func pulseChanged() {
        guard let pulse = shelf.pulse else { return }
        let context = ShelfSoundGate.Context(
            settings: store.settings, quiet: store.quietReason != nil, hiddenForFullscreen: model.notch.hiddenForFullscreen)
        let summary = pulse.events.map(\.summary).joined(separator: "; ")
        switch soundGate.decide(pulse.id, context: context, now: store.now.now()) {
        case .ignore:
            SoundPlayer.log.info("Silent: shelf pulse \(pulse.id) (\(summary, privacy: .public))")
        case .bounce:
            model.bounce()
            SoundPlayer.log.info("Silent bounce: shelf pulse \(pulse.id) (\(summary, privacy: .public))")
        case .bounceAndPlay(let sound, let volume):
            model.bounce()
            model.notch.sounds.play(sound, volume: volume, reason: "shelf pulse \(pulse.id): \(summary)")
        }
    }

    // MARK: Events

    private func installMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.model.collapse()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.window === self.panel, event.keyCode == 53 else { return event }
            self.model.collapse()
            return nil
        }) {
            monitors.append(local)
        }
    }

    private func installObservers() {
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshRootView()
                self.applyFrame(self.frameSize, animated: false)
            }
        }
        observers.append((NotificationCenter.default, token))
    }

    private func observe<T>(_ read: @escaping @MainActor (ShelfController) -> T, _ action: @escaping @MainActor (ShelfController) -> Void) {
        withObservationTracking {
            _ = read(self)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                action(self)
                self.observe(read, action)
            }
        }
    }
}

/// Decides how the circle reacts to a `ShelfStore.pulse`: once per pulse id, never while quiet, disabled, or hidden
/// for fullscreen, and the sound at most every `minimumInterval` (bursts still bounce).
struct ShelfSoundGate {
    static let minimumInterval: TimeInterval = SoundPolicy.minimumInterval

    struct Context {
        var settings: AppSettings
        var quiet: Bool
        var hiddenForFullscreen: Bool
    }

    enum Decision: Equatable {
        case ignore
        case bounce
        case bounceAndPlay(ArrivalSound, volume: Double)
    }

    private var lastPulseID: Int?
    private var lastPlayedAt: Date?

    /// Pulses that already existed when the shelf appeared are history, not news.
    mutating func skip(_ pulse: ShelfPulse?) {
        if let pulse { lastPulseID = pulse.id }
    }

    mutating func decide(_ pulseID: Int, context: Context, now: Date) -> Decision {
        guard pulseID != lastPulseID else { return .ignore }
        lastPulseID = pulseID
        let settings = context.settings
        guard settings.shelf.enabled, !context.quiet, !context.hiddenForFullscreen else { return .ignore }
        guard settings.sound != .off, settings.soundVolume > 0 else { return .bounce }
        if let last = lastPlayedAt, now.timeIntervalSince(last) < Self.minimumInterval { return .bounce }
        lastPlayedAt = now
        return .bounceAndPlay(settings.sound, volume: min(1, settings.soundVolume))
    }
}
