import GitokenCore
import SwiftUI

/// Splits a timeline at the visit boundary: everything from the first newer item by someone else is "new".
struct TimelineSplit {
    var hiddenOlder: [TimelineItem]
    var older: [TimelineItem]
    var newer: [TimelineItem]
    var dividerLabel: String?

    static let keepOlder = 3

    init(items: [TimelineItem], lastVisitAt: Date?, viewer: String?, showAllOlder: Bool) {
        let boundary: Int?
        if let visit = lastVisitAt {
            boundary = items.firstIndex { $0.createdAt > visit && $0.actor.login != viewer }
        } else {
            boundary = items.isEmpty ? nil : 0
        }
        let olderAll = boundary.map { Array(items[..<$0]) } ?? items
        newer = boundary.map { Array(items[$0...]) } ?? []
        if !showAllOlder, olderAll.count > Self.keepOlder + 1 {
            hiddenOlder = Array(olderAll.dropLast(Self.keepOlder))
            older = Array(olderAll.suffix(Self.keepOlder))
        } else {
            hiddenOlder = []
            older = olderAll
        }
        if newer.isEmpty {
            dividerLabel = nil
        } else {
            let n = newer.filter { $0.actor.login != viewer }.count
            dividerLabel = lastVisitAt != nil
                ? "Since your last visit · \(n) new"
                : "First visit · \(Format.plural(n, "update"))"
        }
    }
}

/// Context shared by timeline rows.
struct TimelineContext {
    var group: InboxGroup
    var viewer: String?
    var now: Date
    /// All review comments in the thread by node id, for reply quotes and thread roots.
    var reviewComments: [String: ReviewComment]

    func root(of comment: ReviewComment) -> ReviewComment {
        var current = comment
        var seen: Set<String> = [current.id]
        while let parentID = current.replyToID, let parent = reviewComments[parentID], !seen.contains(parentID) {
            seen.insert(parentID)
            current = parent
        }
        return current
    }

    var kindNoun: String { group.thread.kind == .issue ? "issue" : "pull request" }
}

struct TimelineItemView: View {
    @Environment(\.theme) private var theme
    let item: TimelineItem
    let context: TimelineContext

    var body: some View {
        switch item.payload {
        case .opened(let body):
            FullEventRow(actor: item.actor, date: item.createdAt, context: context) {
                Text("opened this \(context.kindNoun)")
            } content: {
                if !body.isEmpty { RichBodyView(source: body) }
            }
        case .comment(let body):
            let mentionsMe = body.mentions(context.viewer) && item.actor.login != context.viewer
            FullEventRow(actor: item.actor, date: item.createdAt, context: context) {
                if mentionsMe { EventTag(text: "mentioned you") }
            } content: {
                RichBodyView(source: body)
                    .padding(mentionsMe ? 10 : 0)
                    .background {
                        if mentionsMe { HighlightBox(tone: theme.accent) }
                    }
            }
        case .review(let state, let body, let comments):
            if body.isEmpty && state == .commented && !comments.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(comments) { comment in
                        ReviewCommentRow(comment: comment, context: context)
                    }
                }
            } else {
                let look = ReviewLook(state)
                FullEventRow(
                    actor: item.actor, date: item.createdAt, context: context,
                    badge: ActivityBadge(symbol: look.symbol, tone: look.tone)
                ) {
                    Text(look.verb).foregroundStyle(look.tone.color(theme)).fontWeight(.semibold)
                } content: {
                    VStack(alignment: .leading, spacing: 8) {
                        if !body.isEmpty {
                            RichBodyView(source: body)
                                .foregroundStyle(look.tone == .accent ? AnyShapeStyle(.primary) : AnyShapeStyle(look.tone.color(theme)))
                                .padding(10)
                                .background { HighlightBox(tone: look.tone.color(theme)) }
                        }
                        ForEach(comments) { comment in
                            ReviewCommentBlock(comment: comment, context: context, showsAuthor: comment.author.login != item.actor.login)
                        }
                    }
                }
            }
        case .commits(let count, let headlines):
            CompactEventRow(symbol: "smallcircle.circle", tone: .neutral, date: item.createdAt, context: context) {
                Text("\(Text(Format.firstName(item.actor, viewer: context.viewer)).fontWeight(.semibold).foregroundStyle(.primary)) pushed \(Format.plural(count, "commit"))")
            } extra: {
                if !headlines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(headlines.prefix(4).enumerated()), id: \.offset) { _, line in
                            Text(line).lineLimit(1).truncationMode(.tail)
                        }
                        if headlines.count > 4 {
                            Text("and \(headlines.count - 4) more").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
        case .checks(let summary):
            ChecksRow(summary: summary, date: item.createdAt, context: context)
        case .event(let kind, let detail):
            EventRow(kind: kind, detail: detail, item: item, context: context)
        }
    }
}

