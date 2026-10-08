import AppKit
import GitokenCore
import SwiftUI

/// Scrollable `CodeTextView` showing the model's document, with thread cards and the new-comment composer hosted inline.
struct CodeView: NSViewRepresentable {
    let model: PreviewModel
    let document: PreviewDocument
    let documentVersion: Int
    let focusedThreadID: String?
    let scrollRequest: Int
    let newComment: NewCommentAnchor?
    let theme: Theme

    final class Coordinator {
        weak var textView: CodeTextView?
        var documentVersion: Int?
        var theme: Theme?
        var focusedThreadID: String?
        var scrollRequest: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.findBarPosition = .aboveContent

        let textView = CodeTextView(usingTextLayoutManager: true)
        textView.configure()
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        let model = model
        textView.makeCard = { line, threadIDs, onHeight in
            let root = ThreadCardStackRoot(model: model, line: line, threadIDs: threadIDs, onHeight: onHeight)
            let host = ThreadCardHostingView(rootView: root)
            host.sizingOptions = []
            return host
        }
        textView.onGutterSelection = { [weak model] from, to in model?.selectLines(from, to) }
        scroll.documentView = textView
        context.coordinator.textView = textView
        model.codeTextView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }
        let documentChanged = coordinator.documentVersion != documentVersion
        if documentChanged || coordinator.theme != theme {
            coordinator.documentVersion = documentVersion
            coordinator.theme = theme
            textView.show(document, palette: CodePalette(theme: theme), rebuildCards: documentChanged)
        }
        let scrollRequested = coordinator.scrollRequest != scrollRequest
        if scrollRequested || documentChanged || coordinator.focusedThreadID != focusedThreadID {
            coordinator.focusedThreadID = focusedThreadID
            coordinator.scrollRequest = scrollRequest
            textView.setFocus(focusedThreadID, scroll: scrollRequested || documentChanged)
        }
        textView.setComposer(
            line: newComment?.lineIndex, lines: newComment.map { $0.startLineIndex...$0.lineIndex })
    }
}

extension CodePalette {
    init(theme: Theme) {
        text = .labelColor
        background = theme.isFluid ? NSColor(white: 0.075, alpha: 1) : .textBackgroundColor
        gutterBackground = NSColor.labelColor.withAlphaComponent(theme.isFluid ? 0.045 : 0.035)
        gutterText = .tertiaryLabelColor
        separator = NSColor.separatorColor
        added = NSColor(theme.success.opacity(0.13))
        removed = NSColor(theme.danger.opacity(0.13))
        addedGutter = NSColor(theme.success.opacity(0.1))
        removedGutter = NSColor(theme.danger.opacity(0.1))
        hunk = NSColor(theme.accent.opacity(0.08))
        hunkText = .secondaryLabelColor
        focus = NSColor(theme.accent.opacity(0.1))
        selection = NSColor(theme.accent.opacity(0.2))
        accent = NSColor(theme.accent)
        token = { NSColor(theme.tokenColor($0)) }
    }
}

/// Clicks on a card land even while another app is active (the preview never activates Gitoken).
final class ThreadCardHostingView: NSHostingView<ThreadCardStackRoot> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// All threads anchored to one line, stacked in one card view that reports its natural height to the text view, plus
/// the new-comment composer when it sits under this line.
struct ThreadCardStackRoot: View {
    let model: PreviewModel
    let line: Int
    let threadIDs: [String]
    let onHeight: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(threadIDs, id: \.self) { id in
                if let thread = model.thread(id) {
                    ThreadCardView(thread: thread)
                }
            }
            if let anchor = model.newComment, anchor.lineIndex == line {
                NewCommentCardView(anchor: anchor)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight(ceil($0)) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(model.notch)
        .environment(model)
        .environment(\.theme, model.notch.theme)
        .environment(\.motion, model.notch.motion)
    }
}
