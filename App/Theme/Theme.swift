import GitokenCore
import SwiftUI

/// Visual tokens for the two presets. Calm follows the system appearance (native glass);
/// Fluid is always dark (near-black island attached to the notch).
nonisolated struct Theme: Equatable, Sendable {
    var appearance: Appearance
    var notchAttached: Bool

    var isFluid: Bool { appearance == .fluid }

    var accent: Color { isFluid ? Color(red: 0.24, green: 0.61, blue: 1) : .accentColor }
    var danger: Color { pick(Color(red: 0.85, green: 0.23, blue: 0.25), Color(red: 1, green: 0.36, blue: 0.33)) }
    var success: Color { pick(Color(red: 0.1, green: 0.56, blue: 0.28), Color(red: 0.2, green: 0.83, blue: 0.42)) }
    var merged: Color { pick(Color(red: 0.51, green: 0.31, blue: 0.87), Color(red: 0.75, green: 0.55, blue: 1)) }
    var warn: Color { pick(Color(red: 0.72, green: 0.44, blue: 0), Color(red: 1, green: 0.81, blue: 0.2)) }
    var quiet: Color { Color(red: 0.56, green: 0.49, blue: 1) }

    /// Row card background in Fluid; Calm rows sit directly on the glass.
    var groupBackground: Color { isFluid ? Color(white: 0.075) : Color.primary.opacity(0.0) }
    var groupHover: Color { isFluid ? Color(white: 0.11) : Color.primary.opacity(0.05) }
    var chipBackground: Color { Color.primary.opacity(isFluid ? 0.09 : 0.06) }
    var hairline: Color { Color.primary.opacity(0.09) }
    var codeBackground: Color { isFluid ? Color(white: 0.055) : Color(nsColor: .textBackgroundColor).opacity(0.7) }
    var inputBackground: Color { isFluid ? Color(white: 0.105) : Color(nsColor: .textBackgroundColor).opacity(0.6) }
    var settingsCard: Color { isFluid ? Color(white: 0.075) : Color(nsColor: .textBackgroundColor).opacity(0.45) }
    var menuBackground: Color { isFluid ? Color(white: 0.11) : Color(nsColor: .windowBackgroundColor) }

    var rowAvatar: CGFloat { isFluid ? 36 : 30 }
    var eventAvatar: CGFloat { isFluid ? 28 : 26 }
    var bannerAvatar: CGFloat { isFluid ? 40 : 34 }

    // Syntax tokens for diff hunks.
    var tokenKeyword: Color { pick(Color(red: 0.77, green: 0.19, blue: 0.48), Color(red: 1, green: 0.48, blue: 0.72)) }
    var tokenString: Color { pick(Color(red: 0.06, green: 0.48, blue: 0.37), Color(red: 0.62, green: 0.89, blue: 0.64)) }
    var tokenNumber: Color { pick(Color(red: 0.65, green: 0.36, blue: 0), Color(red: 1, green: 0.71, blue: 0.42)) }
    var tokenFunction: Color { pick(Color(red: 0.18, green: 0.36, blue: 0.83), Color(red: 0.49, green: 0.77, blue: 1)) }
    var tokenType: Color { pick(Color(red: 0.48, green: 0.29, blue: 0.79), Color(red: 0.82, green: 0.66, blue: 1)) }
    var tokenComment: Color { Color.primary.opacity(0.42) }

    /// Fluid is always dark; Calm follows the system appearance, so its tones switch with it.
    private func pick(_ light: Color, _ dark: Color) -> Color {
        if isFluid { return dark }
        let lightColor = NSColor(light), darkColor = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

nonisolated private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(appearance: .calm, notchAttached: true)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
