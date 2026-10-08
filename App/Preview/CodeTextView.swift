import AppKit
import GitokenCore

/// Colors the code view draws with, resolved from `Theme` (see `CodeView`).
struct CodePalette {
    var text: NSColor
    var background: NSColor
    var gutterBackground: NSColor
    var gutterText: NSColor
    var separator: NSColor
    var added: NSColor
    var removed: NSColor
    var addedGutter: NSColor
    var removedGutter: NSColor
    var hunk: NSColor
    var hunkText: NSColor
    var focus: NSColor
    var selection: NSColor
    var accent: NSColor
    var token: (HighlightKind) -> NSColor
}

/// Read-only TextKit 2 code view: a line-number gutter (old/new columns and a +/- marker column in diff mode),
/// full-width diff row backgrounds, a tint over the focused thread's lines, and thread cards (subviews) laid out
/// under their anchor lines in space reserved with that line's paragraph spacing. Clicking or dragging across line
/// numbers selects lines for a new comment, whose composer card joins the cards under the last selected line.
final class CodeTextView: NSTextView {
    typealias CardFactory = (_ line: Int, _ threadIDs: [String], _ onHeight: @escaping (CGFloat) -> Void) -> NSView

    var makeCard: CardFactory?
    /// A finished gutter selection, from the pressed line index to the released one.
    var onGutterSelection: ((_ from: Int, _ to: Int) -> Void)?

    private(set) var document: PreviewDocument?
    private var palette: CodePalette?
    private var textLength = 0
    private var focusedThreadID: String?
    /// Line the new-comment composer sits under; it gets a card even without threads.
    private var composerLine: Int?
    /// Lines the open composer covers.
    private var commentLines: ClosedRange<Int>?
    /// Lines under an in-progress gutter drag.
    private var dragLines: ClosedRange<Int>?
    private var cards: [Int: Card] = [:]
    private var gutter = Gutter()
    private var documentGeneration = 0
    private var relayoutScheduled = false
    /// While set, relayouts re-apply the focus scroll: cards above the target settle their heights after the first pass.
    private var focusScrollDeadline: Date?

    private struct Card {
        let threadIDs: [String]
        let view: NSView
        var height: CGFloat
    }

    private struct Gutter {
        var mode: PreviewMode = .file
        var digits = 3
        var columnWidth: CGFloat { CGFloat(digits) * CodeTextView.digitWidth + 14 }
        var markerWidth: CGFloat { mode == .diff ? 14 : 0 }
        /// Numbers + markers; the code starts `textGap` after it.
        var columnsWidth: CGFloat { (mode == .diff ? 2 * columnWidth : columnWidth) + markerWidth }
        var width: CGFloat { columnsWidth + CodeTextView.textGap }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private static let digitWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
    private static let textGap: CGFloat = 10
    private static let rightInset: CGFloat = 14
    private static let verticalInset: CGFloat = 8
    private static let cardGap: CGFloat = 6
    private static let placeholderCardHeight: CGFloat = 72
    /// Documents up to this many lines are laid out completely once loaded, so card positions are exact.
    private static let fullLayoutLineLimit = 10_000

    private static let baseParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        style.tabStops = []
        style.defaultTabInterval = space * 4
        return style
    }()

