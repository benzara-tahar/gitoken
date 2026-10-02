import Foundation

/// Derives inbox row data (preview line, participants, unseen count) from a hydrated timeline.
enum ActivityAnalysis {
    static let maxActors = 3
    static let maxSnippetLength = 200

    static func isViewer(_ actor: Actor, _ viewer: Actor) -> Bool {
        actor.login.caseInsensitiveCompare(viewer.login) == .orderedSame
    }

    /// Newest item not authored by the viewer, falling back to the newest item overall. Items are oldest first.
    static func preview(of detail: ThreadDetail, viewer: Actor) -> ActivityPreview? {
        guard let item = detail.items.last(where: { !isViewer($0.actor, viewer) }) ?? detail.items.last else { return nil }
        return preview(of: item, viewer: viewer)
    }

    static func preview(of item: TimelineItem, viewer: Actor) -> ActivityPreview {
        let (verb, snippet) = describe(item.payload, viewer: viewer)
        return ActivityPreview(actor: item.actor, verb: verb, snippet: snippet.flatMap(Self.snippet), at: item.createdAt)
    }

    /// Most recent distinct non-viewer, non-bot participants, newest last.
    static func actors(in detail: ThreadDetail, viewer: Actor) -> [Actor] {
        [Actor]().merging(detail.items.map(\.actor).filter { !$0.isBot && !isViewer($0, viewer) })
    }

    /// Items by anyone but the viewer created strictly after `boundary` (all of them when `boundary` is nil).
    static func items(in detail: ThreadDetail, byOthersThan viewer: Actor, after boundary: Date?) -> [TimelineItem] {
        detail.items.filter { item in
            !isViewer(item.actor, viewer) && boundary.map { item.createdAt > $0 } ?? true
        }
    }

    /// `@login` as a whole handle: not part of an email address or a longer handle.
    static func mentions(_ viewer: Actor, in text: String) -> Bool {
        let handle = "@" + viewer.login
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: handle, options: .caseInsensitive, range: searchRange) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            if !isHandleCharacter(before), !isHandleCharacter(after) { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    /// Single line, whitespace collapsed, truncated with an ellipsis. Nil when empty.
    static func snippet(_ text: String) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxSnippetLength else { return collapsed }
        return collapsed.prefix(maxSnippetLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func isHandleCharacter(_ c: Character?) -> Bool {
        guard let c else { return false }
        return c.isLetter || c.isNumber || c == "-" || c == "_"
    }

    private static func describe(_ payload: TimelinePayload, viewer: Actor) -> (ActivityVerb, String?) {
        switch payload {
        case .comment(let body):
            return (mentions(viewer, in: body) ? .mentioned : .commented, body)
        case .review(let state, let body, let comments):
            let text = body.isEmpty ? comments.first?.body : body
            switch state {
            case .approved: return (.approved, text)
            case .changesRequested: return (.requestedChanges, text)
            case .commented, .dismissed, .pending:
                let mentioned = mentions(viewer, in: body) || comments.contains { mentions(viewer, in: $0.body) }
                return (mentioned ? .mentioned : .reviewed, text)
            }
        case .commits(let count, let headlines):
            return (.pushed, count > 1 ? "\(count) commits" : headlines.last)
        case .checks(let summary):
            switch summary.status {
            case .failure: return (.checksFailed, summary.failedChecks.joined(separator: ", "))
            case .success: return (.checksPassed, nil)
            case .pending, .neutral: return (.updated, nil)
            }
        case .event(let kind, let detail):
            switch kind {
            case .opened: return (.opened, detail)
            case .closed: return (.closed, detail)
            case .reopened: return (.reopened, detail)
            case .merged: return (.merged, detail)
            case .reviewRequested:
                // `detail` is the requested reviewer; "requested your review" only holds when that's the viewer.
                guard let reviewer = detail, reviewer.caseInsensitiveCompare(viewer.login) != .orderedSame else {
                    return (.reviewRequested, nil)
                }
                return (.updated, "Requested review from \(reviewer)")
            case .headRefForcePushed: return (.pushed, detail ?? "Force-pushed")
            case .readyForReview: return (.updated, detail ?? "Ready for review")
            case .convertedToDraft: return (.updated, detail ?? "Converted to draft")
            case .assigned: return (.updated, detail ?? "Assigned")
            }
        }
    }
}

extension [Actor] {
    /// Appends `newer` (oldest first), keeping each login once at its most recent position and the newest `limit`.
    func merging(_ newer: [Actor], limit: Int = ActivityAnalysis.maxActors) -> [Actor] {
        var result = self
        for actor in newer {
            result.removeAll { $0.login.caseInsensitiveCompare(actor.login) == .orderedSame }
            result.append(actor)
        }
        return Array(result.suffix(limit))
    }
}
