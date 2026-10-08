import Foundation

/// ```suggestion blocks in review comments: extraction, applicability, and applying them to a file.
public enum Suggestions {
    /// Bodies of ```suggestion fenced blocks in markdown (CRLF-tolerant; trailing newline of the block dropped). A
    /// block whose last line is blank keeps it as a trailing "\n", so "" always means "delete the lines". Unclosed
    /// blocks run to the end, as in CommonMark; fences nested in other code blocks don't count.
    public static func blocks(in markdown: String) -> [String] {
        let rows = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var blocks: [String] = []
        var open: Fence?
        var body: [Substring] = []
        func close(_ fence: Fence) {
            guard fence.isSuggestion else { return }
            let text = body.joined(separator: "\n")
            blocks.append(body.last?.isEmpty == true ? text + "\n" : text)
        }
        for row in rows {
            if let fence = open {
                if fence.isClosed(by: row) {
                    close(fence)
                    open = nil
                } else if fence.isSuggestion {
                    body.append(fence.strippingIndent(row))
                }
            } else if let fence = Fence(opening: row) {
                open = fence
                body = []
            }
        }
        if let open { close(open) }
        return blocks
    }

    /// Item for an applicable comment: its thread is current (not outdated, resolved or pending), on the right side
    /// with a known `line`, and the comment holds exactly one suggestion block.
    public static func item(for comment: ReviewComment, in thread: ReviewThread) -> SuggestionItem? {
        guard !thread.isOutdated, !thread.isResolved, !thread.isPending, !comment.isPending, thread.diffSide == .right,
              let line = thread.line, thread.comments.contains(where: { $0.id == comment.id })
        else { return nil }
        let found = blocks(in: comment.body.markdown)
        let start = thread.startLine ?? line
        guard found.count == 1, start >= 1, start <= line else { return nil }
        return SuggestionItem(
            commentID: comment.id, threadID: thread.id, path: thread.path, startLine: start, endLine: line,
            replacement: found[0])
    }

    /// Applies items (same path, non-overlapping) to `text`, bottom-up, preserving line endings and the trailing
    /// newline; nil when a range is out of bounds or items overlap. A replacement's lines take the file's line ending
    /// ("\r\n" when it has any); its last line takes the ending of the last replaced line.
    public static func apply(_ items: [SuggestionItem], to text: String) -> String? {
        guard let path = items.first?.path else { return text }
        guard items.allSatisfy({ $0.path == path }) else { return nil }
        let sorted = items.sorted { $0.startLine < $1.startLine }
        for (previous, next) in zip(sorted, sorted.dropFirst()) where next.startLine <= previous.endLine { return nil }
        var lines = lines(of: text)
        guard sorted.allSatisfy({ 1 <= $0.startLine && $0.startLine <= $0.endLine && $0.endLine <= lines.count }) else {
            return nil
        }
        let ending = text.contains("\r\n") ? "\r\n" : "\n"
        for item in sorted.reversed() {
            let lastEnding = lines[item.endLine - 1].ending
            var replacement = replacementLines(item.replacement).map { Line(content: $0, ending: ending) }
            if !replacement.isEmpty {
                replacement[replacement.count - 1].ending = lastEnding
            } else if item.endLine == lines.count, item.startLine > 1, lastEnding.isEmpty {
                // Deleting the last lines of a file without a final newline: the new last line has none either.
                lines[item.startLine - 2].ending = ""
            }
            lines.replaceSubrange((item.startLine - 1)..<item.endLine, with: replacement)
        }
        return lines.map { $0.content + $0.ending }.joined()
    }

    private struct Line {
        var content: String
        /// "\n", "\r\n", or "" for a last line without a newline.
        var ending: String
    }

    private static func lines(of text: String) -> [Line] {
        var lines: [Line] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\n" || character == "\r\n" {
                lines.append(Line(content: String(text[start..<index]), ending: character == "\n" ? "\n" : "\r\n"))
                start = next
            }
            index = next
        }
        if start < text.endIndex { lines.append(Line(content: String(text[start...]), ending: "")) }
        return lines
    }

    /// "" → no lines; a trailing "\n" ends the last line rather than starting an empty one.
    private static func replacementLines(_ replacement: String) -> [String] {
        let normalized = replacement.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.isEmpty else { return [] }
        var rows = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if normalized.hasSuffix("\n") { rows.removeLast() }
        return rows
    }

    /// A CommonMark fenced code block opener: up to 3 spaces, then 3+ backticks or tildes, then the info string.
    private struct Fence {
        let marker: Character
        let length: Int
        let indent: Int
        let isSuggestion: Bool

        init?(opening row: Substring) {
            let indent = row.prefix { $0 == " " }.count
            guard indent <= 3, let marker = row.dropFirst(indent).first, marker == "`" || marker == "~" else { return nil }
            let rest = row.dropFirst(indent)
            let length = rest.prefix { $0 == marker }.count
            let info = rest.dropFirst(length)
            guard length >= 3, marker == "~" || !info.contains("`") else { return nil }
            self.marker = marker
            self.length = length
            self.indent = indent
            isSuggestion = info.split(whereSeparator: \.isWhitespace).first == "suggestion"
        }

        func isClosed(by row: Substring) -> Bool {
            let indent = row.prefix { $0 == " " }.count
            guard indent <= 3 else { return false }
            let rest = row.dropFirst(indent)
            let count = rest.prefix { $0 == marker }.count
            return count >= length && rest.dropFirst(count).allSatisfy(\.isWhitespace)
        }

        /// Content lines lose up to the opener's indentation.
        func strippingIndent(_ row: Substring) -> Substring {
            row.dropFirst(min(indent, row.prefix { $0 == " " }.count))
        }
    }
}
