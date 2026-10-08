import AppKit
import SwiftUI

/// Floating, resizable, non-activating file preview window. Its titlebar is transparent; the SwiftUI title row
/// sits in it beside the traffic lights. It can become key (keyboard navigation, reply composer, find bar)
/// without activating Gitoken.
final class PreviewPanel: NSPanel {
    static let minSize = NSSize(width: 520, height: 360)

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Preview"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        minSize = Self.minSize
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The preview never activates Gitoken, so its first click usually arrives while another app is active.
final class PreviewHostingView: NSHostingView<PreviewWindowRoot> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
