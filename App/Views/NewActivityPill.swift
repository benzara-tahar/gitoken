import SwiftUI

/// Floating "3 new ↓" / "2 updated ↑" capsule that jumps to activity outside the viewport.
struct NewActivityPill: View {
    @Environment(\.theme) private var theme
    let label: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(theme.accent))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
