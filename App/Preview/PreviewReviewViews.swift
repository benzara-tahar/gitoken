import GitokenCore
import SwiftUI

// MARK: - File list

/// The pull request's changed files beside the code: status, +/−, unresolved threads and pending comments per file.
/// Clicking a file retargets the window to it.
struct PreviewFileSidebar: View {
    @Environment(PreviewModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Files").font(.system(size: 11.5, weight: .semibold))
                if let files = model.changedFiles {
                    Text("\(files.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if model.isLoadingFiles { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            list
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(theme.isFluid ? 0.03 : 0.025))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
        // Also after a suggestion commit, which drops the list listed at the old head.
        .onChange(of: model.changedFiles == nil, initial: true) { _, missing in
            if missing, !model.isLoadingFiles, model.filesError == nil { model.loadFiles() }
        }
    }

    @ViewBuilder
    private var list: some View {
        if let files = model.changedFiles {
            if files.isEmpty {
                message("No changed files")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(files) { file in
                                PreviewFileRow(file: file, selected: model.target?.path == file.path).id(file.path)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .onAppear { if let path = model.target?.path { proxy.scrollTo(path) } }
                    .onChange(of: model.target?.path) { _, path in
                        if let path { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(path) } }
                    }
                }
            }
        } else if let error = model.filesError {
            VStack(spacing: 6) {
                Text("Couldn’t load the files").font(.system(size: 12, weight: .semibold))
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { model.loadFiles() }.buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        } else {
            message("Loading files…")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity)
    }
}

private struct PreviewFileRow: View {
    @Environment(PreviewModel.self) private var model
    @Environment(\.theme) private var theme
    let file: ChangedFile
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let counts = model.threadCounts(on: file.path)
        let directory = (file.path as NSString).deletingLastPathComponent
        Button { model.openFile(file.path) } label: {
            HStack(spacing: 7) {
                Text(glyph.letter)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(glyph.tone.color(theme))
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.basename(file.path))
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !directory.isEmpty {
                        Text(directory)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 2)
                if counts.pending > 0 {
                    Label("\(counts.pending)", systemImage: "hourglass")
                        .foregroundStyle(theme.accent)
                        .help(Format.plural(counts.pending, "pending comment"))
                }
                if counts.unresolved > 0 {
                    Label("\(counts.unresolved)", systemImage: "text.bubble")
                        .foregroundStyle(.secondary)
                        .help(Format.plural(counts.unresolved, "unresolved thread"))
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text("+\(file.additions)").foregroundStyle(theme.success)
                    Text("−\(file.deletions)").foregroundStyle(theme.danger)
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .labelStyle(CompactCountLabelStyle())
            .padding(.horizontal, 6)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? theme.accent.opacity(0.16) : hovering ? Color.primary.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(file.previousPath.map { "\($0) → \(file.path)" } ?? file.path)
        .accessibilityLabel("\(file.path), \(glyph.name), \(file.additions) additions, \(file.deletions) deletions")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var glyph: (letter: String, tone: Tone, name: String) {
        switch file.status {
        case .added: ("A", .success, "added")
        case .removed: ("D", .danger, "deleted")
        case .renamed: ("R", .accent, "renamed")
        case .copied: ("C", .accent, "copied")
        case .modified, .changed: ("M", .warn, "modified")
        case .unchanged: ("·", .neutral, "unchanged")
        }
    }
}

private struct CompactCountLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title.font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
        }
    }
}

// MARK: - Popovers

/// Card chrome for the in-window popovers under the toolbar.
private struct PopoverCard: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(width: 340, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.menuBackground))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }
}

