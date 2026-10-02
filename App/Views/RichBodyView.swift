import GitokenCore
import SwiftUI

/// Typography and colors shared by every piece of a rendered body.
struct RichStyleContext {
    var theme: Theme
    var size: CGFloat
    var viewer: String?
    /// Dark surface: picks `prefers-color-scheme: dark` image variants.
    var dark: Bool
}

/// A comment/description body rendered from GitHub's HTML. Bodies taller than `clampHeight` collapse behind a fade
/// with "Show more".
struct RichBodyView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(NotchModel.self) private var model
    let source: RichBody
    var size: CGFloat = 13
    var clampHeight: CGFloat? = 280

    @State private var expanded = false
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        let style = RichStyleContext(theme: theme, size: size, viewer: model.viewerLogin, dark: colorScheme == .dark)
        // A little slack so a body barely over the limit isn't clamped just to hide one line.
        let clamped = clampHeight.map { naturalHeight > $0 + 48 } ?? false
        let collapsed = clamped && !expanded
        VStack(alignment: .leading, spacing: 4) {
            RichBlocksView(blocks: source.document.blocks, style: style)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
                .frame(maxHeight: collapsed ? clampHeight : nil, alignment: .top)
                .clipped()
                .mask(alignment: .top) {
                    if collapsed {
                        LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                    } else {
                        Rectangle()
                    }
                }
            if clamped {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                        Text(expanded ? "Show less" : "Show more")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "expanded" : "collapsed")
            }
        }
        .textSelection(.enabled)
        .tint(theme.accent)
    }
}

struct RichBlocksView: View {
    let blocks: [RichBlock]
    let style: RichStyleContext
    var listDepth = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                RichBlockView(block: block, style: style, listDepth: listDepth)
            }
        }
    }
}

private struct RichBlockView: View {
    let block: RichBlock
    let style: RichStyleContext
    let listDepth: Int

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            RichInlineText(inlines: inlines, style: style)
        case .heading(let level, let inlines):
            RichHeading(level: level, inlines: inlines, style: style)
        case .list(let list):
            RichListView(list: list, style: style, depth: listDepth)
        case .blockquote(let blocks):
            RichBlocksView(blocks: blocks, style: style, listDepth: listDepth)
                .foregroundStyle(.secondary)
                .padding(.leading, 9)
                .overlay(alignment: .leading) { Rectangle().fill(style.theme.hairline).frame(width: 2) }
        case .code(let code):
            RichCodeView(code: code, style: style)
        case .table(let table):
            RichTableView(table: table, style: style)
        case .image(let image):
            RichBlockImage(image: image, style: style)
        case .details(let details):
            RichDetailsView(details: details, style: style, listDepth: listDepth)
        case .rule:
            Rectangle().fill(style.theme.hairline).frame(height: 1).padding(.vertical, 2)
        }
    }
}

// MARK: - Headings

private struct RichHeading: View {
    let level: Int
    let inlines: [RichInline]
    let style: RichStyleContext

    var body: some View {
        // Modest steps for a narrow panel: h1 is only a few points above body text.
        let size: CGFloat = switch level {
        case 1: style.size + 3
        case 2: style.size + 2
        case 3: style.size + 1
        case 4: style.size
        default: style.size - 0.5
        }
        var headingStyle = style
        headingStyle.size = size
        return VStack(alignment: .leading, spacing: 4) {
            RichInlineText(inlines: inlines, style: headingStyle, weight: level <= 3 ? .bold : .semibold)
                .foregroundStyle(level >= 5 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if level <= 2 {
                Rectangle().fill(style.theme.hairline).frame(height: 1)
            }
        }
        .padding(.top, level <= 2 ? 2 : 0)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Lists

private struct RichListView: View {
    let list: RichList
    let style: RichStyleContext
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(item: item, index: index)
                    RichBlocksView(blocks: item.blocks, style: style, listDepth: depth + 1)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(item: RichListItem, index: Int) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: style.size - 1, weight: .medium))
                .foregroundStyle(checked ? AnyShapeStyle(style.theme.accent) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else if list.ordered {
            Text("\(list.start + index).")
                .font(.system(size: style.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .trailing)
        } else {
            Text(["•", "◦", "▪︎"][depth % 3])
                .font(.system(size: style.size))
                .foregroundStyle(.secondary)
                .frame(width: 10)
        }
    }
}

// MARK: - Details

private struct RichDetailsView: View {
    let details: RichDetails
    let style: RichStyleContext
    let listDepth: Int
    @State private var open: Bool?

    var body: some View {
        let isOpen = open ?? details.isOpen
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { open = !isOpen }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.secondary)
                    RichInlineText(inlines: details.summary, style: style, weight: .semibold)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
            if isOpen {
                RichBlocksView(blocks: details.blocks, style: style, listDepth: listDepth)
                    .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style.theme.chipBackground))
    }
}

// MARK: - Code

private struct RichCodeView: View {
    let code: RichCode
    let style: RichStyleContext

