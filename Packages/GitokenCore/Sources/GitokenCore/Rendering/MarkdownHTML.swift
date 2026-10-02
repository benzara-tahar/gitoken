import Foundation

/// Small GitHub-flavoured markdown → HTML converter for bodies GitHub hasn't rendered (fixtures, local drafts),
/// so every body reaches the screen through `RichHTMLParser`. Covers what comments use: ATX/setext headings,
/// paragraphs with hard line breaks, block quotes, nested (task) lists, fenced code, tables, rules, raw HTML,
/// and inline code/bold/italic/strike/links/images/autolinks/@mentions/#refs.
enum MarkdownHTML {
    static func render(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
        return blocks(normalized.components(separatedBy: "\n"))
    }

    // MARK: Blocks

    private static func blocks(_ source: [String]) -> String {
        var lines = source
        var html = ""
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html += "<p>" + paragraph.map { inline($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: "<br>\n") + "</p>\n"
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if indent < 4, let fence = fenceMarker(trimmed) {
                flushParagraph()
                let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(String(lines[index].dropFirst(min(indent, lines[index].prefix { $0 == " " }.count))))
                    index += 1
                }
                index += 1
                let language = info.split(separator: " ").first.map(String.init)
                let lang = language.map { " lang=\"\(escape($0))\"" } ?? ""
                html += "<pre\(lang)><code>" + escape(code.joined(separator: "\n")) + "</code></pre>\n"
                continue
            }

            if indent < 4, trimmed.hasPrefix("<!--") {
                // Comments are dropped; markdown after `-->` on the closing line is still rendered.
                flushParagraph()
                while index < lines.count, !lines[index].contains("-->") { index += 1 }
                guard index < lines.count, let close = lines[index].range(of: "-->") else { break }
                let rest = lines[index][close.upperBound...].trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    index += 1
                } else {
                    lines[index] = rest
                }
                continue
            }