/// One timeline row: an item, a collapsed run of review requests, or a collapsed AI review.
struct TimelineEntryView: View {
    let entry: TimelineEntry
    let context: TimelineContext

    var body: some View {
        switch entry {
        case .item(let item): TimelineItemView(item: item, context: context)
        case .reviewRequests(let group): ReviewRequestsRow(group: group, context: context)
        case .aiReview(let item): AIReviewRow(item: item, context: context)
        }
    }
}

/// "Leo requested review from 3 teams"; the names show on hover and when expanded.
private struct ReviewRequestsRow: View {
    let group: ReviewRequestGroup
    let context: TimelineContext
    @State private var expanded = false

    var body: some View {
        let name = Format.firstName(group.actor, viewer: context.viewer)
        Button { expanded.toggle() } label: {
            CompactEventRow(symbol: "eye", tone: .warn, date: group.createdAt, context: context) {
                Text("\(Text(name).fontWeight(.semibold).foregroundStyle(.primary)) \(summary) \(Image(systemName: expanded ? "chevron.up" : "chevron.down"))")
            } extra: {
                if expanded {
                    FlowLayout(spacing: 4) {
                        ForEach(group.reviewers, id: \.self) { reviewer in
                            Label(reviewer, systemImage: reviewer.contains("/") ? "person.3" : "person")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .frame(height: 19)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group.reviewers.joined(separator: ", "))
        .accessibilityValue(expanded ? "expanded" : "collapsed")
    }

    private var summary: String {
        let others = group.reviewers.filter { $0.caseInsensitiveCompare(context.viewer ?? "") != .orderedSame }
        if group.includes(context.viewer) {
            return others.isEmpty ? "requested your review" : "requested your review along with \(Self.describe(others))"
        }
        return "requested review from \(Self.describe(others))"
    }

    static func describe(_ reviewers: [String]) -> String {
        let teams = reviewers.filter { $0.contains("/") }
        let people = reviewers.filter { !$0.contains("/") }
        if reviewers.count == 1 { return reviewers[0] }
        if people.isEmpty { return "\(teams.count) teams" }
        if teams.isEmpty { return people.count == 2 ? "\(people[0]) and \(people[1])" : "\(people.count) people" }
        if people.count == 1 { return "\(people[0]) and \(Format.plural(teams.count, "team"))" }
        return "\(reviewers.count) reviewers"
    }
}

/// An AI reviewer's review/comment as one line ("Copilot reviewed · 4 comments"); expands to the full item inline.
private struct AIReviewRow: View {
    let item: TimelineItem
    let context: TimelineContext
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                CompactEventRow(symbol: "sparkles", tone: .neutral, date: item.createdAt, context: context) {
                    Text("\(Text(item.actor.displayName).fontWeight(.semibold).foregroundStyle(.primary)) \(summary) \(Image(systemName: expanded ? "chevron.up" : "chevron.down"))")
                } extra: {
                    if !expanded, let preview {
                        Text(preview)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded {
                TimelineItemView(item: item, context: context)
            }
        }
    }

    private var summary: String {
        switch item.payload {
        case .review(let state, _, let comments):
            let verb = switch state {
            case .approved: "approved"
            case .changesRequested: "requested changes"
            default: "reviewed"
            }
            return comments.isEmpty ? verb : "\(verb) · \(Format.plural(comments.count, "comment"))"
        default:
            return "commented"
        }
    }

    private var preview: String? {
        let text: String
        switch item.payload {
        case .review(_, let body, let comments): text = body.isEmpty ? comments.first?.body.plainText ?? "" : body.plainText
        case .comment(let body): text = body.plainText
        default: return nil
        }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? nil : line
    }
}

private struct ReviewLook {
    var verb: String
    var symbol: String
    var tone: Tone

    init(_ state: ReviewState) {
        switch state {
        case .approved: (verb, symbol, tone) = ("approved these changes", "checkmark", .success)
        case .changesRequested: (verb, symbol, tone) = ("requested changes", "xmark", .danger)
        case .commented: (verb, symbol, tone) = ("reviewed", "bubble.left.fill", .accent)
        case .dismissed: (verb, symbol, tone) = ("review dismissed", "minus", .neutral)
        case .pending: (verb, symbol, tone) = ("started a review", "ellipsis", .neutral)
        }
    }
}

// MARK: - Row shells

/// Avatar gutter + header + content, with the timeline rail behind the gutter.
struct FullEventRow<Head: View, Content: View>: View {
    @Environment(\.theme) private var theme
    var actor: Actor
    var date: Date
    var context: TimelineContext
    var badge: ActivityBadge?
    @ViewBuilder var head: Head
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(actor: actor, size: theme.eventAvatar, badge: badge, badgeRing: theme.isFluid ? .black : Color(nsColor: .windowBackgroundColor))
                .padding(.top, 8)
                .frame(width: 30)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(alignment: .center) { TimelineRail() }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(actor.login == context.viewer ? "You" : actor.displayName)
                        .fontWeight(.semibold)
                        .foregroundStyle(actor.login == context.viewer ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    head
                    Spacer(minLength: 6)
                    TimeStamp(date: date, now: context.now)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                content
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One-line event (CI, commits, state changes) with a small tinted icon in the gutter.
struct CompactEventRow<Line: View, Extra: View>: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var tone: Tone
    var date: Date
    var context: TimelineContext
    @ViewBuilder var line: Line
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(filled ? .white : tone.color(theme))
                .frame(width: 22, height: 22)
                .background(Circle().fill(filled ? tone.color(theme) : theme.isFluid ? Color(white: 0.09) : Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(theme.hairline, lineWidth: filled ? 0 : 0.5))
                .padding(.top, 6)
                .frame(width: 30)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(alignment: .center) { TimelineRail() }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    line.lineLimit(2)
                    Spacer(minLength: 6)
                    TimeStamp(date: date, now: context.now)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                extra
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var filled: Bool { tone == .danger || tone == .success || tone == .merged }
}

extension CompactEventRow where Extra == EmptyView {
    init(symbol: String, tone: Tone, date: Date, context: TimelineContext, @ViewBuilder line: () -> Line) {
        self.init(symbol: symbol, tone: tone, date: date, context: context, line: line, extra: { EmptyView() })
    }
}

private struct TimelineRail: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle().fill(theme.hairline).frame(width: 1)
    }
}

struct TimeStamp: View {
    var date: Date
    var now: Date

    var body: some View {
        Text(Format.stamp(date, now: now))
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
            .help(date.formatted(date: .complete, time: .shortened))
    }
}

private struct EventTag: View {
    @Environment(\.theme) private var theme
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.accent.opacity(0.12)))
            .fixedSize()
    }
}

private struct HighlightBox: View {
    var tone: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tone.opacity(0.08))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                    .fill(tone)
                    .frame(width: 2)
            }
    }
}

