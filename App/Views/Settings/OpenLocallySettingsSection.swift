import GitokenCore
import SwiftUI

/// Editor, worktree location, and the remembered local clones used by "Open in editor".
struct OpenLocallySettingsSection: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme

    private enum EditorKind: Hashable, CaseIterable {
        case vscode, zed, custom

        var title: String {
            switch self {
            case .vscode: "VS Code"
            case .zed: "Zed"
            case .custom: "Custom"
            }
        }
    }

    var body: some View {
        let store = model.store
        let s = store.settings
        SettingsSection(title: "Open locally") {
            SettingsCard {
                SettingsRow(title: "Editor", last: kind(s.editor) != .custom) {
                    Picker("Editor", selection: Binding(get: { kind(s.editor) }, set: { setKind($0) })) {
                        ForEach(EditorKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                if case .custom(let template) = s.editor {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Command", text: Binding(get: { template }, set: { v in store.updateSettings { $0.editor = .custom(template: v) } }),
                                  prompt: Text("code {path}"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .controlSize(.small)
                            .accessibilityLabel("Custom editor command")
                        Text("Runs in your login shell. {path} becomes the quoted folder path.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                }
            }
            SettingsCard {
                SettingsRow(title: "Worktrees", detail: "\(s.worktreeRoot)/owner/repo/pr-<n>", last: true) {
                    HStack(spacing: 4) {
                        if s.worktreeRoot != AppSettings().worktreeRoot {
                            Button("Reset") { store.updateSettings { $0.worktreeRoot = AppSettings().worktreeRoot } }
                                .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                        }
                        Button("Change…") { model.openLocally.chooseWorktreeRoot() }
                            .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                    }
                }
            }
            .padding(.top, 8)
            let repos = s.repoPaths.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            if repos.isEmpty {
                SettingsNote(text: "Gitoken asks for a repository’s local clone the first time you open one of its pull requests.")
            } else {
                SettingsCard {
                    ForEach(Array(repos.enumerated()), id: \.element.key) { index, entry in
                        SettingsRow(title: entry.key, detail: (entry.value as NSString).abbreviatingWithTildeInPath, last: index == repos.count - 1) {
                            HStack(spacing: 4) {
                                Button("Change…") { Task { await model.openLocally.changeClone(for: entry.key) } }
                                    .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                                Button {
                                    model.openLocally.forgetClone(for: entry.key)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                                .help("Forget this clone")
                                .accessibilityLabel("Forget clone of \(entry.key)")
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func kind(_ editor: EditorChoice) -> EditorKind {
        switch editor {
        case .vscode: .vscode
        case .zed: .zed
        case .custom: .custom
        }
    }

    private func setKind(_ kind: EditorKind) {
        model.store.updateSettings { s in
            switch kind {
            case .vscode: s.editor = .vscode
            case .zed: s.editor = .zed
            case .custom: if case .custom = s.editor {} else { s.editor = .custom(template: "code {path}") }
            }
        }
    }
}
