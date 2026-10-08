import AppKit
import GitokenCore
import SwiftUI

/// Hosting root of a preview window: injects the models and theme.
struct PreviewWindowRoot: View {
    let model: PreviewModel

    var body: some View {
        PreviewRootView()
            .environment(model.notch)
            .environment(model)
            .environment(\.theme, model.notch.theme)
            .environment(\.motion, model.notch.motion)
    }
}

/// Preview window chrome: title row in the transparent titlebar, toolbar (file list, mode, thread navigator, review,
/// actions), banners (outdated commit, notices, threads that can't be placed), then the file list beside the code or
/// a state view. Review and commit popovers drop down under the toolbar.
struct PreviewRootView: View {
    @Environment(PreviewModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var toolbarWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            if model.target != nil {
                toolbar
                banners
            }
            Rectangle().fill(theme.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                if model.isSidebarVisible {
                    PreviewFileSidebar().frame(width: PreviewModel.sidebarWidth)
                    Rectangle().fill(theme.hairline).frame(width: 0.5)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topTrailing) { popover }
        }
        .background(theme.isFluid ? Color(white: 0.06) : Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var popover: some View {
        if let popover = model.popover, model.target != nil {
            ZStack(alignment: .topTrailing) {
                // Clicking outside closes it.
                Color.primary.opacity(0.001).onTapGesture { model.popover = nil }
                Group {
                    switch popover {
                    case .review: ReviewPopoverView()
                    case .commit: CommitSuggestionsPopoverView()
                    }
                }
                .padding(.top, 6)
                .padding(.trailing, 10)
            }
        }
    }

    // MARK: Title row

    private var titleRow: some View {
        HStack(spacing: 8) {
            if model.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .help("Pinned preview")
            }
            if let target = model.target {
                let directory = (target.path as NSString).deletingLastPathComponent
                HStack(spacing: 5) {
                    Text(Format.basename(target.path)).fontWeight(.semibold).foregroundStyle(.primary)
                    if !directory.isEmpty {
                        Text(directory).foregroundStyle(.secondary).truncationMode(.head)
                    }
                }
                .font(.system(size: 12.5))
                .lineLimit(1)
                .help(target.path)
                Spacer(minLength: 8)
                if case .loading = model.load { ProgressView().controlSize(.small) }
                if model.content != nil {
                    Chip(text: "GitHub", symbol: "cloud")
                        .help("Fetched from GitHub")
                }
                Text("\(target.ref.repo.name) #\(target.ref.number)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text("Preview").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
        }
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.001))
        .gesture(WindowDragGesture())
    }

    // MARK: Toolbar

    private var toolbar: some View {
        let compact = toolbarWidth < 680
        let tight = toolbarWidth < 590
        return HStack(spacing: 8) {
            if !model.isPinned {
                IconButton(symbol: "sidebar.left", label: "Changed files (B) · N / P next / previous", active: model.isSidebarVisible) {
                    model.toggleSidebar()
                }
            }
            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text("Diff").tag(PreviewMode.diff)
                Text("File").tag(PreviewMode.file)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Diff (D) · File (F)")
            navigator(tight: tight)
            if model.document?.highlightSkipped == true, !compact {
                Text("No highlighting (large file)").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            let batch = model.batchedSuggestions.count
            if batch > 0 {
                Button { model.togglePopover(.commit) } label: {
                    Label(compact ? "Commit (\(batch))" : "Commit suggestions (\(batch))", systemImage: "checkmark.seal")
                        .lineLimit(1)
                }
                .buttonStyle(SmallButtonStyle(theme: theme, tint: model.popover == .commit ? theme.accent : nil))
                .fixedSize()
                .help("Commit \(Format.plural(batch, "batched suggestion")) as one commit")
            }
            if model.reviewThreads != nil { reviewButton(tight: tight) }
            IconButton(symbol: "arrow.up.right.square", label: "Open on GitHub") {
                if let url = model.gitHubURL { NSWorkspace.shared.open(url) }
            }
            if !model.isPinned {
                IconButton(symbol: "pin", label: "Pin a copy of this preview") { model.onPin?() }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }
    }

    private func reviewButton(tight: Bool) -> some View {
        let pending = model.pendingCommentCount
        return Button { model.togglePopover(.review) } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.bubble")
                if !tight { Text("Review") }
                if pending > 0 { CountBadge(count: pending, height: 15).accessibilityHidden(true) }
            }
            .lineLimit(1)
        }
        .buttonStyle(SmallButtonStyle(theme: theme, tint: model.popover == .review ? theme.accent : nil))
        .fixedSize()
        .help(pending > 0 ? "Finish your review (\(Format.plural(pending, "pending comment")))" : "Review this pull request")
        .accessibilityLabel(pending > 0 ? "Review, \(Format.plural(pending, "pending comment"))" : "Review")
    }

    private func navigator(tight: Bool) -> some View {
        let count = model.anchoredThreadIDs.count
        let position = model.focusIndex.map { "\($0 + 1) of \(count)" } ?? "\(count) \(count == 1 ? "thread" : "threads")"
        return HStack(spacing: 2) {
            IconButton(symbol: "chevron.up", label: "Previous thread (K)", size: 22) { model.moveFocus(-1) }
            Text(count == 0 ? "No threads" : position)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: tight ? 40 : 54)
            IconButton(symbol: "chevron.down", label: "Next thread (J)", size: 22) { model.moveFocus(1) }
        }
        .disabled(count == 0)
        .opacity(count == 0 ? 0.5 : 1)
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        if let content = model.content, content.viewing.isOriginal {
            banner(symbol: "clock.arrow.circlepath", tone: theme.warn) {
                Text("Outdated · viewing \(Text(PreviewModel.short(content.viewing.oid)).font(.system(size: 11.5, design: .monospaced)))")
                Spacer(minLength: 8)
                Button("Jump to head") { model.jumpToHead() }
                    .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                    .disabled(model.reviewThreads == nil)
            }
        }
        if let notice = model.notice {
            banner(symbol: "info.circle", tone: theme.accent) {
                Text(notice).lineLimit(2)
                Spacer(minLength: 8)
                IconButton(symbol: "xmark", label: "Dismiss", size: 20) { model.dismissNotice() }
            }
        }
        let outdated = model.outdatedUnanchored
        let removed = model.removedLineUnanchored
        let other = model.otherUnanchored
        if !outdated.isEmpty || !removed.isEmpty || !other.isEmpty {
            HStack(spacing: 10) {
                if !outdated.isEmpty {
                    HStack(spacing: 4) {
                        Text(Format.plural(outdated.count, "outdated thread"))
                        Text("·").foregroundStyle(.tertiary)
                        Menu("View") {
                            ForEach(outdated) { thread in
                                Button(menuTitle(thread)) { model.viewOriginal(of: thread) }
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(theme.accent)
                    }
                }
                if !removed.isEmpty {
                    HStack(spacing: 4) {
                        Text("\(Format.plural(removed.count, "thread")) on removed lines")
                        if model.hasPatch {
                            Text("·").foregroundStyle(.tertiary)
                            Button("Show in Diff") { model.setMode(.diff) }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.accent)
                        }
                    }
                }
                if !other.isEmpty {
                    Text("\(Format.plural(other.count, "thread")) outside this \(model.mode == .diff ? "diff" : "file")")
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Color.primary.opacity(0.03))
        }
    }

    private func banner<Content: View>(symbol: String, tone: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tone)
            content()
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.1))
    }

    private func menuTitle(_ thread: ReviewThread) -> String {
        let line = thread.originalLine.map { "L\($0)" } ?? "File"
        guard let root = thread.root else { return line }
        return "\(line) · \(root.author.displayName): \(Format.plain(root.body.plainText, limit: 50))"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.target == nil {
            if model.pullRequest != nil, model.emptyMessage == nil {
                if let error = model.filesError {
                    PreviewStateView(symbol: "exclamationmark.triangle", title: "Couldn’t load the changed files", detail: error) {
                        Button("Retry") { model.loadFiles() }.buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                    }
                } else {
                    PreviewSkeleton()
                }
            } else {
                PreviewStateView(symbol: "text.bubble", title: model.emptyMessage ?? "Select a conversation with review comments")
            }
        } else {
            switch model.load {
            case .loading:
                PreviewSkeleton()
            case .failed(let message):
                PreviewStateView(symbol: "exclamationmark.triangle", title: "Couldn’t load this file", detail: message) {
                    Button("Retry") { model.retry() }.buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                }
            case .loaded(let content):
                loaded(content)
            }
        }
    }

    @ViewBuilder
    private func loaded(_ content: PreviewContent) -> some View {
        if case .collapsed(let bytes) = content.file {
            PreviewStateView(
                symbol: "doc.text", title: "Large file collapsed",
                detail: "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · generated or too large to show by default."
            ) {
                Button("Load anyway") { model.loadAnyway() }.buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
            }
        } else if let document = model.document, document.mode == model.mode {
            CodeView(
                model: model, document: document, documentVersion: model.documentVersion,
                focusedThreadID: model.focusedThreadID, scrollRequest: model.scrollRequest, newComment: model.newComment,
                theme: theme
            )
        } else if model.mode == .diff {
            if content.patch.patch != nil {
                PreviewSkeleton()
            } else if case .binary = content.file {
                PreviewStateView(symbol: "doc.richtext", title: "Binary file", detail: "Gitoken can’t show binary files.")
            } else {
                PreviewStateView(
                    symbol: "doc.plaintext", title: "No diff for this file",
                    detail: content.patch.status == .unchanged
                        ? "The file is unchanged in this pull request."
                        : "GitHub didn’t include a diff (too large or binary)."
                ) {
                    if case .text = content.file {
                        Button("Show File") { model.setMode(.file) }.buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                    }
                }
            }
        } else {
            switch content.file {
            case .text, .collapsed:
                PreviewSkeleton()
            case .binary:
                PreviewStateView(symbol: "doc.richtext", title: "Binary file", detail: "Gitoken can’t show binary files.")
            case .missing:
                PreviewStateView(symbol: "questionmark.folder", title: "File not present at \(PreviewModel.short(content.viewing.oid))") {
                    if content.patch.patch != nil {
                        Button("Show Diff") { model.setMode(.diff) }.buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                    }
                }
            }
        }
    }
}

/// Centered symbol, title, optional detail and actions.
private struct PreviewStateView<Actions: View>: View {
    var symbol: String
    var title: String
    var detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            actions.padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PreviewStateView where Actions == EmptyView {
    init(symbol: String, title: String, detail: String? = nil) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// Placeholder lines while content loads.
private struct PreviewSkeleton: View {
    @State private var dim = false
    private static let widths: [CGFloat] = [0.42, 0.7, 0.55, 0.82, 0.3, 0.64, 0.5, 0.76, 0.38, 0.6, 0.47, 0.68]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(Self.widths.enumerated()), id: \.offset) { _, width in
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: proxy.size.width * width)
                }
                .frame(height: 9)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 56)
        .padding(.trailing, 24)
        .padding(.top, 16)
        .opacity(dim ? 0.5 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityLabel("Loading")
    }
}
