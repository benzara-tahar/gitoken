import GitokenCore
import SwiftUI

/// Global shortcut + inbox keys, mute rules, and saved replies.
struct InboxSettingsSections: View {
    var body: some View {
        KeyboardSettingsSection()
        MutedSettingsSection()
        SavedRepliesSettingsSection()
    }
}

private struct KeyboardSettingsSection: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let hotKey = model.settings.hotKey
        SettingsSection(title: "Keyboard") {
            SettingsCard {
                SettingsRow(title: "Open inbox", detail: detail(hotKey), last: true) {
                    HStack(spacing: 4) {
                        Button { model.isRecordingHotKey.toggle() } label: {
                            Text(model.isRecordingHotKey ? "Type shortcut…" : hotKey?.displayString ?? "Off")
                                .font(.system(size: 12, weight: .semibold, design: model.isRecordingHotKey ? .default : .rounded))
                                .foregroundStyle(model.isRecordingHotKey ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.primary))
                                .frame(minWidth: 86)
                                .frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.inputBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(model.isRecordingHotKey ? theme.accent : theme.hairline, lineWidth: model.isRecordingHotKey ? 1.5 : 0.5)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click, then press the new shortcut. Esc cancels, Delete turns it off.")
                        .accessibilityLabel("Open inbox shortcut, \(hotKey?.displayString ?? "off")")
                        .accessibilityHint("Press to record a new shortcut")
                        if hotKey != .openInbox {
                            Button("Reset") { model.store.updateSettings { $0.hotKey = .openInbox } }
                                .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                        } else {
                            Button {
                                model.store.updateSettings { $0.hotKey = nil }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                            .help("Turn the shortcut off")
                            .accessibilityLabel("Turn the shortcut off")
                        }
                    }
                }
            }
            SettingsNote(text: "In the inbox: J/K or ↑/↓ move · Return opens · E done · S snooze · U undo")
        }
        .onDisappear { model.isRecordingHotKey = false }
    }

    private func detail(_ hotKey: HotKey?) -> String {
        if model.isRecordingHotKey { return "Include ⌘, ⌥ or ⌃. Esc cancels, Delete turns it off." }
        if hotKey == nil { return "Off" }
        if model.hotKeyUnavailable { return "Another app already uses this shortcut" }
        return "Toggles the inbox from any app"
    }
}

private struct MutedSettingsSection: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let rules = model.settings.muteRules
        SettingsSection(title: "Muted") {
            if rules.isEmpty {
                SettingsNote(text: "Right-click a conversation to mute its repository, organization, or kind of notification.")
            } else {
                SettingsCard {
                    ForEach(Array(rules.enumerated()), id: \.element) { index, rule in
                        SettingsRow(title: rule.subject, last: index == rules.count - 1) {
                            Button("Unmute") { model.store.unmute(rule) }
                                .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                                .accessibilityLabel("Unmute \(rule.subject)")
                        }
                    }
                }
                SettingsNote(text: "Muted conversations stay out of the inbox, counts, arrivals and sounds.")
            }
        }
    }
}

private struct SavedRepliesSettingsSection: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let replies = model.settings.savedReplies
        SettingsSection(title: "Saved replies") {
            SettingsCard {
                ForEach(replies.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        TextField("Reply", text: binding(at: index), prompt: Text("Saved reply"), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .lineLimit(1...3)
                            .accessibilityLabel("Saved reply \(index + 1)")
                        Button {
                            model.store.updateSettings { s in
                                if s.savedReplies.indices.contains(index) { s.savedReplies.remove(at: index) }
                            }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                        .help("Delete this saved reply")
                        .accessibilityLabel("Delete saved reply \(index + 1)")
                    }
                    .frame(minHeight: 36)
                    .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
                }
                HStack {
                    Button {
                        model.store.updateSettings { $0.savedReplies.append("") }
                    } label: {
                        Label("Add reply", systemImage: "plus")
                    }
                    .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
                    .disabled(replies.last?.isEmpty == true)
                    Spacer()
                    if replies != SavedReplies.defaults {
                        Button("Restore defaults") { model.store.updateSettings { $0.savedReplies = SavedReplies.defaults } }
                            .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                    }
                }
                .frame(minHeight: 40)
            }
            SettingsNote(text: "Insert or send them from the speech-bubble button next to the reply box.")
        }
    }

    private func binding(at index: Int) -> Binding<String> {
        Binding(
            get: { model.settings.savedReplies.indices.contains(index) ? model.settings.savedReplies[index] : "" },
            set: { value in
                model.store.updateSettings { s in
                    if s.savedReplies.indices.contains(index) { s.savedReplies[index] = value }
                }
            })
    }
}
