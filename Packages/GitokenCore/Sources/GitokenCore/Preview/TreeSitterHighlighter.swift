import Foundation
import SwiftTreeSitter
import Synchronization
import TreeSitterCSharp
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterSCSS
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// A bundled grammar, including the markdown inline grammar that only appears as an injection.
enum TreeSitterGrammar: Hashable, Sendable {
    case typescript, tsx, javascript, csharp, json, yaml, markdown, markdownInline, html, css, scss

    init(_ language: CodeLanguage) {
        switch language {
        case .typescript: self = .typescript
        case .tsx: self = .tsx
        case .javascript: self = .javascript
        case .csharp: self = .csharp
        case .json: self = .json
        case .yaml: self = .yaml
        case .markdown: self = .markdown
        case .html: self = .html
        case .css: self = .css
        case .scss: self = .scss
        }
    }

    /// `injection.language` values: "markdown_inline" or anything a markdown fence may name.
    init?(injectionName: String) {
        if injectionName == "markdown_inline" {
            self = .markdownInline
        } else if let language = CodeLanguage.detect(fence: injectionName) {
            self.init(language)
        } else {
            return nil
        }
    }

    private var language: Language {
        switch self {
        case .typescript: Language(tree_sitter_typescript())
        case .tsx: Language(tree_sitter_tsx())
        case .javascript: Language(tree_sitter_javascript())
        case .csharp: Language(tree_sitter_c_sharp())
        case .json: Language(tree_sitter_json())
        case .yaml: Language(tree_sitter_yaml())
        case .markdown: Language(tree_sitter_markdown())
        case .markdownInline: Language(tree_sitter_markdown_inline())
        case .html: Language(tree_sitter_html())
        case .css: Language(tree_sitter_css())
        case .scss: Language(tree_sitter_scss())
        }
    }

    /// Paths under `Queries/`, concatenated in this order; TS/TSX/SCSS inherit their base grammar's rules.
    private var highlightQueries: [String] {
        switch self {
        case .typescript: ["typescript/highlights.scm", "javascript/highlights.scm"]
        case .tsx: ["typescript/highlights.scm", "javascript/highlights-jsx.scm", "javascript/highlights.scm"]
        case .javascript: ["javascript/highlights.scm", "javascript/highlights-jsx.scm", "javascript/highlights-params.scm"]
        case .csharp: ["csharp/highlights.scm"]
        case .json: ["json/highlights.scm"]
        case .yaml: ["yaml/highlights.scm"]
        case .markdown: ["markdown/highlights.scm"]
        case .markdownInline: ["markdown-inline/highlights.scm"]
        case .html: ["html/highlights.scm"]
        case .css: ["css/highlights.scm"]
        case .scss: ["scss/highlights.scm", "css/highlights.scm"]
        }
    }

    private var injectionQueries: [String] {
        switch self {
        case .typescript, .tsx, .javascript: ["javascript/injections.scm"]
        case .markdown: ["markdown/injections.scm"]
        case .markdownInline: ["markdown-inline/injections.scm"]
        case .html: ["html/injections.scm"]
        case .csharp, .json, .yaml, .css, .scss: []
        }
    }

    struct Compiled: Sendable {
        let language: Language
        let highlights: Query
        let injections: Query?
    }

    /// Nil entries record a failed compile so it is not retried.
    private static let cache = Mutex<[TreeSitterGrammar: Compiled?]>([:])

    /// Queries compiled on first use, then shared (tree-sitter queries are immutable and thread-safe).
    var compiled: Compiled? {
        Self.cache.withLock { cache in
            if let hit = cache[self] { return hit }
            let built = try? compile()
            cache.updateValue(built, forKey: self)
            return built
        }
    }

    private func compile() throws -> Compiled {
        guard let root = Bundle.module.url(forResource: "Queries", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let language = self.language
        func query(_ files: [String]) throws -> Query? {
            guard !files.isEmpty else { return nil }
            var source = Data()
            for file in files {
                source.append(try Data(contentsOf: root.appending(path: file)))
                source.append(0x0A)
            }
            return try Query(language: language, data: source)
        }
        guard let highlights = try query(highlightQueries) else { throw CocoaError(.fileNoSuchFile) }
        return Compiled(language: language, highlights: highlights, injections: try query(injectionQueries))
    }
}

enum TreeSitterHighlighter {
    /// Nested injections deeper than this (markdown → html → script) are left to their host's colors.
    private static let maxInjectionDepth = 3

    /// Nil when the grammar's queries failed to load.
    static func spans(_ text: String, grammar: TreeSitterGrammar) -> [HighlightSpan]? {
        guard grammar.compiled != nil, let source = Source(text) else { return nil }
        var painter = Painter(length: source.length)
        var parsers: [TreeSitterGrammar: Parser] = [:]
        highlight(grammar, source: source, ranges: [], depth: 0, parsers: &parsers, into: &painter)
        return painter.spans()
    }

