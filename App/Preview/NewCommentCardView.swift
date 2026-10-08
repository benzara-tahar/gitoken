import GitokenCore
import SwiftUI

/// The new-comment composer under the last selected line: Return adds the comment to the pending review, ⌘Return
/// posts it on its own (only without a pending review), Esc cancels.
struct NewCommentCardView: View {
    @Environment(PreviewModel.self) private var model
    @Environment(\.theme) private var theme
    let anchor: NewCommentAnchor

    @State private var height: CGFloat = 28
    @State private var focus = 0

    var body: some View {
        let text = Binding(get: { model.newCommentText }, set: { model.newCommentText = $0 })
        let empty = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let posting = model.isPostingComment
        let pending = model.hasPendingReview
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Chip(text: pending ? "Add to your review" : "New comment", symbol: "plus.bubble", tone: .accent)
                Text(lineLabel).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                IconButton(symbol: "xmark", label: "Cancel (Esc)", size: 20) { model.cancelNewComment() }
            }
            ComposerTextView(
                text: text, height: $height, maxHeight: 200, focusToken: focus,
                onSubmit: { post(now: false) }, onFocusChange: { model.newCommentFocused = $0 }
            )
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text("Leave a comment…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.inputBackground))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.accent.opacity(0.6), lineWidth: 1))
            HStack(spacing: 6) {
                Text(pending ? "Shift-Return for a new line" : "⌘Return comments now")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if posting { ProgressView().controlSize(.mini) }
                Button("Comment now") { post(now: true) }
                    .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                    .disabled(empty || posting || pending)
                    .help(pending
                        ? "You have a pending review: add this comment to it, then submit the review"
                        : "Post this comment on its own (⌘Return)")
                Button("Add to review") { post(now: false) }
                    .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
                    .disabled(empty || posting)
                    .help("Add to your pending review (Return)")
            }
            if let error = model.newCommentError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.isFluid ? Color(white: 0.115) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.accent.opacity(0.85), lineWidth: 1.5)
        )
        // A fresh ComposerTextView takes focus only when its token changes after creation.
        .onAppear { DispatchQueue.main.async { focus += 1 } }
        .onChange(of: model.newCommentFocusToken) { focus += 1 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New comment on \(lineLabel)")
    }

    private func post(now: Bool) {
        Task { await model.postNewComment(now: now) }
    }

    /// "L12", "L12–L18", or "Old L12" for removed lines.
    private var lineLabel: String {
        let position = anchor.position
        let prefix = position.side == .left ? "Old " : ""
        if let start = position.startLine, start != position.line { return "\(prefix)L\(start)–L\(position.line)" }
        return "\(prefix)L\(position.line)"
    }
}
