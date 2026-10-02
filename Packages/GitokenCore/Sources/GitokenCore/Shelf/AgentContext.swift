import Foundation

/// What an AI coding agent needs to act on a PR: the description, unresolved review threads anchored to code, and
/// failing checks. `markdown` is the clipboard/drag payload.
public struct AgentContext: Hashable, Sendable {
    public struct Comment: Hashable, Sendable {
        public let author: String
        public let body: String
        public init(author: String, body: String) {
            self.author = author
            self.body = body
        }
    }

    public struct ReviewThread: Hashable, Sendable {
        public let path: String
        public let line: Int?
        public let isResolved: Bool
        public let isOutdated: Bool
        public let diffHunk: String
        public let comments: [Comment]
        public init(path: String, line: Int?, isResolved: Bool, isOutdated: Bool, diffHunk: String, comments: [Comment]) {
            self.path = path
            self.line = line
            self.isResolved = isResolved
            self.isOutdated = isOutdated
            self.diffHunk = diffHunk
            self.comments = comments
        }
    }

    public struct FailingCheck: Hashable, Sendable {
        public let name: String
        public let detailsURL: URL?
        /// Check-run summary / commit-status description when the provider gives one.
        public let summary: String?
        /// Already trimmed (see `AgentContext.logTail`).
        public let logTail: String?
        public init(name: String, detailsURL: URL?, summary: String?, logTail: String?) {
            self.name = name
            self.detailsURL = detailsURL
            self.summary = summary
            self.logTail = logTail
        }
    }

    public let ref: PullRequestRef
    public let title: String
    public let headRefName: String
    public let baseRefName: String
    /// Markdown description as written on GitHub.
    public let body: String
    /// All review threads; resolved ones are left out of `markdown`.
    public let threads: [ReviewThread]
    public let failingChecks: [FailingCheck]

    public init(
        ref: PullRequestRef, title: String, headRefName: String, baseRefName: String, body: String,
        threads: [ReviewThread], failingChecks: [FailingCheck]
    ) {
        self.ref = ref
        self.title = title
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.body = body
        self.threads = threads
        self.failingChecks = failingChecks
    }

    static let maxDescriptionLength = 2000
    static let maxHunkLines = 24
    public static let maxLogLines = 40
    static let maxSummaryLength = 600

    public var markdown: String {
        var out: [String] = []
        out.append("# \(ref.repo.fullName)#\(ref.number): \(title)")
        out.append("")
        out.append("\(ref.htmlURL.absoluteString)")
        out.append("Branch `\(headRefName)` → `\(baseRefName)`")

        let description = Self.summarizedDescription(body)
        out.append("")
        out.append("## Description")
        out.append("")
        out.append(description.isEmpty ? "_No description._" : description)

        let open = threads.filter { !$0.isResolved }
        out.append("")
        out.append("## Unresolved review threads (\(open.count))")
        if open.isEmpty {
            out.append("")
            out.append("_None._")
        }
        for thread in open {
            out.append("")
            let location = thread.line.map { "\(thread.path):\($0)" } ?? thread.path
            out.append("### `\(location)`\(thread.isOutdated ? " (outdated)" : "")")
            out.append("")
            out.append(Self.fenced(Self.trimmedHunk(thread.diffHunk), language: "diff"))
            for comment in thread.comments {
                out.append("")
                out.append("**@\(comment.author)**:")
                out.append(Self.quoted(comment.body))
            }
        }

        out.append("")
        out.append("## Failing checks (\(failingChecks.count))")
        if failingChecks.isEmpty {
            out.append("")
            out.append("_None._")
        }
        for check in failingChecks {
            out.append("")
            out.append("### \(check.name)")
            if let url = check.detailsURL {
                out.append("")
                out.append(url.absoluteString)
            }
            if let summary = check.summary.map(Self.collapsedBlankLines), !summary.isEmpty {
                out.append("")
                out.append(Self.truncated(summary, to: Self.maxSummaryLength))
            }
            if let tail = check.logTail, !tail.isEmpty {
                out.append("")
                out.append("Log tail:")
                out.append("")
                out.append(Self.fenced(tail, language: ""))
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Last `lines` non-empty lines of a GitHub Actions job log before its "Post job cleanup." section, without the
    /// per-line ISO timestamps, ANSI color codes, and `##[group]` / `##[endgroup]` markers.
    public static func logTail(_ log: String, lines: Int = maxLogLines) -> String {
        let timestamp = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z ?/
        let ansi = /\u{1B}\[[0-9;]*[A-Za-z]/
        var cleaned = log.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { raw in
            String(raw).replacing(timestamp, with: "").replacing(ansi, with: "")
        }
        if let cleanup = cleaned.lastIndex(where: { $0.hasPrefix("Post job cleanup.") }) {
            cleaned.removeSubrange(cleanup...)
        }
        let kept = cleaned.compactMap { line -> String? in
            if line.hasPrefix("##[endgroup]") || line.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            return line.hasPrefix("##[group]") ? String(line.dropFirst("##[group]".count)) : line
        }
        return kept.suffix(lines).joined(separator: "\n")
    }

    // MARK: Formatting

    /// Description without HTML comments (PR templates), blank-line runs collapsed, cut at a line boundary.
    static func summarizedDescription(_ body: String) -> String {
        let withoutComments = body.replacing(/<!--[\s\S]*?-->/, with: "")
        let text = collapsedBlankLines(withoutComments)
        return truncated(text, to: maxDescriptionLength)
    }

    private static func collapsedBlankLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacing(/\n[ \t]*\n(?:[ \t]*\n)+/, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit)
        let cut = prefix.lastIndex(of: "\n").map { prefix[..<$0] } ?? prefix
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
    }

    /// Keeps the `@@` header and the lines nearest the commented line (GitHub hunks end at that line).
    private static func trimmedHunk(_ hunk: String) -> String {
        let lines = hunk.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > maxHunkLines + 1, let header = lines.first, header.hasPrefix("@@") else { return hunk }
        return ([header, " …"] + lines.suffix(maxHunkLines)).joined(separator: "\n")
    }

    /// A code fence longer than any backtick run inside `content`.
    private static func fenced(_ content: String, language: String) -> String {
        var longest = 0
        var run = 0
        for character in content {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(content)\n\(fence)"
    }

    private static func quoted(_ text: String) -> String {
        collapsedBlankLines(text)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }
}