// MARK: - Review comments

/// A standalone review comment (or a reply in a review thread) as its own timeline row.
private struct ReviewCommentRow: View {
    let comment: ReviewComment
    let context: TimelineContext

    var body: some View {
        let parent = comment.replyToID.flatMap { context.reviewComments[$0] }
        FullEventRow(actor: comment.author, date: comment.createdAt, context: context) {
            Text(parent == nil ? "on" : "replied on")
            FileChip(path: comment.path)
        } content: {
            ReviewCommentBody(comment: comment, parent: parent, context: context)
        }
    }
}

/// A review comment nested under a review header.
private struct ReviewCommentBlock: View {
    let comment: ReviewComment
    let context: TimelineContext
    var showsAuthor: Bool

    var body: some View {
        let parent = comment.replyToID.flatMap { context.reviewComments[$0] }
        VStack(alignment: .leading, spacing: 4) {
            if showsAuthor || parent != nil {
                HStack(spacing: 5) {
                    if showsAuthor { Text(comment.author.displayName).fontWeight(.semibold).foregroundStyle(.primary) }
                    Text(parent == nil ? "on" : "replied on")
                    FileChip(path: comment.path)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            ReviewCommentBody(comment: comment, parent: parent, context: context)
        }
    }
}

private struct ReviewCommentBody: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    let comment: ReviewComment
    let parent: ReviewComment?
    let context: TimelineContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let parent {
                HStack(spacing: 6) {
                    AvatarView(actor: parent.author, size: 16)
                    Text(parent.body.plainText.split(whereSeparator: \.isWhitespace).joined(separator: " ")).lineLimit(1)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.chipBackground))
            } else {
                DiffHunkView(comment: comment)
            }
            RichBodyView(source: comment.body)
            Button {
                model.replyTargets[context.group.id] = context.root(of: comment)
                model.requestComposerFocus()
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reply in thread to \(comment.author.displayName)")
        }
    }
}

