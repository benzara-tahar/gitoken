import Foundation

/// Language-agnostic heuristic highlighter for files without a tree-sitter grammar. Tokens never span lines.
enum RegexHighlighter {
    private static let keywordList = """
        const let var function return import from export if else for while new type interface extends async await \
        default func package defer nil struct map range true false null undefined as of in typeof class enum \
        case switch guard self static public private fileprivate internal final protocol extension where throws \
        try catch def fn pub impl mut use mod match
        """
    private static let keywords: Set<String> = Set(keywordList.split(separator: " ").map { String($0) })

    private static let token = try! NSRegularExpression(
        pattern: #"(//.*$|(?<!\S)# .*$)|("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\\n]|\\.)*`)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_$][\w$]*)"#,
        options: [.anchorsMatchLines]
    )

    static func spans(_ text: String) -> [HighlightSpan] {
        let ns = text as NSString
        var out: [HighlightSpan] = []
        for m in token.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let kind: HighlightKind
            if m.range(at: 1).location != NSNotFound {
                kind = .comment
            } else if m.range(at: 2).location != NSNotFound {
                kind = .string
            } else if m.range(at: 3).location != NSNotFound {
                kind = .number
            } else {
                let word = ns.substring(with: m.range)
                let end = NSMaxRange(m.range)
                if keywords.contains(word) {
                    kind = .keyword
                } else if end < ns.length, ns.character(at: end) == 0x28 /* ( */ {
                    kind = .function
                } else if word.first?.isUppercase == true {
                    kind = .type
                } else {
                    continue
                }
            }
            out.append(HighlightSpan(range: m.range, kind: kind))
        }
        return out
    }
}