            if indent < 4, isHTMLBlockStart(trimmed) {
                flushParagraph()
                var raw: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    raw.append(lines[index])
                    index += 1
                }
                html += raw.joined(separator: "\n") + "\n"
                continue
            }

            if indent < 4, let heading = atxHeading(trimmed) {
                flushParagraph()
                html += "<h\(heading.level)>\(inline(heading.text))</h\(heading.level)>\n"
                index += 1
                continue
            }

            if indent < 4, !paragraph.isEmpty, let level = setextLevel(trimmed) {
                let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                paragraph = []
                html += "<h\(level)>\(inline(text))</h\(level)>\n"
                index += 1
                continue
            }

            if indent < 4, isRule(trimmed) {
                flushParagraph()
                html += "<hr>\n"
                index += 1
                continue
            }

            if indent < 4, trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var rest = current.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    index += 1
                }
                html += "<blockquote>\n" + blocks(quoted) + "</blockquote>\n"
                continue
            }

            if listMarker(line) != nil, paragraph.isEmpty || indent < 4 {
                flushParagraph()
                let (rendered, next) = list(lines, from: index)
                html += rendered
                index = next
                continue
            }

            if paragraph.isEmpty, trimmed.contains("|"), index + 1 < lines.count, isTableDelimiter(lines[index + 1]) {
                let header = cells(trimmed)
                let alignments = cells(lines[index + 1]).map(alignment)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !current.isEmpty, current.contains("|") else { break }
                    rows.append(cells(current))
                    index += 1
                }
                html += table(header: header, alignments: alignments, rows: rows)
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return html
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let run = trimmed.prefix { $0 == marker.first }
            return String(run)
        }
        return nil
    }

    /// CommonMark HTML block tags: a line opening with one of these is passed through untouched.
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "div", "dl", "figure", "footer", "h1", "h2",
        "h3", "h4", "h5", "h6", "header", "hr", "li", "ol", "p", "pre", "section", "summary", "table", "tbody", "td",
        "th", "thead", "tr", "ul",
    ]

    private static func isHTMLBlockStart(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("<") else { return false }
        let name = trimmed.dropFirst().drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        return blockTags.contains(name.lowercased())
    }

    private static func atxHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func setextLevel(_ trimmed: String) -> Int? {
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.count >= 2, trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    // MARK: Lists

    private struct Marker {
        var indent: Int
        var ordered: Bool
        var number: Int
        /// Column where the item's content starts.
        var contentColumn: Int
    }

    private static func listMarker(_ line: String) -> Marker? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.isEmpty || after.hasPrefix(" ") else { return nil }
            if isRule(String(rest)) { return nil }
            let spaces = min(4, max(1, after.prefix { $0 == " " }.count))
            return Marker(indent: indent, ordered: false, number: 1, contentColumn: indent + 1 + spaces)
        }
        let digits = rest.prefix { $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let after = afterDigits.dropFirst()
        guard after.isEmpty || after.hasPrefix(" ") else { return nil }
        let spaces = min(4, max(1, after.prefix { $0 == " " }.count))
        return Marker(
            indent: indent, ordered: true, number: Int(digits) ?? 1, contentColumn: indent + digits.count + 1 + spaces
        )
    }

    /// Renders the list starting at `start`; returns the HTML and the index of the first line after it.
    private static func list(_ lines: [String], from start: Int) -> (String, Int) {
        guard let first = listMarker(lines[start]) else { return ("", start + 1) }
        var items: [[String]] = []
        var index = start
        while index < lines.count {
            let line = lines[index]
            let indent = line.prefix { $0 == " " }.count
            if let marker = listMarker(line), marker.indent <= first.indent + 1, marker.ordered == first.ordered {
                let content = String(line.dropFirst(min(line.count, marker.contentColumn)))
                items.append([content])
                index += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line continues the list only if the next non-blank line is indented or another item.
                var next = index + 1
                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                guard next < lines.count else { break }
                let nextIndent = lines[next].prefix { $0 == " " }.count
                let continues = nextIndent > first.indent
                    || (listMarker(lines[next]).map { $0.indent <= first.indent + 1 && $0.ordered == first.ordered } ?? false)
                guard continues else { break }
                items[items.count - 1].append("")
                index += 1
                continue
            }
            if indent > first.indent {
                let strip = min(indent, first.contentColumn)
                items[items.count - 1].append(String(line.dropFirst(strip)))
                index += 1
                continue
            }
            // Lazy continuation of the item's paragraph.
            if listMarker(line) == nil, let last = items.last?.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                items[items.count - 1].append(line.trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }
            break
        }

        let tag = first.ordered ? "ol" : "ul"
        let startAttribute = first.ordered && first.number != 1 ? " start=\"\(first.number)\"" : ""
        var html = "<\(tag)\(startAttribute)>\n"
        for var item in items {
            var checkbox = ""
            if let head = item.first, let task = taskPrefix(head) {
                checkbox = "<input type=\"checkbox\" disabled\(task.checked ? " checked" : "")> "
                item[0] = task.rest
            }
            let inner = blocks(item)
            // Tight items render their single paragraph inline, like GitHub.
            if inner.hasPrefix("<p>"), inner.components(separatedBy: "<p>").count == 2 {
                let body = inner.replacingOccurrences(of: "<p>", with: "").replacingOccurrences(of: "</p>", with: "")
                html += "<li>\(checkbox)\(body.trimmingCharacters(in: .whitespacesAndNewlines))</li>\n"
            } else {
                html += "<li>\(checkbox)\(inner)</li>\n"
            }
        }
        return (html + "</\(tag)>\n", index)
    }

    private static func taskPrefix(_ text: String) -> (checked: Bool, rest: String)? {
        for (prefix, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(prefix) {
            return (checked, String(text.dropFirst(prefix.count)))
        }
        return nil
    }

    // MARK: Tables

    private static func isTableDelimiter(_ line: String) -> Bool {
        let parts = cells(line)
        guard !parts.isEmpty, line.contains("-") else { return false }
        return parts.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var previous: Character?
        for character in row {
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode, previous != "\\" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private static func alignment(_ delimiter: String) -> String? {
        switch (delimiter.hasPrefix(":"), delimiter.hasSuffix(":")) {
        case (true, true): "center"
        case (false, true): "right"
        case (true, false): "left"
        default: nil
        }
    }

    private static func table(header: [String], alignments: [String?], rows: [[String]]) -> String {
        func cell(_ tag: String, _ text: String, _ column: Int) -> String {
            let align = column < alignments.count ? alignments[column].map { " align=\"\($0)\"" } ?? "" : ""
            return "<\(tag)\(align)>\(inline(text))</\(tag)>"
        }
        var html = "<table>\n<thead><tr>" + header.enumerated().map { cell("th", $1, $0) }.joined() + "</tr></thead>\n<tbody>\n"
        for row in rows {
            let padded = (0..<header.count).map { $0 < row.count ? row[$0] : "" }
            html += "<tr>" + padded.enumerated().map { cell("td", $1, $0) }.joined() + "</tr>\n"
        }
        return html + "</tbody>\n</table>\n"
    }

    // MARK: Inlines

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    private static let rawTag = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>|<!--.*?-->"#)

    /// Code spans and raw HTML tags pass through; everything between them gets inline markdown.
    static func inline(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while !rest.isEmpty {
            guard let tick = rest.firstIndex(of: "`") else {
                out += withoutCode(String(rest))
                break
            }
            let run = rest[tick...].prefix { $0 == "`" }
            let afterOpen = rest.index(tick, offsetBy: run.count)
            guard let close = rest[afterOpen...].range(of: String(run)) else {
                out += withoutCode(String(rest))
                break
            }
            out += withoutCode(String(rest[..<tick]))
            var code = String(rest[afterOpen..<close.lowerBound])
            if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2 { code = String(code.dropFirst().dropLast()) }
            out += "<code>" + escape(code) + "</code>"
            rest = rest[close.upperBound...]
        }
        return out
    }

    private static func withoutCode(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in rawTag.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                out += spans(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            out += ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { out += spans(ns.substring(from: cursor)) }
        return out
    }

    private static let spanPattern = try! NSRegularExpression(pattern: [
        #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#,
        #"\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#,
        #"(https?://[^\s<>()]*[^\s<>().,;:!?'"*_~])"#,
        #"\*\*(.+?)\*\*"#,
        #"(?<![\w])__(.+?)__(?![\w])"#,
        #"~~(.+?)~~"#,
        #"(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])"#,
        #"(?<![\w_])_(?![\s_])(.+?)(?<![\s_])_(?![\w_])"#,
        #"(?<![\w/@.`])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38})(?:/[A-Za-z0-9_.-]+)?)"#,
        #"(?<![\w&/#])#(\d+)\b"#,
    ].joined(separator: "|"))

    private static func spans(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in spanPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                out += escapeText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            if let src = group(2) {
                out += "<img src=\"\(escape(src))\" alt=\"\(escape(group(1) ?? ""))\">"
            } else if let label = group(3), let href = group(4) {
                out += "<a href=\"\(escape(href))\">\(spans(label))</a>"
            } else if let url = group(5) {
                out += "<a href=\"\(escape(url))\">\(escape(url))</a>"
            } else if let bold = group(6) ?? group(7) {
                out += "<strong>\(spans(bold))</strong>"
            } else if let strike = group(8) {
                out += "<del>\(spans(strike))</del>"
            } else if let italic = group(9) ?? group(10) {
                out += "<em>\(spans(italic))</em>"
            } else if let login = group(11) {
                out += "<a class=\"user-mention\" href=\"https://github.com/\(escape(login))\">@\(escape(login))</a>"
            } else if let number = group(12) {
                out += "<a class=\"issue-link\">#\(number)</a>"
            }
        }
        if cursor < ns.length { out += escapeText(ns.substring(from: cursor)) }
        return out
    }

    /// Escapes markup characters but keeps entities the author typed (`&nbsp;`, `&#x27;`) and drops the backslash
    /// of markdown escapes like `\*`.
    private static func escapeText(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "&":
                let tail = characters[(index + 1)...].prefix(10)
                let name = tail.prefix { $0 != ";" }
                let isEntity = name.count < tail.count && !name.isEmpty
                    && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "#" }
                out += isEntity ? "&" : "&amp;"
            case "\\" where index + 1 < characters.count && characters[index + 1].isPunctuation:
                index += 1
                out += escape(String(characters[index]))
            default:
                out.append(character)
            }
            index += 1
        }
        return out
    }
}
