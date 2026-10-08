import Foundation
import GitokenCore
import SwiftUI

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
        // GitHub's hunk ends at the commented line; each side is highlighted on its own, numbered by the core parser.
        let hunk = PreviewDocument.build(
            mode: .diff, path: comment.path, fileText: nil, patch: comment.diffHunk, threads: [], viewing: .head("")
        )
        let header = hunk.lines.first { $0.kind == .hunkHeader }?.text ?? ""
        let rows = hunk.lines.indices.filter { hunk.lines[$0].kind != .hunkHeader }
        let expanded = model.expandedDiffs.contains(comment.id)
        let shown = expanded ? rows : Array(rows.suffix(Self.collapsedLines))
        let hotIndex = rows.last
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(comment.path).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                if let line = comment.line ?? hotIndex.flatMap({ hunk.lines[$0].newNumber }) {
                    Text("L\(line)").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.5) }

            if expanded, !header.isEmpty {
                Text(header)
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
                    ForEach(shown, id: \.self) { index in
                        lineRow(hunk, index, hot: index == hotIndex)
                    }
                }
                .padding(.vertical, 3)
                .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.automatic)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }

            if rows.count > Self.collapsedLines {
                Button {
                    withAnimation(motion.open) {
                        if expanded { model.expandedDiffs.remove(comment.id) } else { model.expandedDiffs.insert(comment.id) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                        Text(expanded ? "Show less" : "Show full diff · \(rows.count) lines")
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

    private func lineRow(_ hunk: PreviewDocument, _ index: Int, hot: Bool) -> some View {
        let line = hunk.lines[index]
        return HStack(spacing: 0) {
            Text(line.kind == .removed ? line.oldNumber.map(String.init) ?? "" : line.newNumber.map(String.init) ?? "")
                .foregroundStyle(hot ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 7)
            Text(line.kind == .added ? "+" : line.kind == .removed ? "-" : " ")
                .foregroundStyle(line.kind == .added ? theme.success : line.kind == .removed ? theme.danger : .secondary)
                .frame(width: 12, alignment: .leading)
            Text(CodeHighlighting.line(line.text, at: hunk.lineStarts[index], spans: hunk.spans, theme: theme, tab: "  "))
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

    private func background(_ kind: PreviewLine.Kind) -> Color {
        switch kind {
        case .added: theme.success.opacity(0.12)
        case .removed: theme.danger.opacity(0.11)
        case .context, .plain, .hunkHeader: .clear
        }
    }
}
