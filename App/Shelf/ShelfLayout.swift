import AppKit
import GitokenCore
import SwiftUI

/// Geometry for the PR Shelf panel: where each corner sits on screen and which way the card stack grows.
nonisolated enum ShelfLayout {
    /// Gap between the panel frame and the screen's visible edges (menu bar and Dock excluded).
    static let screenMargin: CGFloat = 4
    /// Transparent room around the content so the bounce, glow halo, ripple, and shadows never clip.
    static let contentPadding: CGFloat = 18
    /// Extra room on the circle's open side for the bounce (elastic lift is ~26pt).
    static let bounceRoom: CGFloat = 16
    static let circleSize: CGFloat = 46
    static let cardWidth: CGFloat = 330

    /// Panel frame for content of `size` resting in `corner` of `visible`.
    static func frame(for size: CGSize, corner: ShelfCorner, in visible: CGRect) -> CGRect {
        let x = corner.isLeft ? visible.minX + screenMargin : visible.maxX - screenMargin - size.width
        let y = corner.isTop ? visible.maxY - screenMargin - size.height : visible.minY + screenMargin
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Corner whose quadrant contains `point` (screen coordinates).
    static func nearestCorner(to point: CGPoint, in visible: CGRect) -> ShelfCorner {
        let left = point.x < visible.midX
        let top = point.y > visible.midY
        switch (top, left) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// Tallest card stack that still leaves the circle and some breathing room on screen.
    static func maxStackHeight(in visible: CGRect) -> CGFloat {
        max(220, visible.height - circleSize - contentPadding * 2 - screenMargin * 2 - 60)
    }
}

extension ShelfCorner {
    nonisolated var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    nonisolated var isTop: Bool { self == .topLeft || self == .topRight }

    /// Content alignment inside the panel: hugs the corner while the frame is larger than the content.
    nonisolated var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    nonisolated var horizontalAlignment: HorizontalAlignment { isLeft ? .leading : .trailing }
}
