import Foundation
import GitokenCore
import SwiftUI

/// A parsed GitHub `diffHunk`: header plus numbered lines. GitHub's hunk ends at the commented line.
struct ParsedHunk {
    enum Kind { case context, added, removed }

    struct Line: Identifiable {
        let id: Int
        var kind: Kind
        var text: String
        var oldNumber: Int?
        var newNumber: Int?
    }

    var header: String
    var lines: [Line]

    private static let headerPattern = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)"#)

    init(_ hunk: String) {
        var rows = hunk.components(separatedBy: "\n")
        if rows.last?.isEmpty == true { rows.removeLast() }
        var oldNo = 1
        var newNo = 1
        header = ""
        if let first = rows.first, first.hasPrefix("@@") {
            header = first
            rows.removeFirst()
            let ns = first as NSString
            if let m = Self.headerPattern.firstMatch(in: first, range: NSRange(location: 0, length: ns.length)) {
                oldNo = Int(ns.substring(with: m.range(at: 1))) ?? 1
                newNo = Int(ns.substring(with: m.range(at: 2))) ?? 1
            }
        }
        var out: [Line] = []
        for (i, raw) in rows.enumerated() {
            let marker = raw.first
            let text = raw.isEmpty ? "" : String(raw.dropFirst())
            switch marker {
            case "+":
                out.append(Line(id: i, kind: .added, text: text, oldNumber: nil, newNumber: newNo))
                newNo += 1
            case "-":
                out.append(Line(id: i, kind: .removed, text: text, oldNumber: oldNo, newNumber: nil))
                oldNo += 1
            case "\\":
                continue
            default:
                out.append(Line(id: i, kind: .context, text: text, oldNumber: oldNo, newNumber: newNo))
                oldNo += 1
                newNo += 1
            }
        }
        lines = out
    }
}

/// Code excerpt for a review comment: the last 4 lines by default; expanding shows the whole hunk and widens
/// the conversation panel (QA: the expanded diff no longer stays in the narrow column).
struct DiffHunkView: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    let comment: ReviewComment
    @State private var viewportWidth: CGFloat = 0

    private static let collapsedLines = 4

    var body: some View {
        let hunk = ParsedHunk(comment.diffHunk)
        let expanded = model.expandedDiffs.contains(comment.id)
        let shown = expanded ? hunk.lines : Array(hunk.lines.suffix(Self.collapsedLines))
        let hotID = hunk.lines.last?.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(comment.path).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                if let line = comment.line ?? hunk.lines.last?.newNumber { Text("L\(line)").foregroundStyle(.tertiary) }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.5) }

            if expanded, !hunk.header.isEmpty {
                Text(hunk.header)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.accent.opacity(0.07))
            }

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { line in
                        lineRow(line, hot: line.id == hotID)
                    }
                }
                .padding(.vertical, 3)
                .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.automatic)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }

            if hunk.lines.count > Self.collapsedLines {
                Button {
                    withAnimation(motion.open) {
                        if expanded { model.expandedDiffs.remove(comment.id) } else { model.expandedDiffs.insert(comment.id) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                        Text(expanded ? "Show less" : "Show full diff · \(hunk.lines.count) lines")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
                .accessibilityValue(expanded ? "expanded" : "collapsed")
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.codeBackground))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
    }

    private func lineRow(_ line: ParsedHunk.Line, hot: Bool) -> some View {
        HStack(spacing: 0) {
            Text(line.kind == .removed ? line.oldNumber.map(String.init) ?? "" : line.newNumber.map(String.init) ?? "")
                .foregroundStyle(hot ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 7)
            Text(line.kind == .added ? "+" : line.kind == .removed ? "-" : " ")
                .foregroundStyle(line.kind == .added ? theme.success : line.kind == .removed ? theme.danger : .secondary)
                .frame(width: 12, alignment: .leading)
            Text(SyntaxHighlighter.highlight(line.text, theme: theme))
                .fixedSize()
                .padding(.trailing, 12)
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(height: 17)
        .frame(minWidth: viewportWidth, maxWidth: .infinity, alignment: .leading)
        .background(background(line.kind))
        .overlay(alignment: .leading) {
            if hot { Rectangle().fill(Color(hex: 0xE8A400)).frame(width: 2) }
        }
    }

    private func background(_ kind: ParsedHunk.Kind) -> Color {
        switch kind {
        case .added: theme.success.opacity(0.12)
        case .removed: theme.danger.opacity(0.11)
        case .context: .clear
        }
    }
}

enum SyntaxHighlighter {
    private static let keywordList = """
        const let var function return import from export if else for while new type interface extends async await \
        default func package defer nil struct map range true false null undefined as of in typeof class enum \
        case switch guard self static public private fileprivate internal final protocol extension where throws \
        try catch def fn pub impl mut use mod match
        """
    private static let keywords: Set<String> = Set(keywordList.split(separator: " ").map { String($0) })

    private static let token = try! NSRegularExpression(
        pattern: #"(//.*$|(?<!\S)# .*$)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_$][\w$]*)"#,
        options: [.anchorsMatchLines]
    )

    static func highlight(_ code: String, theme: Theme) -> AttributedString {
        let expanded = code.replacingOccurrences(of: "\t", with: "  ")
        var out = AttributedString()
        let ns = expanded as NSString
        var cursor = 0
        for m in token.matches(in: expanded, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out += AttributedString(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            cursor = m.range.location + m.range.length
            var piece = AttributedString(ns.substring(with: m.range))
            if m.range(at: 1).location != NSNotFound {
                piece.foregroundColor = theme.tokenComment
            } else if m.range(at: 2).location != NSNotFound {
                piece.foregroundColor = theme.tokenString
            } else if m.range(at: 3).location != NSNotFound {
                piece.foregroundColor = theme.tokenNumber
            } else {
                let word = ns.substring(with: m.range)
                let next = cursor < ns.length ? ns.substring(with: NSRange(location: cursor, length: 1)) : ""
                if keywords.contains(word) {
                    piece.foregroundColor = theme.tokenKeyword
                } else if next == "(" {
                    piece.foregroundColor = theme.tokenFunction
                } else if word.first?.isUppercase == true {
                    piece.foregroundColor = theme.tokenType
                }
            }
            out += piece
        }
        if cursor < ns.length { out += AttributedString(ns.substring(from: cursor)) }
        return out
    }
}
