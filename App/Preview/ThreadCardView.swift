import AppKit
import GitokenCore
import SwiftUI

/// One review thread under its line: status chips and line range, the comments, and Reply / Resolve / Open on
/// GitHub. Resolved threads collapse to one line until clicked.
struct ThreadCardView: View {
    @Environment(NotchModel.self) private var notch
    @Environment(PreviewModel.self) private var model
    @Environment(\.theme) private var theme
    let thread: ReviewThread

    @State private var expanded = false
    @State private var resolving = false
    @State private var sending = false
    @State private var deleting: Set<String> = []
    @State private var composerHeight: CGFloat = 28
    @State private var composerFocus = 0

    private var focused: Bool { model.focusedThreadID == thread.id }
    private var replying: Bool { model.replyingThreadID == thread.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if thread.isResolved && !expanded && !replying {
                collapsed
            } else {
                full
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.isFluid ? Color(white: 0.115) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? theme.accent.opacity(0.85) : theme.hairline, lineWidth: focused ? 1.5 : 0.5)
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.focus(thread.id, scroll: false) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review thread on \(lineLabel)")
    }

    // MARK: Collapsed

    private var collapsed: some View {
        Button {
            expanded = true
            model.focus(thread.id, scroll: false)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
                Text("Resolved").fontWeight(.semibold)
                Text(lineLabel).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                if let root = thread.root {
                    Text("\(root.author.displayName): \(root.body.plainText.split(whereSeparator: \.isWhitespace).joined(separator: " "))")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resolved thread on \(lineLabel). Expand")
    }

    // MARK: Full

    private var full: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(thread.comments) { comment in
                commentRow(comment)
            }
            if replying {
                composer
            } else {
                footer
            }
            if let error = model.cardErrors[thread.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if thread.isPending { Chip(text: "Pending", symbol: "hourglass", tone: .accent) }
            if thread.isOutdated { Chip(text: "Outdated", symbol: "clock.arrow.circlepath", tone: .warn) }
            if thread.isResolved { Chip(text: "Resolved", symbol: "checkmark", tone: .success) }
            Text(lineLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if thread.isResolved {
                IconButton(symbol: "chevron.up", label: "Collapse", size: 20) { expanded = false }
            }
        }
    }

    private func commentRow(_ comment: ReviewComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(actor: comment.author, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.author.displayName).font(.system(size: 12, weight: .semibold))
                    TimelineView(.everyMinute) { _ in
                        Text(Format.ago(comment.createdAt, now: notch.store.now.now()))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .help(comment.createdAt.formatted(date: .complete, time: .shortened))
                    }
                    if comment.isPending, !thread.isPending { Chip(text: "Pending", tone: .accent) }
                    Spacer(minLength: 4)
                    if comment.isPending {
                        if deleting.contains(comment.id) {
                            ProgressView().controlSize(.mini).frame(width: 20, height: 20)
                        } else {
                            IconButton(symbol: "trash", label: "Delete pending comment", size: 20) { delete(comment) }
                        }
                    }
                }
                RichBodyView(source: comment.body, size: 12.5, clampHeight: 520)
                if let item = Suggestions.item(for: comment, in: thread) {
                    let batched = model.isBatched(comment.id)
                    action(batched ? "Remove from batch" : "Add to batch", symbol: batched ? "minus.circle" : "plus.circle") {
                        model.toggleBatch(item, in: thread)
                    }
                    .help(batched
                        ? "Leave this suggestion out of the next commit"
                        : "Collect this suggestion and commit it with others in one commit")
                    .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if thread.viewerCanReply, !thread.isPending {
                action("Reply", symbol: "arrowshape.turn.up.left") { model.startReply(in: thread.id) }
                    .help("Reply (R)")
            }
            if !thread.isPending, thread.isResolved ? thread.viewerCanUnresolve : thread.viewerCanResolve {
                action(thread.isResolved ? "Unresolve" : "Resolve", symbol: thread.isResolved ? "arrow.uturn.backward" : "checkmark", busy: resolving) {
                    resolve(!thread.isResolved)
                }
            }
            Spacer(minLength: 4)
            if let url = thread.comments.last?.url ?? thread.root?.url {
                action("Open on GitHub", symbol: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func action(_ title: String, symbol: String, busy: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.chipBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    // MARK: Reply

    private var composer: some View {
        let draft = Binding(get: { model.drafts[thread.id] ?? "" }, set: { model.drafts[thread.id] = $0 })
        let canSend = !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 6) {
                ComposerTextView(
                    text: draft, height: $composerHeight, maxHeight: 160, focusToken: composerFocus,
                    onSubmit: send, onFocusChange: { _ in }
                )
                .frame(height: composerHeight)
                .overlay(alignment: .topLeading) {
                    if draft.wrappedValue.isEmpty {
                        Text("Reply in thread…")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 5)
                            .allowsHitTesting(false)
                    }
                }
                Button(action: send) {
                    Group {
                        if sending {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(theme.accent))
                    .opacity(canSend || sending ? 1 : 0.3)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send reply")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.inputBackground))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.accent.opacity(0.6), lineWidth: 1))
            HStack {
                Text("Return to send · Shift-Return for a new line")
                Spacer()
                Button("Cancel") { model.cancelReply() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Text("Esc")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
        }
        // A fresh ComposerTextView takes focus only when its token changes after creation.
        .onAppear { DispatchQueue.main.async { composerFocus += 1 } }
        .onChange(of: model.replyFocusToken) { composerFocus += 1 }
    }

    private func send() {
        guard !sending else { return }
        sending = true
        Task {
            await model.sendReply(in: thread)
            sending = false
        }
    }

    private func delete(_ comment: ReviewComment) {
        guard deleting.insert(comment.id).inserted else { return }
        Task {
            await model.deletePendingComment(comment, in: thread)
            deleting.remove(comment.id)
        }
    }

    private func resolve(_ resolved: Bool) {
        guard !resolving else { return }
        resolving = true
        Task {
            await model.setResolved(thread, resolved)
            resolving = false
            if resolved { expanded = false }
        }
    }

    // MARK: Labels

    /// "L12" or "L12–L18" at the viewed commit (original lines while viewing an outdated thread's commit).
    private var lineLabel: String {
        let original = model.content?.viewing.isOriginal == true || thread.line == nil
        let end = original ? thread.originalLine : thread.line
        let start = original ? thread.originalStartLine : thread.startLine
        guard let end else { return "File" }
        if let start, start != end { return "L\(start)–L\(end)" }
        return "L\(end)"
    }
}
