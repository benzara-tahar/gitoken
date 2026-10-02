import AppKit
import CoreGraphics

/// Geometry of the screen the notch UI lives on.
struct HostScreen: Equatable {
    var frame: CGRect
    var hasNotch: Bool
    /// Width of the camera housing; 0 without a notch.
    var notchWidth: CGFloat
    /// Height of the notch / menu bar band at the top of the screen.
    var topInset: CGFloat
    var displayID: CGDirectDisplayID

    static let fallback = HostScreen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: false, notchWidth: 0, topInset: 24, displayID: 0
    )

    /// Prefers the built-in screen that has a notch; otherwise the main screen (pill mode).
    static func current() -> (HostScreen, NSScreen?) {
        let screens = NSScreen.screens
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }) {
            return (HostScreen(notched), notched)
        }
        guard let main = NSScreen.main ?? screens.first else { return (.fallback, nil) }
        return (HostScreen(main), main)
    }

    init(frame: CGRect, hasNotch: Bool, notchWidth: CGFloat, topInset: CGFloat, displayID: CGDirectDisplayID) {
        self.frame = frame
        self.hasNotch = hasNotch
        self.notchWidth = notchWidth
        self.topInset = topInset
        self.displayID = displayID
    }

    init(_ screen: NSScreen) {
        frame = screen.frame
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchWidth = max(0, screen.frame.width - left.width - right.width)
            topInset = safeTop
        } else {
            hasNotch = false
            notchWidth = 0
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            topInset = menuBar > 0 ? menuBar : 24
        }
    }

    /// Room available for a surface hanging from the top edge.
    var maxSurfaceHeight: CGFloat { max(260, frame.height - topInset - 60) }
    var maxSurfaceWidth: CGFloat { max(360, frame.width - 48) }

    /// True when another app's window covers this whole screen (a fullscreen space is frontmost).
    func isCoveredByFullscreenWindow() -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let cgFrame = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in info {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if bounds.integral == cgFrame.integral { return true }
        }
        return false
    }
}
