import Foundation
import SwiftSoup

/// Reduces GitHub's rendered `bodyHTML` to a `RichDocument`. Comments, scripts, styles and SVG are dropped;
/// unknown tags contribute their text. Relative URLs resolve against https://github.com.
enum RichHTMLParser {
    static let baseURL = URL(string: "https://github.com/")!

    static func parse(_ html: String) -> RichDocument {
        guard let document = try? SwiftSoup.parseBodyFragment(html, baseURL.absoluteString), let body = document.body()
        else { return RichDocument(blocks: []) }
        var builder = BlockBuilder()
        builder.appendChildren(of: body)
        return RichDocument(blocks: builder.finish())
    }

    // MARK: Element helpers

    private static let droppedTags: Set<String> = [
        "script", "style", "svg", "template", "head", "meta", "link", "title", "noscript", "iframe", "object", "embed",
        "button", "clipboard-copy", "input", "textarea", "select", "form", "audio", "video", "source", "track", "math",
    ]

    fileprivate static func isDropped(_ element: Element) -> Bool {
        let tag = element.tagNameNormal()
        if droppedTags.contains(tag) { return true }
        if tag == "div", element.hasClass("zeroclipboard-container") { return true }
        if tag == "a", element.hasClass("anchor") { return true }
        return false
    }

