import Foundation

public enum HighlightKind: String, Sendable {
    case keyword, string, number, constant, function, type, variable, property, tag, attribute, comment, `operator`, punctuation
}

public struct HighlightSpan: Hashable, Sendable {
    /// UTF-16 offsets into the highlighted text.
    public let range: NSRange
    public let kind: HighlightKind

    public init(range: NSRange, kind: HighlightKind) {
        self.range = range
        self.kind = kind
    }
}

public enum CodeHighlighter {
    /// Tree-sitter for supported languages, else the regex fallback.
    /// Thread-safe, synchronous; call off the main actor for large inputs. Spans are sorted and non-overlapping.
    public static func spans(_ text: String, language: CodeLanguage?) -> [HighlightSpan] {
        guard !text.isEmpty else { return [] }
        if let language, let spans = TreeSitterHighlighter.spans(text, grammar: TreeSitterGrammar(language)) {
            return spans
        }
        return RegexHighlighter.spans(text)
    }
}
