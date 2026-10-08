import GitokenCore
import SwiftUI

struct CustomSectionsSettings: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    private var draft: CustomSection? {
        get { model.sectionDraft }
        nonmutating set {
            if newValue?.id != model.sectionDraft?.id || newValue == nil { model.sectionQueryPreview = nil }
            model.sectionDraft = newValue
        }
    }
    private var deleting: CustomSection? {
        get { model.sectionPendingDeletion }
        nonmutating set { model.sectionPendingDeletion = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsNote(text: "Saved GitHub searches, not notification filters. Browse matching PRs and issues without extra sounds or notch badge counts.")
            if model.settings.customSections.isEmpty, draft == nil {
                VStack(spacing: 4) {
                    InboxIllustration(.empty, size: 64)
                    Text("No saved sections yet.").font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            ForEach(Array(model.settings.customSections.enumerated()), id: \.element.id) { index, section in
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 5) {
                            Text(section.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                            Spacer(minLength: 0)
                            IconButton(symbol: "arrow.up", label: "Move \(section.name) up") { move(section.id, by: -1) }
                                .disabled(index == 0)
                            IconButton(symbol: "arrow.down", label: "Move \(section.name) down") { move(section.id, by: 1) }
                                .disabled(index == model.settings.customSections.count - 1)
                            IconButton(symbol: "pencil", label: "Edit \(section.name)") { draft = section }
                            IconButton(symbol: "trash", label: "Delete \(section.name)") { deleting = section }
                        }
                        Text(section.query)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 10)
                }
            }
            if let section = deleting {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Delete “\(section.name)”?").font(.system(size: 12, weight: .semibold))
                        Text("Only this saved search is removed. GitHub and shared local seen state are unchanged.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack {
                            Button("Cancel") { deleting = nil }
                                .buttonStyle(SmallButtonStyle(theme: theme))
                            Spacer()
                            Button("Delete section") {
                                model.store.updateSettings { $0.customSections.removeAll { $0.id == section.id } }
                                if draft?.id == section.id { draft = nil }
                                deleting = nil
                            }
                            .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.danger))
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            if let draft {
                CustomSectionEditor(section: draft, onSave: save, onCancel: { self.draft = nil })
                    .id(draft.id)
            } else {
                Button {
                    draft = CustomSection(name: "", query: "is:pr state:open archived:false sort:updated-desc")
                } label: {
                    Label("Add section", systemImage: "plus")
                }
                .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
            }
            SettingsNote(text: "Use GitHub qualifiers such as repo:, org:, author:, state:open and archived:false, with AND, OR and parentheses. Results are limited to repositories your gh account can access.")
            if model.settings.customSections.isEmpty, draft == nil {
                SettingsNote(text: "Example: is:pr state:open archived:false sort:updated-desc (author:alice OR author:bob)")
            }
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        model.store.updateSettings { settings in
            guard let index = settings.customSections.firstIndex(where: { $0.id == id }),
                  settings.customSections.indices.contains(index + offset) else { return }
            settings.customSections.swapAt(index, index + offset)
        }
    }

    private func save(_ section: CustomSection) {
        model.store.updateSettings { settings in
            if let index = settings.customSections.firstIndex(where: { $0.id == section.id }) {
                settings.customSections[index] = section
            } else {
                settings.customSections.append(section)
            }
        }
        draft = nil
        Task { await model.store.customSections.refreshSection(section.id) }
    }
}

private struct CustomSectionEditor: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    @State var section: CustomSection
    var onSave: (CustomSection) -> Void
    var onCancel: () -> Void
    @State private var preview: SearchPage?
    @State private var error: GitHubError?
    @State private var loading = false
    @State private var previewTask: Task<Void, Never>?
    @State private var generation = 0

    private var canSave: Bool {
        !section.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !section.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Section editor").font(.system(size: 12.5, weight: .semibold))
                TextField("Section name", text: $section.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Section name")
                TextField("GitHub search query", text: $section.query, axis: .vertical)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(3...8)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("GitHub search query")
                HStack {
                    Button("Preview results") { previewResults() }
                        .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
                        .disabled(section.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }
                if let error {
                    SearchFailureMessage(error: error, hasCachedRows: preview?.items.isEmpty == false)
                    if preview != nil {
                        Text("Showing previous preview.").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                if let preview {
                    previewResults(preview)
                }
                HStack {
                    Button("Cancel", action: onCancel).buttonStyle(SmallButtonStyle(theme: theme))
                    Spacer(minLength: 0)
                    Button("Save section") {
                        var cleaned = section
                        cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        cleaned.query = cleaned.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(cleaned)
                    }
                    .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
                    .disabled(!canSave)
                }
                SettingsNote(text: "Opening marks results seen locally. Dismiss hides a PR or issue from every matching section until it changes again; it does not mark a GitHub notification done.")
            }
            .padding(.vertical, 12)
        }
        .onAppear {
            if let saved = model.sectionQueryPreview, saved.id == section.id, saved.query == section.query {
                preview = saved.page
            }
        }
        .onChange(of: section) {
            if model.sectionDraft?.id == section.id { model.sectionDraft = section }
        }
        .onChange(of: section.query) { invalidatePreview() }
        .onChange(of: model.viewerLogin) { invalidatePreview() }
        .onDisappear { invalidatePreview(clearSaved: false) }
    }

    @ViewBuilder
    private func previewResults(_ page: SearchPage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(page.totalCount) matching \(page.totalCount == 1 ? "result" : "results")")
                .font(.system(size: 11, weight: .semibold))
            if page.incompleteResults || page.totalCount > 1_000 {
                SearchLimitNote(page: page)
            }
            if page.items.isEmpty {
                HStack(spacing: 8) {
                    InboxIllustration(.noSearchResults, size: 36)
                    Text("No matching PRs or issues.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ForEach(page.items.prefix(5)) { item in
                Button { model.openSearch(item) } label: {
                    HStack(alignment: .top, spacing: 7) {
                        KindIcon(kind: item.kind, state: item.state, size: 11)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
                            Text("\(item.repo.fullName) #\(item.number)")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview \(item.title)")
            }
            if page.items.count > 5 {
                Text("Preview shows the first 5. Save to browse and load more.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.chipBackground))
    }

    private func invalidatePreview(clearSaved: Bool = true) {
        generation += 1
        previewTask?.cancel()
        previewTask = nil
        error = nil
        loading = false
        if clearSaved {
            preview = nil
            model.sectionQueryPreview = nil
        }
    }

    private func previewResults() {
        invalidatePreview(clearSaved: false)
        loading = true
        let generation = generation
        let query = section.query
        previewTask = Task {
            do throws(GitHubError) {
                let page = try await model.store.customSections.previewQuery(query)
                guard !Task.isCancelled, self.generation == generation else { return }
                preview = page
                model.sectionQueryPreview = (section.id, query, page)
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.error = error
            }
            loading = false
            previewTask = nil
        }
    }
}
