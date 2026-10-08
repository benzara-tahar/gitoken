import Foundation

public enum PreviewMode: String, Sendable { case diff, file }

public struct PreviewLine: Hashable, Sendable {
    public enum Kind: Sendable { case plain, context, added, removed, hunkHeader }
    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct ThreadAnchor: Hashable, Sendable {
    public let threadID: String
    /// First line of a multi-line range (== `lineIndex` for single-line).
    public let startLineIndex: Int
    /// The card goes under this line.
    public let lineIndex: Int

    public init(threadID: String, startLineIndex: Int, lineIndex: Int) {
        self.threadID = threadID
        self.startLineIndex = startLineIndex
        self.lineIndex = lineIndex
    }
}

/// One file's preview, ready for the text view: numbered lines, their highlighting, and where each thread sits.
public struct PreviewDocument: Sendable {
    public let mode: PreviewMode
    public let lines: [PreviewLine]
    /// Lines joined with "\n", no trailing newline.
    public let text: String
    /// UTF-16 offset of each line in `text`.
    public let lineStarts: [Int]
    /// Over `text`; empty when skipped.
    public let spans: [HighlightSpan]
    public let highlightSkipped: Bool
    /// Sorted by `lineIndex`; several threads may share a line.
    public let anchors: [ThreadAnchor]
    /// Threads on this path that cannot be placed in this mode/commit (outdated at head, left-side in file mode, …).
    public let unanchored: [String]

    /// File mode shows `fileText` (empty when nil); diff mode shows `patch` (empty when nil).
    /// At `.head` only current threads anchor; at `.original(oid)` only threads first commented on `oid` anchor, by
    /// their original lines, and all others are omitted.
    public static func build(
        mode: PreviewMode, path: String, fileText: String?, patch: String?,
        threads: [ReviewThread], viewing: PreviewCommit
    ) -> PreviewDocument {
        let lines: [PreviewLine] = switch mode {
        case .file: fileText.map(fileLines) ?? []
        case .diff: patch.map(diffLines) ?? []
        }
        let text = lines.map(\.text).joined(separator: "\n")
        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            lineStarts.append(offset)
            offset += line.text.utf16.count + 1
        }

        let language = CodeLanguage.detect(path: path)
        let skipped = text.utf8.count > PreviewSizePolicy.highlightBytes
        let spans: [HighlightSpan] = if skipped || text.isEmpty {
            []
        } else if mode == .file {
            CodeHighlighter.spans(text, language: language)
        } else {
            diffSpans(lines: lines, lineStarts: lineStarts, language: language)
        }

        let (anchors, unanchored) = anchor(threads.filter { $0.path == path }, mode: mode, lines: lines, viewing: viewing)
        return PreviewDocument(
            mode: mode, lines: lines, text: text, lineStarts: lineStarts, spans: spans, highlightSkipped: skipped,
            anchors: anchors, unanchored: unanchored
        )
    }

