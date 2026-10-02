import GitokenCore
import SwiftUI

/// Animation curves per motion style, mirroring the prototype's `DUR` table
/// (gentle 440/300 ms ease-out, elastic ~760/480 ms spring, reduced ≈ instant).
nonisolated struct Motion: Equatable, Sendable {
    var style: MotionStyle

    var isReduced: Bool { style == .reduced }

    var open: Animation {
        switch style {
        case .gentle: .smooth(duration: 0.44)
        case .elastic: .spring(response: 0.55, dampingFraction: 0.7)
        case .reduced: .easeOut(duration: 0.12)
        }
    }

    var close: Animation {
        switch style {
        case .gentle: .smooth(duration: 0.3)
        case .elastic: .spring(response: 0.42, dampingFraction: 0.82)
        case .reduced: .easeOut(duration: 0.1)
        }
    }

    /// Small pops: count bumps, avatars joining a merged arrival, menus.
    var pop: Animation {
        switch style {
        case .gentle: .smooth(duration: 0.32)
        case .elastic: .spring(response: 0.38, dampingFraction: 0.55)
        case .reduced: .linear(duration: 0.01)
        }
    }

    var fade: Animation { .easeOut(duration: style == .reduced ? 0.15 : 0.22) }

    /// How long the panel keeps its larger frame after content shrinks, so closing animations aren't clipped.
    var settle: Duration {
        switch style {
        case .gentle: .milliseconds(520)
        case .elastic: .milliseconds(900)
        case .reduced: .milliseconds(200)
        }
    }

    /// Calm surfaces enter from slightly above and smaller; Fluid grows out of the notch instead.
    var hiddenScale: CGFloat {
        switch style {
        case .gentle: 0.975
        case .elastic: 0.9
        case .reduced: 1
        }
    }

    var hiddenOffset: CGFloat {
        switch style {
        case .gentle: -8
        case .elastic: -16
        case .reduced: 0
        }
    }
}

nonisolated private struct MotionKey: EnvironmentKey {
    static let defaultValue = Motion(style: .gentle)
}

extension EnvironmentValues {
    var motion: Motion {
        get { self[MotionKey.self] }
        set { self[MotionKey.self] = newValue }
    }
}
