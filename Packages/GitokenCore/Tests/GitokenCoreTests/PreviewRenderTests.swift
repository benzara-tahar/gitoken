import Foundation
import Testing
@testable import GitokenCore

@Suite struct PreviewRenderTests {
    // MARK: - Helpers

    private func kind(at offset: Int, in spans: [HighlightSpan]) -> HighlightKind? {
        spans.first { NSLocationInRange(offset, $0.range) }?.kind
    }

    private func kind(of token: String, in text: String, spans: [HighlightSpan]) -> HighlightKind? {
        let range = (text as NSString).range(of: token)
        precondition(range.location != NSNotFound, "\(token) not in sample")
        return kind(at: range.location, in: spans)
    }

    private func expectWellFormed(_ spans: [HighlightSpan], length: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        var end = 0
        for span in spans {
            #expect(span.range.length > 0, sourceLocation: sourceLocation)
            #expect(span.range.location >= end, "spans overlap or are unsorted at \(span.range)", sourceLocation: sourceLocation)
            end = NSMaxRange(span.range)
        }
        #expect(end <= length, sourceLocation: sourceLocation)
    }

    private func thread(
        _ id: String, path: String = "src/app.ts", side: DiffSide = .right, line: Int? = nil, startLine: Int? = nil,
        outdated: Bool = false, originalLine: Int? = nil, originalStartLine: Int? = nil, oid: String? = "head1"
    ) -> ReviewThread {
        ReviewThread(
            id: id, isResolved: false, isOutdated: outdated, path: path, diffSide: side, line: line, startLine: startLine,
            originalLine: originalLine ?? line, originalStartLine: originalStartLine ?? startLine, originalCommitOID: oid,
            comments: [], viewerCanResolve: true, viewerCanUnresolve: false, viewerCanReply: true
        )
    }

    // MARK: - UnifiedDiff

