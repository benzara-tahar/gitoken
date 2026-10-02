import Foundation

/// Display model for a comment body: GitHub-rendered HTML reduced to the blocks and inlines the app draws.
public struct RichDocument: Hashable, Sendable {
    public var blocks: [RichBlock]

    public init(blocks: [RichBlock]) {
        self.blocks = blocks
    }
}

public indirect enum RichBlock: Hashable, Sendable {
    case paragraph([RichInline])
    case heading(level: Int, [RichInline])
    case list(RichList)
    case blockquote([RichBlock])
    case code(RichCode)
    case table(RichTable)
    case image(RichImage)
    case details(RichDetails)
    case rule
}

public struct RichList: Hashable, Sendable {
    public var ordered: Bool
    public var start: Int
    public var items: [RichListItem]

    public init(ordered: Bool, start: Int = 1, items: [RichListItem]) {
        self.ordered = ordered
        self.start = start
        self.items = items
    }
}

public struct RichListItem: Hashable, Sendable {
    /// Task-list checkbox state; nil for an ordinary item.
    public var checked: Bool?
    public var blocks: [RichBlock]

    public init(checked: Bool? = nil, blocks: [RichBlock]) {
        self.checked = checked
        self.blocks = blocks
    }
}

public struct RichDetails: Hashable, Sendable {
    public var summary: [RichInline]
    public var blocks: [RichBlock]
    public var isOpen: Bool

    public init(summary: [RichInline], blocks: [RichBlock], isOpen: Bool) {
        self.summary = summary
        self.blocks = blocks
        self.isOpen = isOpen
    }
}

// MARK: Code

public enum RichTokenKind: String, Hashable, Sendable {
    case keyword, string, constant, function, type, variable, tag, comment, inserted, deleted
}

public struct RichCodeToken: Hashable, Sendable {
    public var text: String
    public var kind: RichTokenKind?

    public init(_ text: String, _ kind: RichTokenKind? = nil) {
        self.text = text
        self.kind = kind
    }
}

public struct RichCodeLine: Hashable, Sendable {
    public enum Change: Hashable, Sendable { case added, removed }

    public var change: Change?
    public var tokens: [RichCodeToken]

    public init(change: Change? = nil, tokens: [RichCodeToken]) {
        self.change = change
        self.tokens = tokens
    }

    public var text: String { tokens.map(\.text).joined() }
}

public struct RichCode: Hashable, Sendable {
    public var language: String?
    /// A ```suggestion block: lines carry `.added` / `.removed`.
    public var isSuggestion: Bool
    public var lines: [RichCodeLine]

    public init(language: String?, isSuggestion: Bool = false, lines: [RichCodeLine]) {
        self.language = language
        self.isSuggestion = isSuggestion
        self.lines = lines
    }

    /// GitHub supplied syntax classes; otherwise the app may highlight heuristically.
    public var isHighlighted: Bool { lines.contains { $0.tokens.contains { $0.kind != nil } } }

    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

// MARK: Table

public enum RichAlignment: Hashable, Sendable {
    case leading, center, trailing
}

public struct RichTable: Hashable, Sendable {
    public var alignments: [RichAlignment]
    public var header: [[RichInline]]
    public var rows: [[[RichInline]]]

    public init(alignments: [RichAlignment], header: [[RichInline]], rows: [[[RichInline]]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }

    public var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }
}

// MARK: Images

public struct RichImage: Hashable, Sendable {
    /// `<img src>`: the universal fallback.
    public var url: URL
    /// `<picture><source media="(prefers-color-scheme: dark)">`.
    public var darkURL: URL?
    /// `<picture><source media="(prefers-color-scheme: light)">`.
    public var lightURL: URL?
    public var alt: String
    public var width: Double?
    public var height: Double?
    /// Enclosing `<a href>`.
    public var link: URL?

    public init(
        url: URL, darkURL: URL? = nil, lightURL: URL? = nil, alt: String = "", width: Double? = nil,
        height: Double? = nil, link: URL? = nil
    ) {
        self.url = url
        self.darkURL = darkURL
        self.lightURL = lightURL
        self.alt = alt
        self.width = width
        self.height = height
        self.link = link
    }

    /// URLs to try in order for the surface appearance; the `<img src>` is always last.
    public func candidates(dark: Bool) -> [URL] {
        var urls: [URL] = []
        if let preferred = dark ? darkURL : lightURL { urls.append(preferred) }
        if !urls.contains(url) { urls.append(url) }
        return urls
    }
}

// MARK: Inlines

public struct RichStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = RichStyle(rawValue: 1 << 0)
    public static let italic = RichStyle(rawValue: 1 << 1)
    public static let strikethrough = RichStyle(rawValue: 1 << 2)
    public static let code = RichStyle(rawValue: 1 << 3)
}

public enum RichInline: Hashable, Sendable {
    case text(String, RichStyle)
    case link(String, url: URL, RichStyle)
    /// `@login` or `@org/team`.
    case mention(login: String, url: URL?)
    /// `#123`, `org/repo#123`, or a commit SHA link.
    case reference(String, url: URL?)
    case emoji(String)
    case lineBreak
    case image(RichImage)
}

// MARK: Plain text

extension RichDocument {
    /// Readable text without markup: blocks on their own lines, images as their alt text.
    public var plainText: String {
        blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension RichBlock {
    var plainText: String {
        switch self {
        case .paragraph(let inlines), .heading(_, let inlines):
            return inlines.plainText
        case .list(let list):
            return list.items.map { $0.blocks.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
        case .blockquote(let blocks):
            return blocks.map(\.plainText).joined(separator: "\n")
        case .code(let code):
            return code.text
        case .table(let table):
            return ([table.header] + table.rows).map { $0.map(\.plainText).joined(separator: " ") }.joined(separator: "\n")
        case .image(let image):
            return image.alt
        case .details(let details):
            return ([details.summary.plainText] + details.blocks.map(\.plainText)).joined(separator: "\n")
        case .rule:
            return ""
        }
    }
}

extension [RichInline] {
    var plainText: String {
        map { inline -> String in
            switch inline {
            case .text(let text, _), .link(let text, _, _), .reference(let text, _), .emoji(let text): text
            case .mention(let login, _): "@" + login
            case .lineBreak: "\n"
            case .image(let image): image.alt
            }
        }
        .joined()
    }
}