/// Finish the review: optional summary, Comment / Approve / Request changes, Submit; discard the pending review.
struct ReviewPopoverView: View {
    @Environment(PreviewModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var summaryHeight: CGFloat = 28
    @State private var focus = 0
    @State private var confirmingDiscard = false

    var body: some View {
        let summary = Binding(get: { model.reviewSummary }, set: { model.reviewSummary = $0 })
        let pending = model.pendingCommentCount
        let isAuthor = model.reviewThreads?.viewerIsAuthor == true
        let busy = model.isSubmittingReview || model.isDiscardingReview
        let hasSummary = !summary.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSubmit = !busy && model.reviewThreads != nil && (model.reviewEvent != .comment || pending > 0 || hasSummary)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Finish your review").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(pending > 0 ? Format.plural(pending, "pending comment") : "No pending comments")
                    .font(.system(size: 11))
                    .foregroundStyle(pending > 0 ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.tertiary))
            }
            ComposerTextView(
                text: summary, height: $summaryHeight, maxHeight: 160, focusToken: focus,
                onSubmit: { if canSubmit { submit() } }, onFocusChange: { _ in }
            )
            .frame(height: max(summaryHeight, 56))
            .overlay(alignment: .topLeading) {
                if summary.wrappedValue.isEmpty {
                    Text("Leave a summary (optional)")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.inputBackground))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
            eventPicker(isAuthor: isAuthor)
            if let error = model.reviewError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if model.hasPendingReview { discard(pending: pending, busy: busy) }
                Spacer(minLength: 4)
                if model.isSubmittingReview { ProgressView().controlSize(.mini) }
                Button("Submit review") { submit() }
                    .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
                    .disabled(!canSubmit)
                    .help("Submit (Return in the summary)")
            }
        }
        .modifier(PopoverCard())
        .onAppear { DispatchQueue.main.async { focus += 1 } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Finish your review")
    }

    private func eventPicker(isAuthor: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(ReviewEvent.allCases, id: \.self) { event in
                let disabled = isAuthor && event != .comment
                let selected = model.reviewEvent == event
                HStack {
                    Button { model.reviewEvent = event } label: {
                        Label(title(event), systemImage: symbol(event))
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(selected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.primary))
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? theme.accent.opacity(0.18) : .clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .opacity(disabled ? 0.4 : 1)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                // On the wrapper: disabled buttons show no tooltip.
                .help(disabled ? "You can’t approve or request changes on your own pull request." : help(event))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(theme.isFluid ? 0.08 : 0.05)))
    }

    @ViewBuilder
    private func discard(pending: Int, busy: Bool) -> some View {
        if confirmingDiscard {
            Text(pending > 0 ? "Delete \(Format.plural(pending, "comment"))?" : "Discard?")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if model.isDiscardingReview { ProgressView().controlSize(.mini) }
            Button("Discard") {
                Task {
                    await model.discardPendingReview()
                    confirmingDiscard = false
                }
            }
            .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.danger))
            .disabled(busy)
            Button("Keep") { confirmingDiscard = false }
                .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                .disabled(busy)
        } else {
            Button("Discard pending review") { confirmingDiscard = true }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.danger)
                .disabled(busy)
        }
    }

    private func submit() {
        Task { await model.submitReview() }
    }

    private func title(_ event: ReviewEvent) -> String {
        switch event {
        case .comment: "Comment"
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        }
    }

    private func symbol(_ event: ReviewEvent) -> String {
        switch event {
        case .comment: "text.bubble"
        case .approve: "checkmark.circle"
        case .requestChanges: "exclamationmark.bubble"
        }
    }

    private func help(_ event: ReviewEvent) -> String {
        switch event {
        case .comment: "General feedback without explicit approval"
        case .approve: "Approve merging these changes"
        case .requestChanges: "Feedback that must be addressed before merging"
        }
    }
}

/// Commit the batched suggestions as one commit on the head branch.
struct CommitSuggestionsPopoverView: View {
    @Environment(PreviewModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var headlineFocused: Bool

    var body: some View {
        let items = model.batchedSuggestions
        let headline = Binding(get: { model.commitHeadline }, set: { model.commitHeadline = $0 })
        let files = Set(items.map(\.path)).count
        return VStack(alignment: .leading, spacing: 10) {
            Text("Commit suggestions").font(.system(size: 13, weight: .semibold))
            Text(summary(count: items.count, files: files))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.prefix(6)) { item in
                    Text("\(Format.basename(item.path)) \(item.startLine == item.endLine ? "L\(item.endLine)" : "L\(item.startLine)–L\(item.endLine)")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.path)
                }
                if items.count > 6 {
                    Text("and \(items.count - 6) more").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            TextField("Commit headline", text: headline)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($headlineFocused)
                .onSubmit(commit)
            if let error = model.commitError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 4)
                if model.isCommitting { ProgressView().controlSize(.mini) }
                Button("Commit") { commit() }
                    .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
                    .disabled(model.isCommitting || items.isEmpty)
            }
        }
        .modifier(PopoverCard())
        .onAppear { DispatchQueue.main.async { headlineFocused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commit suggestions")
    }

    private func summary(count: Int, files: Int) -> String {
        let branch = model.reviewThreads?.headRefName
        let target = branch.map { " to \($0)" } ?? ""
        return "\(Format.plural(count, "suggestion")) in \(Format.plural(files, "file")), as one commit\(target)."
    }

    private func commit() {
        guard !model.isCommitting, !model.batchedSuggestions.isEmpty else { return }
        Task { await model.commitSuggestions() }
    }
}