    /// Paints `ranges` (whole text when empty) with the grammar's captures, then its injections on top.
    /// One parser per grammar is reused across injections (markdown has one inline injection per paragraph).
    private static func highlight(
        _ grammar: TreeSitterGrammar, source: Source, ranges: [TSRange], depth: Int,
        parsers: inout [TreeSitterGrammar: Parser], into painter: inout Painter
    ) {
        guard let compiled = grammar.compiled else { return }
        let parser: Parser
        if let cached = parsers[grammar] {
            parser = cached
        } else {
            parser = Parser()
            guard (try? parser.setLanguage(compiled.language)) != nil else { return }
            parsers[grammar] = parser
        }
        // The host parse always runs first, so a reused parser never needs its ranges reset to the whole text.
        if !ranges.isEmpty { parser.includedRanges = ranges }
        guard let tree = parser.parse(tree: nil as Tree?, readBlock: source.read) else { return }
        let context = source.context

        var captures: [Painter.Capture] = []
        for match in compiled.highlights.execute(in: tree).resolve(with: context) {
            for capture in match.captures {
                guard let paint = paint(for: capture.nameComponents) else { continue }
                captures.append(Painter.Capture(range: capture.range, kind: paint.kind, pattern: match.patternIndex))
            }
        }
        painter.apply(captures)

        guard depth < maxInjectionDepth, let injections = compiled.injections else { return }
        for match in injections.execute(in: tree).resolve(with: context) {
            let content = match.captures(named: "injection.content").map(\.node.tsRange).filter { !$0.bytes.isEmpty }
            guard !content.isEmpty else { continue }
            let name = match.captures(named: "injection.language").first.map { source.text.substring(with: $0.range) }
                ?? match.metadata["injection.language"]
            guard let name, let injected = TreeSitterGrammar(injectionName: name) else { continue }
            highlight(injected, source: source, ranges: content, depth: depth + 1, parsers: &parsers, into: &painter)
        }
    }

    private struct Paint { let kind: HighlightKind? }

    /// Maps a capture name to a color; `Paint(kind: nil)` clears what an enclosing capture painted. Nil = ignored.
    private static func paint(for name: [String]) -> Paint? {
        guard let first = name.first else { return nil }
        let second = name.count > 1 ? name[1] : ""
        let kind: HighlightKind
        switch first {
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass": kind = .keyword
        case "string", "character":
            kind = second == "escape" ? .constant : name == ["string", "special", "key"] ? .property : .string
        case "escape": kind = .constant
        case "number", "float": kind = .number
        case "boolean", "constant": kind = .constant
        case "function", "method": kind = .function
        case "type", "constructor", "module", "namespace": kind = .type
        case "variable", "parameter": kind = .variable
        case "property", "field", "label": kind = .property
        case "tag": kind = .tag
        case "attribute": kind = .attribute
        case "comment": kind = .comment
        case "operator": kind = .operator
        case "punctuation": kind = .punctuation
        case "text", "markup":
            switch second {
            case "title", "heading": kind = .keyword
            case "literal", "raw": kind = .string
            case "uri", "link": kind = .function
            case "reference": kind = .property
            case "emphasis", "strong", "italic": kind = .type
            default: return nil
            }
        case "none", "embedded": return Paint(kind: nil)
        default: return nil
        }
        return Paint(kind: kind)
    }
}

/// The text once in the parser's encoding plus an NSString view for predicates and injection names.
private struct Source {
    let text: NSString
    let utf16: Data
    var length: Int { text.length }

    init?(_ string: String) {
        guard let utf16 = string.data(using: .utf16LittleEndian) else { return nil }
        self.text = string as NSString
        self.utf16 = utf16
    }

    /// Small, because every injection parse copies at least one chunk.
    private static let chunkBytes = 4 * 1024

    func read(byteOffset: Int, _: Point) -> Data? {
        guard byteOffset < utf16.count else { return nil }
        return utf16.subdata(in: byteOffset..<min(utf16.count, byteOffset + Self.chunkBytes))
    }

    var context: SwiftTreeSitter.Predicate.Context {
        let text = self.text
        return SwiftTreeSitter.Predicate.Context(textProvider: { range, _ in text.substring(with: range) })
    }
}

/// Resolves overlapping captures into sorted, non-overlapping spans: captures are painted outermost first, so nested
/// ranges keep the innermost kind and, on an exact overlap, the later pattern wins. Later layers (injections) paint last.
private struct Painter {
    struct Capture {
        let range: NSRange
        /// Nil clears.
        let kind: HighlightKind?
        let pattern: Int
    }

    private var kinds: [HighlightKind?]

    init(length: Int) {
        kinds = Array(repeating: nil, count: length)
    }

    mutating func apply(_ captures: [Capture]) {
        let ordered = captures.enumerated().sorted { a, b in
            let (l, r) = (a.element, b.element)
            if l.range.location != r.range.location { return l.range.location < r.range.location }
            if l.range.length != r.range.length { return l.range.length > r.range.length }
            if l.pattern != r.pattern { return l.pattern < r.pattern }
            return a.offset < b.offset
        }
        kinds.withUnsafeMutableBufferPointer { buffer in
            for (_, capture) in ordered {
                let lower = max(0, capture.range.location)
                let upper = min(buffer.count, NSMaxRange(capture.range))
                guard lower < upper else { continue }
                for i in lower..<upper { buffer[i] = capture.kind }
            }
        }
    }

    func spans() -> [HighlightSpan] {
        var out: [HighlightSpan] = []
        var start = 0
        while start < kinds.count {
            guard let kind = kinds[start] else {
                start += 1
                continue
            }
            var end = start + 1
            while end < kinds.count, kinds[end] == kind { end += 1 }
            out.append(HighlightSpan(range: NSRange(location: start, length: end - start), kind: kind))
            start = end
        }
        return out
    }
}