    /// Line index for a UTF-16 offset (binary search over `lineStarts`).
    public func lineIndex(forOffset offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        guard high > 0 else { return 0 }
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: - Lines

    private static func fileLines(_ text: String) -> [PreviewLine] {
        // "\r\n" is a single Character, so normalize before splitting.
        var rows = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        if rows.count > 1, rows.last?.isEmpty == true { rows.removeLast() }
        return rows.enumerated().map { i, row in
            PreviewLine(kind: .plain, text: String(row), oldNumber: nil, newNumber: i + 1)
        }
    }

    private static func diffLines(_ patch: String) -> [PreviewLine] {
        UnifiedDiff.parse(patch).map { line in
            let kind: PreviewLine.Kind = switch line.kind {
            case .hunkHeader: .hunkHeader
            case .context: .context
            case .added: .added
            case .removed: .removed
            }
            return PreviewLine(kind: kind, text: line.text, oldNumber: line.oldLine, newNumber: line.newLine)
        }
    }

    // MARK: - Highlighting

    /// Highlights the new side (context + added) and the old side (context + removed) as separate files so each parses
    /// cleanly, then maps spans back: context and added lines take new-side spans, removed lines old-side spans.
    private static func diffSpans(lines: [PreviewLine], lineStarts: [Int], language: CodeLanguage?) -> [HighlightSpan] {
        var newSide: [Int] = []
        var oldSide: [Int] = []
        for (i, line) in lines.enumerated() {
            switch line.kind {
            case .context:
                newSide.append(i)
                oldSide.append(i)
            case .added: newSide.append(i)
            case .removed: oldSide.append(i)
            case .plain, .hunkHeader: break
            }
        }
        func mapped(_ side: [Int], keep: Set<PreviewLine.Kind>) -> [HighlightSpan] {
            guard !side.isEmpty else { return [] }
            let texts = side.map { lines[$0].text }
            var sideStarts: [Int] = []
            var offset = 0
            for text in texts {
                sideStarts.append(offset)
                offset += text.utf16.count + 1
            }
            var out: [HighlightSpan] = []
            var row = 0
            for span in CodeHighlighter.spans(texts.joined(separator: "\n"), language: language) {
                var location = span.range.location
                let end = NSMaxRange(span.range)
                while row + 1 < side.count, sideStarts[row + 1] <= location { row += 1 }
                var k = row
                while k < side.count, location < end {
                    let lineEnd = sideStarts[k] + texts[k].utf16.count
                    if location < lineEnd, keep.contains(lines[side[k]].kind) {
                        let start = lineStarts[side[k]] + location - sideStarts[k]
                        out.append(HighlightSpan(range: NSRange(location: start, length: min(end, lineEnd) - location), kind: span.kind))
                    }
                    k += 1
                    if k < side.count { location = sideStarts[k] }
                }
            }
            return out
        }
        let new = mapped(newSide, keep: [.context, .added])
        let old = mapped(oldSide, keep: [.removed])
        return (new + old).sorted { $0.range.location < $1.range.location }
    }

    // MARK: - Anchors

    private static func anchor(
        _ threads: [ReviewThread], mode: PreviewMode, lines: [PreviewLine], viewing: PreviewCommit
    ) -> (anchors: [ThreadAnchor], unanchored: [String]) {
        var newIndex: [Int: Int] = [:]
        var oldIndex: [Int: Int] = [:]
        if mode == .diff {
            for (i, line) in lines.enumerated() {
                if let n = line.newNumber, line.kind != .removed, newIndex[n] == nil { newIndex[n] = i }
                if let n = line.oldNumber, line.kind != .added, oldIndex[n] == nil { oldIndex[n] = i }
            }
        }
        func index(of line: Int, side: DiffSide) -> Int? {
            switch (mode, side) {
            case (.file, .right): lines.indices.contains(line - 1) ? line - 1 : nil
            case (.file, .left): nil
            case (.diff, .right): newIndex[line]
            case (.diff, .left): oldIndex[line]
            }
        }

        var anchors: [ThreadAnchor] = []
        var unanchored: [String] = []
        for thread in threads {
            let line: Int?
            let startLine: Int?
            switch viewing {
            case .head:
                guard !thread.isOutdated else {
                    unanchored.append(thread.id)
                    continue
                }
                (line, startLine) = (thread.line, thread.startLine)
            case .original(let oid):
                guard thread.originalCommitOID == oid else { continue }
                (line, startLine) = (thread.originalLine, thread.originalStartLine)
            }
            guard let line, let lineIndex = index(of: line, side: thread.diffSide) else {
                unanchored.append(thread.id)
                continue
            }
            let startIndex = startLine.flatMap { index(of: $0, side: thread.diffSide) }.map { min($0, lineIndex) }
            anchors.append(ThreadAnchor(threadID: thread.id, startLineIndex: startIndex ?? lineIndex, lineIndex: lineIndex))
        }
        let sorted = anchors.enumerated().sorted { a, b in
            a.element.lineIndex != b.element.lineIndex ? a.element.lineIndex < b.element.lineIndex : a.offset < b.offset
        }
        return (sorted.map(\.element), unanchored)
    }
}
