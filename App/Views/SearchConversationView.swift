import GitokenCore
import SwiftUI

/// Search subjects have no notification identity or notification actions.
struct SearchConversationView: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    let id: SearchItemID
    var width: CGFloat
    var maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var revealAI = false

    private var backTitle: String {
        model.navigationState.history.dropLast().last == .settings ? "Sections" : "Inbox"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                SurfaceHeader(width: width) {
                    BackButton(title: backTitle) { model.back() }
                } trailing: {
                    IconButton(symbol: model.pinned ? "pin.fill" : "pin", label: "Pin panel open", active: model.pinned) {
                        model.pinned.toggle()
                    }
                    IconButton(symbol: "xmark", label: "Close notch") { model.close() }
                }
                if let item = model.searchItem(id) { titleBlock(item) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollView {
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, max(120, maxHeight - headerHeight)))
        }
        .frame(width: width)
    }

    private func titleBlock(_ item: SearchItem) -> some View {
        let detail = model.store.customSections.conversations[id]?.detail
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                KindIcon(kind: item.kind, state: detail?.state ?? item.state, size: 12)
                Text(item.repo.fullName).lineLimit(1).truncationMode(.middle)
                Text("#\(item.number)").foregroundStyle(.tertiary).fixedSize()
                Spacer(minLength: 0)
                Text(searchStateTitle(detail?.state ?? item.state)).fixedSize()
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text(detail?.title ?? item.title)
                .font(.system(size: 15.5, weight: .bold))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack(spacing: 6) {
                PillButton(title: "Dismiss locally", symbol: "xmark") { model.dismissSearch(item) }
                Spacer(minLength: 0)
                PillButton(title: "Open on GitHub", symbol: "arrow.up.right.square", kind: .ghost) {
                    NSWorkspace.shared.open(detail?.htmlURL ?? item.htmlURL)
                }
            }
            Text("Custom section · seen and dismissed state is local")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
    }

    @ViewBuilder
    private var content: some View {
        let state = model.store.customSections.conversations[id]
        VStack(alignment: .leading, spacing: 10) {
            if state?.isLoading == true {
                HStack { ProgressView().controlSize(.small); Text("Loading conversation…") }
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if let error = state?.error {
                Text(error.briefDescription).font(.system(size: 11.5)).foregroundStyle(theme.warn)
                if let item = model.searchItem(id) {
                    Button("Retry") { Task { await model.store.customSections.openConversation(item) } }
                        .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
                }
            }
            if let detail = state?.detail {
                let mode = model.settings.aiReviews
                let hidden = mode == .hide && !revealAI ? detail.items.filter(AIReviewers.isAIActivity) : []
                let items = hidden.isEmpty ? detail.items : detail.items.filter { !AIReviewers.isAIActivity($0) }
                let split = TimelineSplit(items: items, lastVisitAt: state?.lastVisitAt,
                                          viewer: model.viewerLogin, showAllOlder: true)
                entries(split.older, collapseAI: mode == .collapse)
                if let label = split.dividerLabel {
                    Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.accent)
                        .padding(.vertical, 5)
                }
                entries(split.newer, collapseAI: mode == .collapse)
                if !hidden.isEmpty {
                    Button("Show \(hidden.count) hidden AI updates") { revealAI = true }
                        .buttonStyle(SmallButtonStyle(theme: theme))
                }
                Text("Recent timeline from GitHub. Open on GitHub for the full history and to reply or review.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state == nil {
                Text("This search result is no longer available.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func entries(_ items: [TimelineItem], collapseAI: Bool) -> some View {
        ForEach(TimelineEntry.entries(for: items, collapseAI: collapseAI)) { entry in
            switch entry {
            case .item(let item): SearchTimelineItem(item: item)
            case .aiReview(let item):
                DisclosureGroup("\(item.actor.displayName) · AI review") { SearchTimelineItem(item: item) }
                    .font(.system(size: 11.5)).tint(theme.accent)
            case .reviewRequests(let group):
                Text("\(group.actor.displayName) requested reviews from \(group.reviewers.joined(separator: ", "))")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SearchTimelineItem: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    let item: TimelineItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                AvatarView(actor: item.actor, size: 20)
                Text(item.actor.displayName).fontWeight(.semibold)
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(Format.ago(item.createdAt, now: model.store.now.now()))
                    .foregroundStyle(.tertiary).fixedSize()
            }
            .font(.system(size: 11))
            payload
            if let url = item.url {
                Link("View on GitHub", destination: url)
                    .font(.system(size: 10.5)).foregroundStyle(theme.accent)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.chipBackground))
    }

    @ViewBuilder
    private var payload: some View {
        switch item.payload {
        case .opened(let body), .comment(let body):
            if !body.isEmpty { RichBodyView(source: body, size: 12) }
        case .review(_, let body, let comments):
            if !body.isEmpty { RichBodyView(source: body, size: 12) }
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(comment.author.displayName) · \(comment.path)\(comment.line.map { ":\($0)" } ?? "")")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !comment.diffHunk.isEmpty {
                        DisclosureGroup("Code context") {
                            Text(comment.diffHunk).font(.system(size: 10.5, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        .font(.system(size: 10.5))
                    }
                    RichBodyView(source: comment.body, size: 12)
                    if let url = comment.url {
                        Link("View comment on GitHub", destination: url).font(.system(size: 10.5))
                    }
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(theme.hairline).frame(width: 1) }
            }
        case .commits(_, let headlines):
            ForEach(Array(headlines.enumerated()), id: \.offset) { _, headline in
                Text(headline).font(.system(size: 11.5)).textSelection(.enabled)
            }
        case .checks(let checks):
            Text("\(checks.passedCount) passed · \(checks.pendingCount) pending · \(checks.failedChecks.count) failed")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            ForEach(checks.failedChecks, id: \.self) { Text($0).font(.system(size: 11.5)).foregroundStyle(theme.danger) }
        case .event(_, let detail):
            if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
    }

    private var label: String {
        switch item.payload {
        case .opened: "opened"
        case .comment: "commented"
        case .review(let state, _, _):
            switch state {
            case .approved: "approved"
            case .changesRequested: "requested changes"
            case .commented: "reviewed"
            case .dismissed: "review dismissed"
            case .pending: "pending review"
            }
        case .commits(let count, _): "pushed \(count) \(count == 1 ? "commit" : "commits")"
        case .checks(let checks): checks.status == .failure ? "checks failed" : checks.status == .pending ? "checks running" : "checks finished"
        case .event(let kind, _):
            switch kind {
            case .closed: "closed"
            case .reopened: "reopened"
            case .merged: "merged"
            case .reviewRequested: "requested a review"
            case .readyForReview: "marked ready for review"
            case .convertedToDraft: "converted to draft"
            case .assigned: "assigned"
            case .headRefForcePushed: "force-pushed"
            }
        }
    }
}

private func searchStateTitle(_ state: SubjectState) -> String {
    switch state {
    case .open: "Open"
    case .draft: "Draft"
    case .closed: "Closed"
    case .merged: "Merged"
    case .unknown: "Unknown"
    }
}