private struct FileChip: View {
    @Environment(\.theme) private var theme
    var path: String

    var body: some View {
        Text(Format.basename(path))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.chipBackground))
            .frame(maxWidth: 200, alignment: .leading)
            .fixedSize()
            .help(path)
    }
}

// MARK: - Compact rows

private struct ChecksRow: View {
    @Environment(\.theme) private var theme
    let summary: CheckSummary
    let date: Date
    let context: TimelineContext

    var body: some View {
        let sha = String(summary.commitSHA.prefix(7))
        switch summary.status {
        case .failure:
            CompactEventRow(symbol: "xmark", tone: .danger, date: date, context: context) {
                Text("\(Text("\(Format.plural(summary.failedChecks.count, "check")) failed").fontWeight(.semibold).foregroundStyle(.primary)) on \(Text(sha).font(.system(size: 11, design: .monospaced)))")
            } extra: {
                FlowLayout(spacing: 4) {
                    ForEach(summary.failedChecks, id: \.self) { name in
                        CheckChip(text: name, symbol: "xmark", tone: .danger)
                    }
                    if summary.passedCount > 0 {
                        CheckChip(text: "\(summary.passedCount) passed", symbol: "checkmark", tone: .success)
                    }
                }
            }
        case .success:
            CompactEventRow(symbol: "checkmark", tone: .success, date: date, context: context) {
                Text("All checks passed \(Text("· \(Format.plural(summary.passedCount, "check")) on").foregroundStyle(.tertiary)) \(Text(sha).font(.system(size: 11, design: .monospaced)))")
            }
        case .pending:
            CompactEventRow(symbol: "clock", tone: .warn, date: date, context: context) {
                Text("Checks running on \(Text(sha).font(.system(size: 11, design: .monospaced))) \(Text("· \(summary.pendingCount) pending").foregroundStyle(.tertiary))")
            }
        case .neutral:
            CompactEventRow(symbol: "minus", tone: .neutral, date: date, context: context) {
                Text("Checks completed on \(Text(sha).font(.system(size: 11, design: .monospaced)))")
            }
        }
    }
}

private struct CheckChip: View {
    @Environment(\.theme) private var theme
    var text: String
    var symbol: String
    var tone: Tone

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
        }
        .foregroundStyle(tone.color(theme))
        .padding(.horizontal, 6)
        .frame(height: 19)
        .background(RoundedRectangle(cornerRadius: 5).fill(tone == .danger ? tone.color(theme).opacity(0.1) : theme.chipBackground))
    }
}

private struct EventRow: View {
    let kind: TimelineEventKind
    let detail: String?
    let item: TimelineItem
    let context: TimelineContext

    var body: some View {
        let name = Format.firstName(item.actor, viewer: context.viewer)
        let look = look(name: name)
        CompactEventRow(symbol: look.symbol, tone: look.tone, date: item.createdAt, context: context) {
            Text("\(Text(name).fontWeight(.semibold).foregroundStyle(.primary)) \(look.text)")
        }
    }

    private func look(name: String) -> (symbol: String, tone: Tone, text: String) {
        let target = detail.flatMap { $0.isEmpty ? nil : $0 }
        switch kind {
        case .closed:
            return (context.group.thread.kind == .issue ? "checkmark.circle" : "xmark", .merged, "closed this")
        case .reopened: return ("arrow.clockwise", .success, "reopened this")
        case .merged: return ("arrow.triangle.merge", .merged, "merged this pull request")
        case .reviewRequested:
            if target == nil || target == context.viewer { return ("eye", .warn, "requested your review") }
            return ("eye", .warn, "requested review from \(target!)")
        case .readyForReview: return ("eye", .success, "marked this ready for review")
        case .convertedToDraft: return ("pencil", .neutral, "converted this to a draft")
        case .assigned:
            if target == nil || target == context.viewer { return ("person", .neutral, "assigned you") }
            return ("person", .neutral, "assigned \(target!)")
        case .headRefForcePushed: return ("arrow.up.circle", .neutral, "force-pushed\(target.map { " \($0)" } ?? "")")
        }
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
