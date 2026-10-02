import AppKit
import SwiftUI

/// Borderless, non-activating floating panel for the PR Shelf. It joins every space, never activates Gitoken,
/// and takes keyboard focus only while the card stack is open (so Escape can close it).
final class ShelfPanel: NSPanel {
    var allowsKey = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The shelf never activates Gitoken, so the first click on it usually lands while another app is active;
/// without first-mouse the circle's tap/drag gesture would swallow that click.
final class ShelfHostingView: NSHostingView<ShelfRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
