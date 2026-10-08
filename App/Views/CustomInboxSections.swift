import GitokenCore
import SwiftUI

struct CustomInboxSection: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    let section: CustomSection

    var body: some View {
        let result = model.store.customSections.results[section.id]
        Section {
            if !section.isCollapsed {
                if let error = result?.error {
                    SearchFailureMessage(error: error, hasCachedRows: result?.page.items.isEmpty == false)
                        .padding(.horizontal, 8)
                }
                if let result {
                    if result.page.incompleteResults || result.page.totalCount > 1_000 {
                        SearchLimitNote(page: result.page).padding(.horizontal, 8)
                    }
                    if result.error != nil, let refreshed = result.refreshedAt {
                        Text("Showing saved results · \(Format.ago(refreshed, now: model.store.now.now())).")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    let items = model.customItems(in: section.id)
                    ForEach(items) { item in
                        SearchInboxRow(item: item, sectionID: section.id)
                            .id(SearchRowID(sectionID: section.id, itemID: item.id))
                    }
                    if items.isEmpty, !result.isLoading, result.error == nil, result.refreshedAt != nil {
                        HStack(spacing: 8) {
                            InboxIllustration(.noSearchResults, size: 36)
                            Text(model.searchQuery.isEmpty ? "No matching PRs or issues." : "No results match the inbox filter.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    HStack(spacing: 8) {
                        if result.page.nextPage != nil {
                            Button("Load more") { Task { await model.store.customSections.loadMore(section.id) } }
                                .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
                                .disabled(result.isLoading)
                        }
                        let dismissed = model.store.customSections.dismissedCount(in: section.id)
                        if dismissed > 0 {
                            Button("Restore \(dismissed) dismissed") { restoreDismissed() }
                                .buttonStyle(SmallButtonStyle(theme: theme))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                } else {
                    Text("Waiting to refresh…").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
            }
        } header: {
            header(result)
        }
    }

    private func header(_ result: CustomSectionResult?) -> some View {
        HStack(spacing: 5) {
            Button { model.toggleCustomSection(section.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: section.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                    Text(section.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    if let result, result.refreshedAt != nil {
                        Text("\(model.store.customSections.items(in: section.id).count) / \(result.page.totalCount)")
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.name), \(section.isCollapsed ? "collapsed" : "expanded")")
            Spacer(minLength: 0)
            if result?.isLoading == true { ProgressView().controlSize(.mini) }
            IconButton(symbol: "arrow.clockwise", label: "Refresh \(section.name)") {
                Task { await model.store.customSections.refreshSection(section.id) }
            }
            .disabled(result?.isLoading == true)
            IconButton(symbol: "slider.horizontal.3", label: "Manage custom sections") { model.openSectionSettings() }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .padding(.top, 6)
        .help(section.query)
    }

    private func restoreDismissed() {
        guard let result = model.store.customSections.results[section.id] else { return }
        for item in result.page.items { model.store.customSections.restore(item.id) }
    }
}

struct SearchFailureMessage: View {
    @Environment(\.theme) private var theme
    let error: GitHubError
    var hasCachedRows = false

    private var isConnectionFailure: Bool {
        switch error {
        case .transport, .rateLimited: true
        case .http(let status, _): status >= 500
        case .auth, .graphQL, .decoding: false
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if !hasCachedRows, isConnectionFailure {
                InboxIllustration(.connectionError, size: 36)
            }
            Text(error.briefDescription)
                .font(.system(size: 11)).foregroundStyle(theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SearchLimitNote: View {
    let page: SearchPage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if page.incompleteResults {
                Text("GitHub returned incomplete results. Narrow the query or refresh to try again.")
            }
            if page.totalCount > 1_000 {
                Text("GitHub exposes only the first 1,000 of \(page.totalCount) matches. Narrow this query to see the rest.")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SearchInboxRow: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    let item: SearchItem
    let sectionID: UUID
    @State private var hovering = false

    private var rowID: SearchRowID { SearchRowID(sectionID: sectionID, itemID: item.id) }

    var body: some View {
        let unseen = model.store.customSections.isUnseen(item)
        HStack(alignment: .center, spacing: 3) {
            Button {
                model.selectListRow(.search(rowID))
                model.openSearch(item)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    KindIcon(kind: item.kind, state: item.state, size: 12).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.system(size: 12, weight: unseen ? .semibold : .medium))
                            .lineLimit(2).multilineTextAlignment(.leading)
                        HStack(spacing: 4) {
                            Text(item.repo.fullName).truncationMode(.middle)
                            Text("#\(item.number)").fixedSize()
                        }
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 4) {
                            if unseen { Circle().fill(theme.accent).frame(width: 5, height: 5) }
                            if let author = item.author { Text(author.login).lineLimit(1) }
                            Text("· \(Format.ago(item.updatedAt, now: model.store.now.now()))").fixedSize()
                        }
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .padding(.leading, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.repo.fullName) number \(item.number): \(item.title)\(unseen ? ", updated since seen" : "")")
            if hovering || model.selectedSearchRow == rowID {
                IconButton(symbol: "arrow.up.right.square", label: "Open \(item.title) on GitHub") {
                    model.store.customSections.markSeen(item)
                    NSWorkspace.shared.open(item.htmlURL)
                }
                IconButton(symbol: "xmark", label: "Dismiss \(item.title) from custom sections") { model.dismissSearch(item) }
            }
        }
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(
            model.selectedSearchRow == rowID ? theme.accent.opacity(0.12) : hovering ? theme.chipBackground : .clear
        ))
        .onHover { hovering = $0 }
    }
}
