import SwiftUI

/// Building blocks matching `SettingsView`'s section/card/row look, for sections that live in their own files.
struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.top, 14)
    }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.settingsCard))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
    }
}

struct SettingsRow<Control: View>: View {
    @Environment(\.theme) private var theme
    var title: String
    var detail: String?
    var last = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 40)
        .padding(.vertical, detail == nil ? 0 : 6)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(theme.hairline).frame(height: 0.5) }
        }
    }
}

struct SettingsNote: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .padding(.top, 6)
    }
}