    fileprivate static func attribute(_ element: Element, _ name: String) -> String? {
        guard element.hasAttr(name), let value = try? element.attr(name) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func classes(_ element: Element) -> [String] {
        ((try? element.className()) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Absolute http(s)/mailto URL, or nil for in-page anchors and other schemes.
    static func resolve(_ raw: String?) -> URL? {
        guard let raw, !raw.hasPrefix("#") else { return nil }
        guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL else { return nil }
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    fileprivate static func dimension(_ raw: String?) -> Double? {
        guard var raw, !raw.hasSuffix("%") else { return nil }
        if raw.hasSuffix("px") { raw.removeLast(2) }
        guard let value = Double(raw), value > 0 else { return nil }
        return value
    }

    // MARK: Images

    fileprivate static func image(_ img: Element, link: URL? = nil) -> RichImage? {
        guard let url = resolve(attribute(img, "src") ?? attribute(img, "data-canonical-src")) else { return nil }
        var width = dimension(attribute(img, "width"))
        var height = dimension(attribute(img, "height"))
        if img.hasClass("emoji"), width == nil, height == nil {
            width = 20
            height = 20
        }
        return RichImage(
            url: url, alt: attribute(img, "alt") ?? attribute(img, "title") ?? "", width: width, height: height, link: link
        )
    }

    fileprivate static func picture(_ picture: Element, link: URL? = nil) -> RichImage? {
        var dark: URL?
        var light: URL?
        var fallback: URL?
        var img: RichImage?
        for child in picture.children().array() {
            switch child.tagNameNormal() {
            case "source":
                let url = resolve(attribute(child, "srcset")?.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init))
                let media = attribute(child, "media")?.lowercased().replacingOccurrences(of: " ", with: "") ?? ""
                if media.contains("prefers-color-scheme:dark") {
                    dark = dark ?? url
                } else if media.contains("prefers-color-scheme:light") {
                    light = light ?? url
                } else {
                    fallback = fallback ?? url
                }
            case "img":
                img = image(child, link: link)
            default:
                continue
            }
        }
        if var img {
            img.darkURL = dark
            img.lightURL = light
            return img
        }
        guard let url = fallback ?? light ?? dark else { return nil }
        return RichImage(url: url, darkURL: dark, lightURL: light, link: link)
    }

    // MARK: Code

    private static let tokenClasses: [String: RichTokenKind] = [
        "pl-k": .keyword, "pl-mh": .keyword,
        "pl-s": .string, "pl-pds": .string, "pl-sr": .string, "pl-cce": .string, "pl-sra": .string, "pl-sre": .string,
        "pl-c1": .constant, "pl-mi2": .constant,
        "pl-en": .function, "pl-e": .function,
        "pl-smi": .type, "pl-ent": .tag, "pl-ba": .tag,
        "pl-v": .variable, "pl-smw": .variable, "pl-mc": .variable,
        "pl-c": .comment,
        "pl-mi1": .inserted, "pl-mdr": .keyword,
        "pl-md": .deleted, "pl-ii": .deleted, "pl-bu": .deleted,
    ]

    private static func tokenKind(_ element: Element) -> RichTokenKind? {
        for name in classes(element) {
            if let kind = tokenClasses[name] { return kind }
        }
        return nil
    }

    private static func append(_ value: String, kind: RichTokenKind?, to out: inout [RichCodeToken]) {
        guard !value.isEmpty else { return }
        if let last = out.last, last.kind == kind {
            out[out.count - 1].text += value
        } else {
            out.append(RichCodeToken(value, kind))
        }
    }

    private static func tokens(in node: Node, kind: RichTokenKind?, into out: inout [RichCodeToken]) {
        if let text = node as? TextNode {
            append(text.getWholeText(), kind: kind, to: &out)
            return
        }
        guard let element = node as? Element, !isDropped(element) else { return }
        if element.tagNameNormal() == "br" {
            append("\n", kind: kind, to: &out)
            return
        }
        let own = tokenKind(element) ?? kind
        for child in element.getChildNodes() { tokens(in: child, kind: own, into: &out) }
    }

    /// Splits a token stream into lines, dropping the trailing newline GitHub leaves before `</pre>`.
    private static func lines(_ stream: [RichCodeToken], change: RichCodeLine.Change? = nil) -> [RichCodeLine] {
        var lines: [RichCodeLine] = [RichCodeLine(change: change, tokens: [])]
        for token in stream {
            let parts = token.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                if index > 0 { lines.append(RichCodeLine(change: change, tokens: [])) }
                if !part.isEmpty { lines[lines.count - 1].tokens.append(RichCodeToken(String(part), token.kind)) }
            }
        }
        if lines.count > 1, lines.last?.tokens.isEmpty == true { lines.removeLast() }
        return lines
    }

    fileprivate static func code(_ pre: Element) -> RichCode {
        var language = attribute(pre, "lang")
        if language == nil, let parent = pre.parent() {
            language = classes(parent).lazy.compactMap { name -> String? in
                for prefix in ["highlight-source-", "highlight-text-"] where name.hasPrefix(prefix) {
                    return String(name.dropFirst(prefix.count))
                }
                return nil
            }.first
        }
        if language == nil, let code = pre.children().array().first(where: { $0.tagNameNormal() == "code" }) {
            language = classes(code).first { $0.hasPrefix("language-") }.map { String($0.dropFirst("language-".count)) }
        }
        var stream: [RichCodeToken] = []
        for child in pre.getChildNodes() { tokens(in: child, kind: nil, into: &stream) }
        if language?.lowercased() == "suggestion" {
            return RichCode(language: nil, isSuggestion: true, lines: lines(stream, change: .added))
        }
        return RichCode(language: language, lines: lines(stream))
    }

    /// GitHub's rendered ```suggestion: a diff table of deletion/addition rows.
    fileprivate static func suggestion(_ container: Element) -> RichCode {
        var result: [RichCodeLine] = []
        let cells = (try? container.select("td.blob-code-inner, td.blob-code").array()) ?? []
        for cell in cells {
            let names = classes(cell)
            let change: RichCodeLine.Change? = names.contains { $0.hasPrefix("blob-code-deletion") }
                ? .removed : names.contains { $0.hasPrefix("blob-code-addition") } ? .added : nil
            var stream: [RichCodeToken] = []
            for child in cell.getChildNodes() { tokens(in: child, kind: nil, into: &stream) }
            let merged = lines(stream, change: change)
            result.append(contentsOf: merged)
        }
        return RichCode(language: nil, isSuggestion: true, lines: result)
    }

    // MARK: Tables

    fileprivate static func table(_ table: Element) -> RichTable {
        let rows = ((try? table.select("tr").array()) ?? []).filter { row in
            // Ignore rows of tables nested inside cells.
            var parent = row.parent()
            while let current = parent, current !== table {
                if current.tagNameNormal() == "table" { return false }
                parent = current.parent()
            }
            return true
        }
        func cells(_ row: Element) -> [Element] {
            row.children().array().filter { ["td", "th"].contains($0.tagNameNormal()) }
        }
        func alignment(_ cell: Element) -> RichAlignment {
            let raw = (attribute(cell, "align") ?? attribute(cell, "style") ?? "").lowercased()
            if raw.contains("center") { return .center }
            if raw.contains("right") { return .trailing }
            return .leading
        }
        func content(_ cell: Element) -> [RichInline] {
            var out: [RichInline] = []
            for child in cell.getChildNodes() { InlineBuilder.append(child, style: [], into: &out) }
            return InlineBuilder.normalized(out)
        }

        var header: [[RichInline]] = []
        var body = rows
        var alignments: [RichAlignment] = []
        if let first = rows.first {
            let firstCells = cells(first)
            let inHead = first.parent()?.tagNameNormal() == "thead"
            if inHead || (!firstCells.isEmpty && firstCells.allSatisfy { $0.tagNameNormal() == "th" }) {
                header = firstCells.map(content)
                alignments = firstCells.map(alignment)
                body.removeFirst()
            }
        }
        let bodyRows = body.map { cells($0).map(content) }
        if alignments.isEmpty, let first = body.first { alignments = cells(first).map(alignment) }
        let columns = max(header.count, bodyRows.map(\.count).max() ?? 0)
        alignments += Array(repeating: .leading, count: max(0, columns - alignments.count))
        return RichTable(alignments: alignments, header: header, rows: bodyRows)
    }
}

// MARK: - Blocks

private struct BlockBuilder {
    private var blocks: [RichBlock] = []
    private var pending: [RichInline] = []

    mutating func appendChildren(of element: Element) {
        for child in element.getChildNodes() { append(child) }
    }

    mutating func finish() -> [RichBlock] {
        flush()
        return blocks
    }

    private mutating func flush() {
        let inlines = InlineBuilder.normalized(pending)
        pending = []
        guard !inlines.isEmpty else { return }
        let visible = inlines.filter { if case .lineBreak = $0 { return false } else { return true } }
        if visible.count == 1, case .image(let image) = visible[0] {
            blocks.append(.image(image))
        } else {
            blocks.append(.paragraph(inlines))
        }
    }

    private mutating func block(_ block: RichBlock) {
        flush()
        blocks.append(block)
    }

    private static func children(of element: Element) -> [RichBlock] {
        var builder = BlockBuilder()
        builder.appendChildren(of: element)
        return builder.finish()
    }

    mutating func append(_ node: Node) {
        guard let element = node as? Element else {
            InlineBuilder.append(node, style: [], into: &pending)
            return
        }
        if RichHTMLParser.isDropped(element) { return }
        let tag = element.tagNameNormal()
        switch tag {
        case "p":
            flush()
            for child in element.getChildNodes() { InlineBuilder.append(child, style: [], into: &pending) }
            flush()
        case "h1", "h2", "h3", "h4", "h5", "h6":
            var inlines: [RichInline] = []
            for child in element.getChildNodes() { InlineBuilder.append(child, style: [], into: &inlines) }
            let normalized = InlineBuilder.normalized(inlines)
            if !normalized.isEmpty { block(.heading(level: Int(String(tag.dropFirst())) ?? 6, normalized)) }
            else { flush() }
        case "ul", "ol":
            let start = RichHTMLParser.attribute(element, "start").flatMap(Int.init) ?? 1
            let items = element.children().array().filter { $0.tagNameNormal() == "li" }.map(Self.listItem)
            if !items.isEmpty { block(.list(RichList(ordered: tag == "ol", start: start, items: items))) }
        case "blockquote":
            let inner = Self.children(of: element)
            if !inner.isEmpty { block(.blockquote(inner)) }
        case "pre":
            block(.code(RichHTMLParser.code(element)))
        case "table":
            block(.table(RichHTMLParser.table(element)))
        case "hr":
            block(.rule)
        case "details":
            block(.details(Self.details(element)))
        case "div" where element.hasClass("js-suggested-changes-blob"):
            block(.code(RichHTMLParser.suggestion(element)))
        case "div" where element.hasClass("markdown-alert"):
            let inner = Self.children(of: element)
            if !inner.isEmpty { block(.blockquote(inner)) }
        case "div", "section", "article", "main", "header", "footer", "figure", "figcaption", "center", "dl", "dt",
            "dd", "li", "summary", "nav", "aside", "address":
            flush()
            appendChildren(of: element)
            flush()
        default:
            // Custom wrappers such as `<markdown-accessiblity-table>` hold blocks; everything else is inline.
            if (try? element.select(Self.blockSelector))?.isEmpty() == false {
                flush()
                appendChildren(of: element)
                flush()
            } else {
                InlineBuilder.append(element, style: [], into: &pending)
            }
        }
    }

    private static let blockSelector = "p, div, table, ul, ol, pre, blockquote, h1, h2, h3, h4, h5, h6, details, hr"

    private static func listItem(_ li: Element) -> RichListItem {
        var checked: Bool?
        let leading = li.children().array().first.flatMap { first -> Element? in
            if first.tagNameNormal() == "input" { return first }
            if first.tagNameNormal() == "p" { return first.children().array().first { $0.tagNameNormal() == "input" } }
            return nil
        }
        if let input = leading, RichHTMLParser.attribute(input, "type")?.lowercased() == "checkbox" {
            checked = input.hasAttr("checked")
        }
        return RichListItem(checked: checked, blocks: children(of: li))
    }

    private static func details(_ element: Element) -> RichDetails {
        var summary: [RichInline] = []
        var builder = BlockBuilder()
        var sawSummary = false
        for child in element.getChildNodes() {
            if !sawSummary, let summaryElement = child as? Element, summaryElement.tagNameNormal() == "summary" {
                sawSummary = true
                for node in summaryElement.getChildNodes() { InlineBuilder.append(node, style: [], into: &summary) }
            } else {
                builder.append(child)
            }
        }
        let title = InlineBuilder.normalized(summary)
        return RichDetails(
            summary: title.isEmpty ? [.text("Details", [])] : title, blocks: builder.finish(),
            isOpen: element.hasAttr("open")
        )
    }
}

// MARK: - Inlines

private enum InlineBuilder {
    static func append(_ node: Node, style: RichStyle, into out: inout [RichInline]) {
        if let text = node as? TextNode {
            let collapsed = collapse(text.getWholeText())
            if !collapsed.isEmpty { out.append(.text(collapsed, style)) }
            return
        }
        guard let element = node as? Element, !RichHTMLParser.isDropped(element) else { return }
        switch element.tagNameNormal() {
        case "strong", "b":
            children(element, style.union(.bold), &out)
        case "em", "i", "cite", "dfn", "var":
            children(element, style.union(.italic), &out)
        case "del", "s", "strike":
            children(element, style.union(.strikethrough), &out)
        case "code", "kbd", "samp", "tt":
            children(element, style.union(.code), &out)
        case "br":
            out.append(.lineBreak)
        case "img":
            if let image = RichHTMLParser.image(element) { out.append(.image(image)) }
        case "picture":
            if let image = RichHTMLParser.picture(element) { out.append(.image(image)) }
        case "g-emoji":
            let text = (try? element.text()) ?? ""
            if !text.isEmpty { out.append(.emoji(text)) }
        case "a":
            link(element, style: style, into: &out)
        default:
            children(element, style, &out)
        }
    }

    private static func children(_ element: Element, _ style: RichStyle, _ out: inout [RichInline]) {
        for child in element.getChildNodes() { append(child, style: style, into: &out) }
    }

    private static let referenceHovercards: Set<String> = ["issue", "pull_request", "commit", "discussion"]

    private static func link(_ element: Element, style: RichStyle, into out: inout [RichInline]) {
        let url = RichHTMLParser.resolve(RichHTMLParser.attribute(element, "href"))
        let text = collapse((try? element.text()) ?? "").trimmingCharacters(in: .whitespaces)
        if element.hasClass("user-mention") || element.hasClass("team-mention") {
            let login = text.hasPrefix("@") ? String(text.dropFirst()) : text
            if !login.isEmpty {
                out.append(.mention(login: login, url: url))
                return
            }
        }
        let hovercard = RichHTMLParser.attribute(element, "data-hovercard-type") ?? ""
        if element.hasClass("issue-link") || element.hasClass("commit-link") || referenceHovercards.contains(hovercard),
           !text.isEmpty
        {
            out.append(.reference(text, url: url))
            return
        }
        var inner: [RichInline] = []
        children(element, style, &inner)
        guard let url else {
            out.append(contentsOf: inner)
            return
        }
        for inline in inner {
            switch inline {
            case .text(let text, let style):
                out.append(.link(text, url: url, style))
            case .image(var image):
                image.link = image.link ?? url
                out.append(.image(image))
            case .emoji(let text):
                out.append(.link(text, url: url, style))
            default:
                out.append(inline)
            }
        }
    }

    static func collapse(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace && character != "\u{00A0}" {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result
    }

    /// Merges same-style text runs, collapses whitespace across run boundaries, and trims around line breaks
    /// and at both ends. Returns empty when nothing visible remains.
    static func normalized(_ inlines: [RichInline]) -> [RichInline] {
        var out: [RichInline] = []
        func endsWithBreakOrSpace() -> Bool {
            switch out.last {
            case nil, .lineBreak: return true
            case .text(let text, _): return text.hasSuffix(" ")
            case .link(let text, _, _): return text.hasSuffix(" ")
            default: return false
            }
        }
        for inline in inlines {
            switch inline {
            case .text(var text, let style):
                if endsWithBreakOrSpace(), text.hasPrefix(" ") { text.removeFirst() }
                guard !text.isEmpty else { continue }
                if case .text(let previous, let previousStyle) = out.last, previousStyle == style {
                    out[out.count - 1] = .text(previous + text, style)
                } else {
                    out.append(.text(text, style))
                }
            case .link(var text, let url, let style):
                if endsWithBreakOrSpace(), text.hasPrefix(" ") { text.removeFirst() }
                guard !text.isEmpty else { continue }
                if case .link(let previous, let previousURL, let previousStyle) = out.last, previousURL == url,
                   previousStyle == style
                {
                    out[out.count - 1] = .link(previous + text, url: url, style)
                } else {
                    out.append(.link(text, url: url, style))
                }
            case .lineBreak:
                trimTrailingSpace(&out)
                out.append(.lineBreak)
            default:
                out.append(inline)
            }
        }
        while true {
            trimTrailingSpace(&out)
            guard case .lineBreak = out.last else { break }
            out.removeLast()
        }
        while case .lineBreak = out.first { out.removeFirst() }
        return out
    }

    private static func trimTrailingSpace(_ out: inout [RichInline]) {
        switch out.last {
        case .text(var text, let style) where text.hasSuffix(" "):
            text.removeLast()
            if text.isEmpty { out.removeLast() } else { out[out.count - 1] = .text(text, style) }
        case .link(var text, let url, let style) where text.hasSuffix(" "):
            text.removeLast()
            if text.isEmpty { out.removeLast() } else { out[out.count - 1] = .link(text, url: url, style) }
        default:
            break
        }
    }
}