    var body: some View {
        let theme = style.theme
        VStack(alignment: .leading, spacing: 0) {
            if code.isSuggestion {
                Text("Suggested change")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(code.lines.enumerated()), id: \.offset) { _, line in
                        lineView(line)
                    }
                }
                .padding(.vertical, 7)
                .fixedSize()
            }
            .scrollIndicators(.never)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.codeBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
    }

    private func lineView(_ line: RichCodeLine) -> some View {
        let theme = style.theme
        let marker = line.change == .added ? "+" : line.change == .removed ? "-" : nil
        return HStack(spacing: 0) {
            if code.isSuggestion {
                Text(marker ?? " ")
                    .foregroundStyle(line.change == .added ? theme.success : line.change == .removed ? theme.danger : .secondary)
                    .frame(width: 14, alignment: .center)
            }
            Text(highlighted(line))
                .padding(.trailing, 10)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.leading, code.isSuggestion ? 0 : 9)
        .frame(minHeight: 16)
        .background(
            line.change == .added ? theme.success.opacity(0.12) : line.change == .removed ? theme.danger.opacity(0.11) : .clear
        )
    }

    private func highlighted(_ line: RichCodeLine) -> AttributedString {
        if !code.isHighlighted, code.language != nil {
            return SyntaxHighlighter.highlight(line.text, theme: style.theme)
        }
        var out = AttributedString()
        for token in line.tokens {
            var piece = AttributedString(token.text.replacingOccurrences(of: "\t", with: "    "))
            if let color = color(token.kind) { piece.foregroundColor = color }
            out += piece
        }
        return out
    }

    private func color(_ kind: RichTokenKind?) -> Color? {
        let theme = style.theme
        switch kind {
        case .keyword: return theme.tokenKeyword
        case .string: return theme.tokenString
        case .constant, .variable: return theme.tokenNumber
        case .function: return theme.tokenFunction
        case .type, .tag: return theme.tokenType
        case .comment: return theme.tokenComment
        case .inserted: return theme.success
        case .deleted: return theme.danger
        case nil: return nil
        }
    }
}

// MARK: - Tables

private struct RichTableView: View {
    let table: RichTable
    let style: RichStyleContext

    private static let maxColumnWidth: CGFloat = 240

    var body: some View {
        let theme = style.theme
        let columns = table.columnCount
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !table.header.isEmpty {
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            cell(column < table.header.count ? table.header[column] : [], column: column, header: true)
                        }
                    }
                    .background(theme.chipBackground)
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            cell(column < row.count ? row[column] : [], column: column, header: false)
                        }
                    }
                }
            }
            .fixedSize()
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .scrollIndicators(.automatic)
    }

    private func cell(_ inlines: [RichInline], column: Int, header: Bool) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        var cellStyle = style
        cellStyle.size = style.size - 1
        return RichInlineText(
            inlines: inlines, style: cellStyle, weight: header ? .semibold : .regular,
            alignment: alignment.textAlignment
        )
        .modifier(CappedWidth(maxWidth: Self.maxColumnWidth))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frameAlignment)
        .overlay(alignment: .trailing) { Rectangle().fill(style.theme.hairline).frame(width: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(style.theme.hairline).frame(height: 1) }
    }
}

/// Lets text take its natural single-line width up to `maxWidth`, then wrap: inside a horizontal scroll view
/// nothing proposes a width, so a plain `frame(maxWidth:)` would clip the wrapped lines instead.
private struct CappedWidth: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        CappedWidthLayout(maxWidth: maxWidth) { content }
    }
}

private struct CappedWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let ideal = view.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth else { return ideal }
        return view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private extension RichAlignment {
    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

// MARK: - Block images

private struct RichBlockImage: View {
    @Environment(\.openURL) private var openURL
    let image: RichImage
    let style: RichStyleContext
    @State private var loaded: NSImage?
    @State private var failed = false

    var body: some View {
        let shown = loaded ?? RichImageLoader.shared.cached(image, dark: style.dark)
        let target = image.link ?? image.url
        Button { openURL(target) } label: {
            Group {
                if let shown {
                    let natural = shown.size
                    let width = image.width ?? natural.width
                    let ratio = natural.height > 0 ? natural.width / natural.height : 1
                    Image(nsImage: shown)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(ratio, contentMode: .fit)
                        .frame(maxWidth: width)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    placeholder
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(image.alt.isEmpty ? target.absoluteString : image.alt)
        .accessibilityLabel(image.alt.isEmpty ? "Image" : image.alt)
        .task(id: "\(image.url.absoluteString)|\(style.dark)") {
            guard RichImageLoader.shared.cached(image, dark: style.dark) == nil else { return }
            loaded = await RichImageLoader.shared.load(image, dark: style.dark)
            failed = loaded == nil
        }
    }

    private var placeholder: some View {
        let width = image.width ?? 220
        let height = image.height.map { h in image.width.map { _ in h } ?? h } ?? 120
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(style.theme.chipBackground)
            .overlay {
                VStack(spacing: 4) {
                    if failed {
                        Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(.tertiary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if !image.alt.isEmpty {
                        Text(image.alt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: width)
            .aspectRatio(width / max(height, 1), contentMode: .fit)
    }
}
