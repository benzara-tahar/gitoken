import Foundation
import SwiftUI

/// Just enough GitHub-flavoured markdown for notification-sized comments: paragraphs, block quotes,
/// fenced code, inline code, bold/italic, @mentions, #refs and bare links.
enum MarkdownLite {
    enum Block: Hashable {
        case paragraph(String)
        case quote(String)
        case code(String)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            guard !joined.isEmpty else { return }
            let lines = joined.components(separatedBy: "\n")
            if lines.allSatisfy({ $0.hasPrefix(">") }) {
                let body = lines.map { line -> String in
                    var l = line.dropFirst()
                    if l.hasPrefix(" ") { l = l.dropFirst() }
                    return String(l)
                }
                blocks.append(.quote(body.joined(separator: "\n")))
            } else {
                blocks.append(.paragraph(joined))
            }
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    struct Style {
        var accent: Color
        var codeBackground: Color
        var mentionBackground: Color
        var viewer: String?
    }

    private static let inlinePattern = try! NSRegularExpression(
        pattern: #"\*\*([^*]+)\*\*|(?<![\w*])\*([^*\s][^*]*)\*|(?<![\w/&])@([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:/[A-Za-z0-9-]+)?)|(?<![\w&#])#(\d+)\b|(https?://[^\s)<>]+)"#
    )

    static func inline(_ text: String, style: Style) -> AttributedString {
        var out = AttributedString()
        let parts = text.components(separatedBy: "`")
        for (index, part) in parts.enumerated() {
            // Odd segments sit between backticks; an unmatched trailing backtick stays literal.
            if index % 2 == 1, index < parts.count - 1 || parts.count % 2 == 1 {
                // Word joiners keep short spans like `?q=` on one line; long spans may still wrap.
                let body = part.count <= 32 ? part.map(String.init).joined(separator: "\u{2060}") : part
                var code = AttributedString("\u{2009}\u{2060}\(body)\u{2060}\u{2009}")
                code.font = .system(size: 11.5, design: .monospaced)
                code.backgroundColor = style.codeBackground
                out += code
            } else {
                out += decorate(index % 2 == 1 ? "`" + part : part, style: style)
            }
        }
        return out
    }

    private static func decorate(_ text: String, style: Style) -> AttributedString {
        var out = AttributedString()
        let ns = text as NSString
        var cursor = 0
        for match in inlinePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                out += AttributedString(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length
            func group(_ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            if let bold = group(1) {
                var s = AttributedString(bold)
                s.inlinePresentationIntent = .stronglyEmphasized
                out += s
            } else if let italic = group(2) {
                var s = AttributedString(italic)
                s.inlinePresentationIntent = .emphasized
                out += s
            } else if let login = group(3) {
                var s = AttributedString("@\(login)")
                s.foregroundColor = style.accent
                s.font = .system(size: 13, weight: .semibold)
                if login.caseInsensitiveCompare(style.viewer ?? "") == .orderedSame {
                    s.backgroundColor = style.mentionBackground
                }
                s.link = URL(string: "https://github.com/\(login)")
                out += s
            } else if let number = group(4) {
                var s = AttributedString("#\(number)")
                s.foregroundColor = style.accent
                out += s
            } else if let link = group(5) {
                var s = AttributedString(link)
                s.link = URL(string: link)
                s.foregroundColor = style.accent
                out += s
            }
        }
        if cursor < ns.length { out += AttributedString(ns.substring(from: cursor)) }
        return out
    }

    static func mentions(_ text: String, login: String?) -> Bool {
        guard let login, !login.isEmpty else { return false }
        return text.range(of: "@\(login)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Renders markdown-lite blocks with the conversation's typography.
struct MarkdownText: View {
    @Environment(\.theme) private var theme
    @Environment(NotchModel.self) private var model
    var text: String
    var size: CGFloat = 13

    var body: some View {
        let style = MarkdownLite.Style(
            accent: theme.accent, codeBackground: theme.chipBackground, mentionBackground: theme.accent.opacity(0.15),
            viewer: model.viewerLogin
        )
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownLite.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let p):
                    Text(MarkdownLite.inline(p, style: style))
                        .font(.system(size: size))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                case .quote(let q):
                    Text(MarkdownLite.inline(q, style: style))
                        .font(.system(size: size))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 9)
                        .overlay(alignment: .leading) { Rectangle().fill(theme.hairline).frame(width: 2) }
                case .code(let c):
                    ScrollView(.horizontal) {
                        Text(c)
                            .font(.system(size: 11, design: .monospaced))
                            .fixedSize()
                            .padding(8)
                    }
                    .scrollIndicators(.never)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.codeBackground))
                }
            }
        }
        .textSelection(.enabled)
        .tint(theme.accent)
    }
}
