import Foundation

/// Languages with a bundled tree-sitter grammar. Everything else uses the regex fallback.
public enum CodeLanguage: String, CaseIterable, Sendable {
    case typescript, tsx, javascript, csharp, json, yaml, markdown, html, css, scss

    private static let byExtension: [String: CodeLanguage] = [
        "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "tsx": .tsx,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "cs": .csharp, "csx": .csharp,
        "json": .json, "jsonc": .json,
        "yml": .yaml, "yaml": .yaml,
        "md": .markdown, "markdown": .markdown,
        "html": .html, "htm": .html,
        "css": .css,
        "scss": .scss,
    ]

    private static let byFence: [String: CodeLanguage] = byExtension.merging([
        "typescript": .typescript,
        "javascript": .javascript, "node": .javascript,
        "csharp": .csharp, "c#": .csharp, "c-sharp": .csharp,
    ]) { current, _ in current }

    /// By file extension (case-insensitive); `foo.d.ts` is TypeScript, `tsconfig.json` JSON.
    public static func detect(path: String) -> CodeLanguage? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return byExtension[name[name.index(after: dot)...].lowercased()]
    }

    /// Markdown fence info strings ("ts", "typescript", "cs", "c#", "jsonc", "yml", …). Only the first word counts.
    public static func detect(fence: String) -> CodeLanguage? {
        let word = fence.split(whereSeparator: { $0.isWhitespace || $0 == "{" || $0 == "," }).first
        return word.flatMap { byFence[$0.lowercased()] }
    }
}