    /// Call once after `init(usingTextLayoutManager: true)`.
    func configure() {
        isEditable = false
        isSelectable = true
        isRichText = false
        allowsUndo = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        usesFontPanel = false
        isAutomaticLinkDetectionEnabled = false
        drawsBackground = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        focusRingType = .none
        font = Self.font
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        applyInsets()
        setAccessibilityLabel("Code")
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: gutter.width, y: Self.verticalInset) }

    private func applyInsets() {
        textContainerInset = NSSize(width: (gutter.width + Self.rightInset) / 2, height: Self.verticalInset)
        invalidateTextContainerOrigin()
    }

    // MARK: Content

    /// Renders `document`. `rebuildCards` is false when only the palette changed (cards keep their heights). A rebuild
    /// of the same text (threads added or removed) keeps the scroll position.
    func show(_ document: PreviewDocument, palette: CodePalette, rebuildCards: Bool) {
        let sameText = self.document.map { $0.mode == document.mode && $0.text == document.text } ?? false
        self.document = document
        self.palette = palette
        textLength = (document.text as NSString).length
        backgroundColor = palette.background
        insertionPointColor = palette.text

        var nextGutter = Gutter()
        nextGutter.mode = document.mode
        let maxNumber = document.lines.reduce(0) { max($0, $1.oldNumber ?? 0, $1.newNumber ?? 0) }
        nextGutter.digits = max(3, String(maxNumber).count)
        if nextGutter.mode != gutter.mode || nextGutter.digits != gutter.digits {
            gutter = nextGutter
            applyInsets()
        }

        if rebuildCards {
            documentGeneration += 1
            setSelectedRange(NSRange(location: 0, length: 0))
            replaceCards()
        }
        textStorage?.setAttributedString(attributedText(document, palette: palette))
        for line in cards.keys { reserveSpace(under: line) }
        if rebuildCards, !sameText { scrollToBeginningOfDocument(nil) }
        if document.lines.count <= Self.fullLayoutLineLimit, let layout = textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        }
        layoutCards()
        needsDisplay = true
    }

    private func attributedText(_ document: PreviewDocument, palette: CodePalette) -> NSAttributedString {
        // A trailing newline makes the last real line a non-final paragraph, so its paragraph spacing (a card) applies.
        let text = NSMutableAttributedString(string: document.text + "\n", attributes: [
            .font: Self.font, .foregroundColor: palette.text, .paragraphStyle: Self.baseParagraph,
        ])
        var tokenColors: [HighlightKind: NSColor] = [:]
        text.beginEditing()
        for span in document.spans where span.range.location >= 0 && NSMaxRange(span.range) <= textLength {
            let color = tokenColors[span.kind] ?? palette.token(span.kind)
            tokenColors[span.kind] = color
            text.addAttribute(.foregroundColor, value: color, range: span.range)
        }
        for (index, line) in document.lines.enumerated() where line.kind == .hunkHeader {
            text.addAttribute(.foregroundColor, value: palette.hunkText, range: lineRange(index))
        }
        text.endEditing()
        return text
    }

    /// UTF-16 range of line `index` without its newline.
    private func lineRange(_ index: Int) -> NSRange {
        guard let starts = document?.lineStarts, starts.indices.contains(index) else { return NSRange(location: 0, length: 0) }
        let end = index + 1 < starts.count ? starts[index + 1] - 1 : textLength
        return NSRange(location: starts[index], length: max(0, end - starts[index]))
    }

    /// The paragraph of line `index` including its newline (the last line owns the appended one).
    private func paragraphRange(_ index: Int) -> NSRange {
        guard let starts = document?.lineStarts, starts.indices.contains(index) else { return NSRange(location: 0, length: 0) }
        let end = index + 1 < starts.count ? starts[index + 1] : textLength + 1
        return NSRange(location: starts[index], length: end - starts[index])
    }

    // MARK: Cards

    private func replaceCards() {
        for card in cards.values { card.view.removeFromSuperview() }
        cards = [:]
        guard let document, let makeCard else { return }
        var grouped: [Int: [String]] = [:]
        for anchor in document.anchors where grouped[anchor.lineIndex]?.contains(anchor.threadID) != true {
            grouped[anchor.lineIndex, default: []].append(anchor.threadID)
        }
        if let composerLine, document.lines.indices.contains(composerLine), grouped[composerLine] == nil {
            grouped[composerLine] = []
        }
        for (line, ids) in grouped { addCard(line: line, threadIDs: ids, makeCard: makeCard) }
    }

    private func addCard(line: Int, threadIDs: [String], makeCard: CardFactory) {
        let generation = documentGeneration
        let view = makeCard(line, threadIDs) { [weak self] height in
            guard let self, self.documentGeneration == generation else { return }
            self.cardHeightChanged(line: line, height: height)
        }
        addSubview(view, positioned: .above, relativeTo: nil)
        cards[line] = Card(threadIDs: threadIDs, view: view, height: Self.placeholderCardHeight)
    }

    /// Moves the new-comment composer card (nil closes it) and the highlighted line range it covers.
    func setComposer(line: Int?, lines: ClosedRange<Int>?) {
        if lines != commentLines {
            commentLines = lines
            needsDisplay = true
        }
        guard line != composerLine else { return }
        let old = composerLine
        composerLine = line
        guard let document, let makeCard else { return }
        // Cards with threads stay; their content drops or adds the composer by itself.
        if let old, let card = cards[old], card.threadIDs.isEmpty {
            card.view.removeFromSuperview()
            cards[old] = nil
            clearSpace(under: old)
        }
        if let line, document.lines.indices.contains(line), cards[line] == nil {
            addCard(line: line, threadIDs: [], makeCard: makeCard)
            reserveSpace(under: line)
        }
        scheduleRelayout()
    }

    private func cardHeightChanged(line: Int, height: CGFloat) {
        guard var card = cards[line], abs(card.height - height) > 0.5 else { return }
        card.height = height
        cards[line] = card
        reserveSpace(under: line)
        scheduleRelayout()
    }

    private func reserveSpace(under line: Int) {
        guard let card = cards[line] else { return }
        setParagraphSpacing(card.height + Self.cardGap * 2, line: line)
    }

    private func clearSpace(under line: Int) { setParagraphSpacing(0, line: line) }

    private func setParagraphSpacing(_ spacing: CGFloat, line: Int) {
        guard let storage = textStorage else { return }
        let range = paragraphRange(line)
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let style = Self.baseParagraph.mutableCopy() as! NSMutableParagraphStyle
        style.paragraphSpacing = spacing
        if let content = textContentStorage {
            content.performEditingTransaction { storage.addAttribute(.paragraphStyle, value: style, range: range) }
        } else {
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    private func scheduleRelayout() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.relayoutScheduled = false
            if let document = self.document, document.lines.count <= Self.fullLayoutLineLimit, let layout = self.textLayoutManager {
                layout.ensureLayout(for: layout.documentRange)
            }
            self.layoutCards()
            if let deadline = self.focusScrollDeadline, Date() < deadline { self.scrollToFocus(force: true) }
            self.needsDisplay = true
        }
    }

    private func layoutFragment(forLine line: Int) -> NSTextLayoutFragment? {
        guard let document, document.lineStarts.indices.contains(line),
              let layout = textLayoutManager, let content = textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: document.lineStarts[line]) else {
            return nil
        }
        return layout.textLayoutFragment(for: location)
    }

    /// Bottom of a fragment's text in view coordinates (its frame also includes the reserved card space).
    private func textBottom(of fragment: NSTextLayoutFragment) -> CGFloat {
        textContainerOrigin.y + fragment.layoutFragmentFrame.minY + Self.textHeight(of: fragment)
    }

    /// Height of the fragment's text lines, skipping the empty extra line the appended final newline produces.
    private static func textHeight(of fragment: NSTextLayoutFragment) -> CGFloat {
        let lines = fragment.textLineFragments
        let last = lines.last { $0.characterRange.length > 0 } ?? lines.last
        return last?.typographicBounds.maxY ?? fragment.layoutFragmentFrame.height
    }

    private func layoutCards() {
        guard let container = textContainer else { return }
        let x = textContainerOrigin.x
        let width = max(0, container.size.width)
        for (line, card) in cards {
            guard let fragment = layoutFragment(forLine: line) else {
                card.view.isHidden = true
                continue
            }
            let rect = NSRect(x: x, y: textBottom(of: fragment) + Self.cardGap, width: width, height: card.height).integral
            card.view.isHidden = false
            if card.view.frame != rect { card.view.frame = rect }
        }
    }

    override func viewWillDraw() {
        layoutCards()
        super.viewWillDraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            layoutCards()
            scheduleRelayout()
        }
    }

    // MARK: Focus

    func setFocus(_ threadID: String?, scroll: Bool) {
        if threadID != focusedThreadID {
            focusedThreadID = threadID
            needsDisplay = true
        }
        guard scroll, threadID != nil else { return }
        focusScrollDeadline = Date().addingTimeInterval(0.6)
        scrollToFocus(force: false)
        scheduleRelayout()
    }

    private var focusedLines: ClosedRange<Int>? {
        guard let focusedThreadID, let anchors = document?.anchors.filter({ $0.threadID == focusedThreadID }),
              let first = anchors.map(\.startLineIndex).min(), let last = anchors.map(\.lineIndex).max() else { return nil }
        return min(first, last)...last
    }

    /// Brings the focused range and its card into view with a top margin; `force` re-centers even when visible.
    private func scrollToFocus(force: Bool) {
        guard let lines = focusedLines, let scrollView = enclosingScrollView else { return }
        ensureLayout(through: lines.upperBound)
        guard let top = layoutFragment(forLine: lines.lowerBound) else { return }
        layoutCards()
        let rangeTop = textContainerOrigin.y + top.layoutFragmentFrame.minY
        let cardBottom = cards[lines.upperBound].map { $0.view.frame.maxY }
            ?? layoutFragment(forLine: lines.upperBound).map(textBottom) ?? rangeTop
        let visible = scrollView.documentVisibleRect
        let margin: CGFloat = 48
        let fits = rangeTop >= visible.minY + 8 && cardBottom <= visible.maxY - 8
        guard force || !fits else { return }
        let maxY = max(0, bounds.height - visible.height)
        let y = min(max(0, rangeTop - margin), maxY)
        guard abs(visible.minY - y) > 1 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Large documents lay out lazily; make sure everything above `line` (and the line itself) has real positions.
    private func ensureLayout(through line: Int) {
        guard let document, document.lines.count > Self.fullLayoutLineLimit, document.lineStarts.indices.contains(line),
              let layout = textLayoutManager, let content = textContentStorage else { return }
        let end = paragraphRange(line)
        guard let location = content.location(content.documentRange.location, offsetBy: NSMaxRange(end)),
              let range = NSTextRange(location: content.documentRange.location, end: location) else { return }
        layout.ensureLayout(for: range)
    }

    // MARK: Find

    var isFindBarVisible: Bool { enclosingScrollView?.isFindBarVisible ?? false }

    func performFind(_ action: NSTextFinder.Action) {
        if action == .showFindInterface { window?.makeFirstResponder(self) }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
        if action == .hideFindInterface { window?.makeFirstResponder(self) }
    }

    // MARK: Gutter selection

    private func isInGutter(_ event: NSEvent) -> Bool {
        onGutterSelection != nil && document != nil && convert(event.locationInWindow, from: nil).x < gutter.columnsWidth
    }

    /// The line at `point`. Points in a card's reserved space below a line count only when `clamped` (while dragging);
    /// above or below the text they clamp to the first or last line.
    private func lineIndex(at point: NSPoint, clamped: Bool) -> Int? {
        guard let document, !document.lines.isEmpty, let layout = textLayoutManager, let content = textContentStorage else {
            return nil
        }
        let y = point.y - textContainerOrigin.y
        if y < 0 { return clamped ? 0 : nil }
        guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: y)) else {
            return clamped ? document.lines.count - 1 : nil
        }
        if !clamped, point.y > textBottom(of: fragment) { return nil }
        let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return min(document.lineIndex(forOffset: min(offset, textLength)), document.lines.count - 1)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event, isInGutter(event) { return true }
        return super.acceptsFirstMouse(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if isInGutter(event) {
            NSCursor.pointingHand.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isInGutter(event) {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// Press on a line number, drag across others, release: reports the range to `onGutterSelection`.
    override func mouseDown(with event: NSEvent) {
        guard isInGutter(event), let start = lineIndex(at: convert(event.locationInWindow, from: nil), clamped: false),
              let window else {
            super.mouseDown(with: event)
            return
        }
        window.makeFirstResponder(self)
        var end = start
        dragLines = start...start
        needsDisplay = true
        displayIfNeeded()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            autoscroll(with: next)
            if let index = lineIndex(at: visiblePoint(convert(next.locationInWindow, from: nil)), clamped: true), index != end {
                end = index
                dragLines = min(start, end)...max(start, end)
                needsDisplay = true
                displayIfNeeded()
            }
        }
        dragLines = nil
        needsDisplay = true
        onGutterSelection?(start, end)
    }

    /// `point` pulled into the visible part of the document, so dragging past the viewport edge selects up to the edge
    /// line (autoscroll then moves the edge) instead of jumping to the first or last line of the file.
    private func visiblePoint(_ point: NSPoint) -> NSPoint {
        let visible = visibleRect
        guard visible.height > 2 else { return point }
        return NSPoint(x: point.x, y: min(max(point.y, visible.minY + 1), visible.maxY - 1))
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let document, let palette, let layout = textLayoutManager, let content = textContentStorage else { return }
        let columns = gutter.columnsWidth
        palette.gutterBackground.setFill()
        NSRect(x: 0, y: rect.minY, width: columns, height: rect.height).fill()
        palette.separator.setFill()
        NSRect(x: columns - 0.5, y: rect.minY, width: 0.5, height: rect.height).fill()

        let origin = textContainerOrigin
        let focus = focusedLines
        let selection = dragLines ?? commentLines
        let start = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, rect.minY - origin.y)))?.rangeInElement.location
            ?? layout.documentRange.location
        _ = layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let top = origin.y + frame.minY
            guard top <= rect.maxY else { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            guard offset <= self.textLength else { return false }
            let index = document.lineIndex(forOffset: offset)
            guard document.lines.indices.contains(index) else { return true }
            let firstLine = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
            let height = Self.textHeight(of: fragment)
            let row = NSRect(x: 0, y: top, width: self.bounds.width, height: height)
            self.drawRow(
                document.lines[index], row: row, firstLineHeight: firstLine, focused: focus?.contains(index) == true,
                selected: selection?.contains(index) == true, palette: palette)
            return true
        }
    }

    private func drawRow(
        _ line: PreviewLine, row: NSRect, firstLineHeight: CGFloat, focused: Bool, selected: Bool, palette: CodePalette
    ) {
        let columns = gutter.columnsWidth
        switch line.kind {
        case .added:
            palette.added.setFill()
            row.fill()
            palette.addedGutter.setFill()
            NSRect(x: 0, y: row.minY, width: columns, height: row.height).fill(using: .sourceOver)
        case .removed:
            palette.removed.setFill()
            row.fill()
            palette.removedGutter.setFill()
            NSRect(x: 0, y: row.minY, width: columns, height: row.height).fill(using: .sourceOver)
        case .hunkHeader:
            palette.hunk.setFill()
            row.fill()
        case .plain, .context:
            break
        }
        if focused || selected {
            (selected ? palette.selection : palette.focus).setFill()
            row.fill(using: .sourceOver)
            palette.accent.setFill()
            NSRect(x: columns - 2.5, y: row.minY, width: 2.5, height: row.height).fill()
        }
        guard line.kind != .hunkHeader else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.numberFont, .foregroundColor: focused || selected ? palette.accent : palette.gutterText,
        ]
        let numberHeight = Self.numberFont.ascender - Self.numberFont.descender
        let y = row.minY + (firstLineHeight - numberHeight) / 2
        func draw(_ text: String, rightEdge: CGFloat) {
            let string = NSAttributedString(string: text, attributes: attributes)
            string.draw(at: NSPoint(x: rightEdge - string.size().width, y: y))
        }
        switch gutter.mode {
        case .file:
            if let number = line.newNumber ?? line.oldNumber { draw(String(number), rightEdge: gutter.columnWidth - 7) }
        case .diff:
            if let old = line.oldNumber { draw(String(old), rightEdge: gutter.columnWidth - 7) }
            if let new = line.newNumber { draw(String(new), rightEdge: 2 * gutter.columnWidth - 7) }
            let marker = line.kind == .added ? "+" : line.kind == .removed ? "−" : ""
            if !marker.isEmpty { draw(marker, rightEdge: columns - 4) }
        }
    }
}
