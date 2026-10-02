import GitokenCore
import SwiftUI

/// "PR Shelf" settings: show the floating circle, which corner it rests in, and which changes bounce it.
struct ShelfSettingsSection: View {
    @Environment(NotchModel.self) private var model

    var body: some View {
        let store = model.store
        let shelf = store.settings.shelf
        SettingsSection(title: "PR Shelf") {
            SettingsCard {
                SettingsRow(title: "Show PR Shelf", detail: "Floating circle with your open pull requests") {
                    Toggle("Show PR Shelf", isOn: Binding(get: { shelf.enabled }, set: { v in store.updateSettings { $0.shelf.enabled = v } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsRow(title: "Corner", last: true) {
                    Picker("Corner", selection: Binding(get: { shelf.corner }, set: { v in store.updateSettings { $0.shelf.corner = v } })) {
                        ForEach([ShelfCorner.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { corner in
                            Image(systemName: corner.symbol).help(corner.title).accessibilityLabel(corner.title).tag(corner)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                .disabled(!shelf.enabled)
                .opacity(shelf.enabled ? 1 : 0.45)
            }
            SettingsCard {
                ForEach(Array(ShelfEventKind.allCases.enumerated()), id: \.element) { index, kind in
                    SettingsRow(title: kind.title, last: index == ShelfEventKind.allCases.count - 1) {
                        Toggle(kind.title, isOn: Binding(
                            get: { shelf.events.contains(kind) },
                            set: { on in store.updateSettings { if on { $0.shelf.events.insert(kind) } else { $0.shelf.events.remove(kind) } } }
                        ))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }
            .padding(.top, 8)
            .disabled(!shelf.enabled)
            .opacity(shelf.enabled ? 1 : 0.45)
            SettingsNote(text: "These changes on your pull requests bounce the circle and play the arrival sound. Quiet mode, quiet hours and snooze keep it still. Drag the circle to any corner; drop a GitHub pull request link on it to pin that PR.")
        }
    }
}

extension ShelfCorner {
    var title: String {
        switch self {
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        }
    }

    var symbol: String {
        switch self {
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        }
    }
}