    @Test func unifiedDiffNumbersAcrossHunksAndDropsNoNewlineMarker() {
        let patch = """
            @@ -1,3 +1,4 @@
             a
            -b
            +B
            +c
             d
            @@ -10,2 +11,3 @@ func x() {
             j
            +k
             l
            \\ No newline at end of file

            """
        let lines = UnifiedDiff.parse(patch)
        #expect(lines.map(\.kind) == [.hunkHeader, .context, .removed, .added, .added, .context,
                                      .hunkHeader, .context, .added, .context])
        #expect(lines.map(\.text) == ["@@ -1,3 +1,4 @@", "a", "b", "B", "c", "d",
                                      "@@ -10,2 +11,3 @@ func x() {", "j", "k", "l"])
        #expect(lines.map(\.oldLine) == [nil, 1, 2, nil, nil, 3, nil, 10, nil, 11])
        #expect(lines.map(\.newLine) == [nil, 1, nil, 2, 3, 4, nil, 11, 12, 13])
    }

    @Test func unifiedDiffToleratesCRLF() {
        let lines = UnifiedDiff.parse("@@ -5,2 +5,2 @@\r\n-x\r\n+y\r\n z\r\n")
        #expect(lines.map(\.text) == ["@@ -5,2 +5,2 @@", "x", "y", "z"])
        #expect(lines.map(\.oldLine) == [nil, 5, nil, 6])
        #expect(lines.map(\.newLine) == [nil, nil, 5, 6])
    }

    @Test func unifiedDiffKeepsEmptyContextLines() {
        let lines = UnifiedDiff.parse("@@ -1,3 +1,3 @@\n a\n\n b")
        #expect(lines.map(\.kind) == [.hunkHeader, .context, .context, .context])
        #expect(lines.map(\.newLine) == [nil, 1, 2, 3])
    }

    // MARK: - Language detection

    @Test func detectsLanguageFromPath() {
        #expect(CodeLanguage.detect(path: "types/index.d.ts") == .typescript)
        #expect(CodeLanguage.detect(path: "src/App.tsx") == .tsx)
        #expect(CodeLanguage.detect(path: "scripts/build.mjs") == .javascript)
        #expect(CodeLanguage.detect(path: "tsconfig.json") == .json)
        #expect(CodeLanguage.detect(path: ".github/workflows/ci.yml") == .yaml)
        #expect(CodeLanguage.detect(path: "Api/Controllers/Users.CS") == .csharp)
        #expect(CodeLanguage.detect(path: "styles/site.scss") == .scss)
        #expect(CodeLanguage.detect(path: "cmd/main.go") == nil)
        #expect(CodeLanguage.detect(path: "Makefile") == nil)
        #expect(CodeLanguage.detect(path: ".gitignore") == nil)
    }

    @Test func detectsLanguageFromFence() {
        #expect(CodeLanguage.detect(fence: "ts") == .typescript)
        #expect(CodeLanguage.detect(fence: "TypeScript") == .typescript)
        #expect(CodeLanguage.detect(fence: "c#") == .csharp)
        #expect(CodeLanguage.detect(fence: "cs") == .csharp)
        #expect(CodeLanguage.detect(fence: "jsonc") == .json)
        #expect(CodeLanguage.detect(fence: "yml title=\"ci\"") == .yaml)
        #expect(CodeLanguage.detect(fence: "suggestion") == nil)
        #expect(CodeLanguage.detect(fence: "") == nil)
    }

    // MARK: - Highlighting

    @Test func treeSitterHighlightsTypeScript() {
        let text = "const greeting: string = \"hi\";\n// done\nexport function greet(name: string) { return greeting + name; }\n"
        let spans = CodeHighlighter.spans(text, language: .typescript)
        #expect(kind(of: "const", in: text, spans: spans) == .keyword)
        #expect(kind(of: "\"hi\"", in: text, spans: spans) == .string)
        #expect(kind(of: "// done", in: text, spans: spans) == .comment)
        #expect(kind(of: "greet(", in: text, spans: spans) == .function)
        expectWellFormed(spans, length: text.utf16.count)
    }

    @Test func treeSitterHighlightsCSharp() {
        let text = "public class Foo\n{\n    private int _count = 42;\n}\n"
        let spans = CodeHighlighter.spans(text, language: .csharp)
        #expect(kind(of: "public", in: text, spans: spans) == .keyword)
        #expect(kind(of: "class", in: text, spans: spans) == .keyword)
        #expect(kind(of: "42", in: text, spans: spans) == .number)
        expectWellFormed(spans, length: text.utf16.count)
    }

    @Test func markdownHighlightsInlineCodeAndFencedInjection() {
        let text = "# Title\n\nRun `npm ci` first.\n\n```ts\nconst x = 1;\n```\n"
        let spans = CodeHighlighter.spans(text, language: .markdown)
        #expect(kind(of: "npm ci", in: text, spans: spans) == .string)
        #expect(kind(of: "`npm", in: text, spans: spans) == .punctuation)
        #expect(kind(of: "Title", in: text, spans: spans) == .keyword)
        #expect(kind(of: "const", in: text, spans: spans) == .keyword, "fenced ts block is highlighted by its own grammar")
        expectWellFormed(spans, length: text.utf16.count)
    }

    @Test func htmlInjectsScriptAndStyle() {
        let text = "<style>a { color: red; }</style>\n<script>const n = 1;</script>\n"
        let spans = CodeHighlighter.spans(text, language: .html)
        #expect(kind(of: "style", in: text, spans: spans) == .tag)
        #expect(kind(of: "const", in: text, spans: spans) == .keyword)
        #expect(kind(of: "color", in: text, spans: spans) == .property)
        expectWellFormed(spans, length: text.utf16.count)
    }

    @Test func innermostCaptureWinsInsideNestedRanges() {
        // The template string paints the whole literal; its substitution clears it and the identifier inside wins.
        let text = "const s = `a ${value} b`;\n"
        let spans = CodeHighlighter.spans(text, language: .javascript)
        #expect(kind(of: "`a ", in: text, spans: spans) == .string)
        #expect(kind(of: "value", in: text, spans: spans) == .variable)
        expectWellFormed(spans, length: text.utf16.count)
    }

    @Test func everyLanguageProducesWellFormedSpans() throws {
        let samples: [CodeLanguage: String] = [
            .typescript: "interface A<T> { a: T }\nconst MAX = 3;\n",
            .tsx: "export const App = () => <div className=\"x\">{n * 2}</div>;\n",
            .javascript: "import x from 'y';\nconsole.log(/ab+c/g, `t ${x}`);\n",
            .csharp: "namespace N; record R(int A);\n",
            .json: "{\"a\": [1, true, null]}\n",
            .yaml: "on:\n  push:\n    branches: [main] # c\n",
            .markdown: "- **bold** and _em_ [link](https://x.y)\n",
            .html: "<a href=\"#\">x</a><!-- c -->\n",
            .css: ".a > #b:hover { margin: calc(1px + 2em); }\n",
            .scss: "$c: red;\n.a { &:hover { color: $c; } @include m; }\n",
        ]
        for language in CodeLanguage.allCases {
            let text = try #require(samples[language])
            let spans = CodeHighlighter.spans(text, language: language)
            #expect(!spans.isEmpty, "\(language) produced no highlights")
            expectWellFormed(spans, length: text.utf16.count)
        }
    }

    @Test func unsupportedLanguageUsesRegexFallback() {
        let text = "func main() {\n\tx := \"hi\" // note\n\treturn Foo(42)\n}"
        let spans = CodeHighlighter.spans(text, language: CodeLanguage.detect(path: "main.go"))
        #expect(kind(of: "func", in: text, spans: spans) == .keyword)
        #expect(kind(of: "main", in: text, spans: spans) == .function)
        #expect(kind(of: "\"hi\"", in: text, spans: spans) == .string)
        #expect(kind(of: "// note", in: text, spans: spans) == .comment)
        #expect(kind(of: "Foo", in: text, spans: spans) == .function)
        #expect(kind(of: "42", in: text, spans: spans) == .number)
        expectWellFormed(spans, length: text.utf16.count)
    }

    @Test func regexFallbackStringsDoNotSpanLines() {
        let text = "a = \"open\nb = \"closed\""
        let spans = CodeHighlighter.spans(text, language: nil)
        #expect(kind(of: "\"open", in: text, spans: spans) == nil)
        #expect(kind(of: "\"closed\"", in: text, spans: spans) == .string)
    }

    // MARK: - PreviewDocument

    private static let fileText = "line1\nline2\nline3\nline4\n"

    @Test func fileModeAtHeadAnchorsRightSideThreads() {
        let threads = [
            thread("multi", line: 3, startLine: 1),
            thread("single", line: 2),
            thread("left", side: .left, line: 2),
            thread("outdated", outdated: true, originalLine: 2),
            thread("beyond", line: 99),
            thread("elsewhere", path: "src/other.ts", line: 1),
        ]
        let doc = PreviewDocument.build(
            mode: .file, path: "src/app.ts", fileText: Self.fileText, patch: nil, threads: threads, viewing: .head("head1")
        )
        #expect(doc.lines.count == 4, "the trailing newline does not add a line")
        #expect(doc.lines.map(\.newNumber) == [1, 2, 3, 4])
        #expect(doc.text == "line1\nline2\nline3\nline4")
        #expect(doc.lineStarts == [0, 6, 12, 18])
        #expect(doc.anchors == [
            ThreadAnchor(threadID: "single", startLineIndex: 1, lineIndex: 1),
            ThreadAnchor(threadID: "multi", startLineIndex: 0, lineIndex: 2),
        ])
        #expect(doc.unanchored == ["left", "outdated", "beyond"])
    }

    @Test func fileModeNormalizesCRLF() {
        let doc = PreviewDocument.build(
            mode: .file, path: "a.txt", fileText: "a\r\nb\r\n", patch: nil, threads: [], viewing: .head("h")
        )
        #expect(doc.lines.map(\.text) == ["a", "b"])
    }

    @Test func fileModeWithoutTextIsEmpty() {
        let doc = PreviewDocument.build(
            mode: .file, path: "src/app.ts", fileText: nil, patch: "@@ -1 +1 @@\n+x", threads: [thread("t", line: 1)],
            viewing: .head("head1")
        )
        #expect(doc.lines.isEmpty && doc.text.isEmpty && doc.lineStarts.isEmpty && doc.spans.isEmpty)
        #expect(doc.anchors.isEmpty)
        #expect(doc.unanchored == ["t"])
    }

    @Test func originalCommitAnchorsOnlyThatCommitsThreads() {
        let threads = [
            thread("old", line: nil, outdated: true, originalLine: 4, originalStartLine: 3, oid: "abc"),
            thread("current", line: 2, oid: "def"),
            thread("oldLeft", side: .left, line: nil, outdated: true, originalLine: 1, oid: "abc"),
            thread("oldGone", line: nil, outdated: true, originalLine: 40, oid: "abc"),
        ]
        let doc = PreviewDocument.build(
            mode: .file, path: "src/app.ts", fileText: Self.fileText, patch: nil, threads: threads, viewing: .original("abc")
        )
        #expect(doc.anchors == [ThreadAnchor(threadID: "old", startLineIndex: 2, lineIndex: 3)])
        #expect(doc.unanchored == ["oldLeft", "oldGone"], "threads from other commits are omitted entirely")
    }

    private static let patch = """
        @@ -1,3 +1,3 @@
        -let old = 1;
        +const fresh = "a";
         export {};
        @@ -10,1 +10,2 @@
         x;
        +y;
        """

    @Test func diffModeMapsSidesToDiffLines() {
        let threads = [
            thread("newAdded", line: 1),
            thread("oldRemoved", side: .left, line: 1),
            thread("newContext", line: 2),
            thread("oldContext", side: .left, line: 2),
            thread("range", line: 11, startLine: 10),
            thread("notInDiff", line: 5),
        ]
        let doc = PreviewDocument.build(
            mode: .diff, path: "src/app.ts", fileText: nil, patch: Self.patch, threads: threads, viewing: .head("head1")
        )
        #expect(doc.lines.map(\.kind) == [.hunkHeader, .removed, .added, .context, .hunkHeader, .context, .added])
        #expect(doc.anchors == [
            ThreadAnchor(threadID: "oldRemoved", startLineIndex: 1, lineIndex: 1),
            ThreadAnchor(threadID: "newAdded", startLineIndex: 2, lineIndex: 2),
            ThreadAnchor(threadID: "newContext", startLineIndex: 3, lineIndex: 3),
            ThreadAnchor(threadID: "oldContext", startLineIndex: 3, lineIndex: 3),
            ThreadAnchor(threadID: "range", startLineIndex: 5, lineIndex: 6),
        ])
        #expect(doc.unanchored == ["notInDiff"])
    }

    @Test func diffModeWithoutPatchIsEmpty() {
        let doc = PreviewDocument.build(
            mode: .diff, path: "src/app.ts", fileText: Self.fileText, patch: nil, threads: [thread("t", line: 1)],
            viewing: .head("head1")
        )
        #expect(doc.lines.isEmpty)
        #expect(doc.unanchored == ["t"])
    }

    @Test func diffModeSpansLandOnTheirLines() {
        let doc = PreviewDocument.build(
            mode: .diff, path: "src/app.ts", fileText: nil, patch: Self.patch, threads: [], viewing: .head("head1")
        )
        let ns = doc.text as NSString
        func lineKind(_ line: Int, _ token: String) -> HighlightKind? {
            let lineRange = NSRange(location: doc.lineStarts[line], length: doc.lines[line].text.utf16.count)
            let range = ns.range(of: token, range: lineRange)
            return kind(at: range.location, in: doc.spans)
        }
        #expect(lineKind(1, "let") == .keyword, "removed lines use the old side")
        #expect(lineKind(2, "const") == .keyword)
        #expect(lineKind(2, "\"a\"") == .string)
        #expect(lineKind(3, "export") == .keyword)
        for header in [0, 4] {
            let range = NSRange(location: doc.lineStarts[header], length: doc.lines[header].text.utf16.count)
            #expect(!doc.spans.contains { NSIntersectionRange($0.range, range).length > 0 }, "hunk headers stay plain")
        }
        for span in doc.spans {
            let line = doc.lineIndex(forOffset: span.range.location)
            #expect(NSMaxRange(span.range) <= doc.lineStarts[line] + doc.lines[line].text.utf16.count, "spans never cross lines")
        }
        expectWellFormed(doc.spans, length: ns.length)
        #expect(!doc.highlightSkipped)
    }

    @Test func highlightingIsSkippedOverTheCap() {
        let big = String(repeating: "const a = 1;\n", count: PreviewSizePolicy.highlightBytes / 13 + 10)
        let doc = PreviewDocument.build(mode: .file, path: "a.ts", fileText: big, patch: nil, threads: [], viewing: .head("h"))
        #expect(doc.highlightSkipped)
        #expect(doc.spans.isEmpty)
    }

    @Test func lineIndexForOffset() {
        let doc = PreviewDocument.build(
            mode: .file, path: "a.txt", fileText: Self.fileText, patch: nil, threads: [], viewing: .head("h")
        )
        #expect(doc.lineIndex(forOffset: 0) == 0)
        #expect(doc.lineIndex(forOffset: 5) == 0, "the newline belongs to its line")
        #expect(doc.lineIndex(forOffset: 6) == 1)
        #expect(doc.lineIndex(forOffset: 20) == 3)
        #expect(doc.lineIndex(forOffset: 1_000) == 3)
    }

    // MARK: - Size policy

    @Test func sizePolicy() {
        #expect(PreviewSizePolicy.isGenerated(path: "web/package-lock.json"))
        #expect(PreviewSizePolicy.isGenerated(path: "yarn.lock"))
        #expect(PreviewSizePolicy.isGenerated(path: "go.sum"))
        #expect(PreviewSizePolicy.isGenerated(path: "dist/app.min.js"))
        #expect(PreviewSizePolicy.isGenerated(path: "dist/app.js.map"))
        #expect(PreviewSizePolicy.isGenerated(path: "Forms/Main.Designer.cs"))
        #expect(PreviewSizePolicy.isGenerated(path: "obj/Api.g.cs"))
        #expect(!PreviewSizePolicy.isGenerated(path: "src/package.json"))
        #expect(!PreviewSizePolicy.isGenerated(path: "src/minimal.js"))

        #expect(PreviewSizePolicy.shouldCollapse(path: "pnpm-lock.yaml", byteCount: 10))
        #expect(PreviewSizePolicy.shouldCollapse(path: "src/a.ts", byteCount: PreviewSizePolicy.collapseBytes + 1))
        #expect(!PreviewSizePolicy.shouldCollapse(path: "src/a.ts", byteCount: PreviewSizePolicy.collapseBytes))

        #expect(PreviewSizePolicy.isBinary(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
        #expect(!PreviewSizePolicy.isBinary(Data("plain text".utf8)))
        #expect(!PreviewSizePolicy.isBinary(Data(repeating: 0x41, count: 8000) + Data([0])), "only the first 8000 bytes count")
    }
}
