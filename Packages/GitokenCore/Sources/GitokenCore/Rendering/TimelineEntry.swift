import Foundation

/// Consecutive review requests by one actor, e.g. a PR author adding three teams at once.
public struct ReviewRequestGroup: Hashable, Sendable {
    public let actor: Actor
    /// Requested logins / `org/team` slugs, in request order without duplicates.
    public let reviewers: [String]
    /// Oldest first; never empty.
    public let items: [TimelineItem]

    public var id: String { items[0].id }
    public var createdAt: Date { items[items.count - 1].createdAt }

    public func includes(_ login: String?) -> Bool {
        guard let login else { return false }
        return reviewers.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }
}

/// A row in the conversation timeline.
public enum TimelineEntry: Hashable, Sendable, Identifiable {
    case item(TimelineItem)
    case reviewRequests(ReviewRequestGroup)
    /// An AI reviewer's review or comment shown as one compact, expandable row.
    case aiReview(TimelineItem)

    public var id: String {
        switch self {
        case .item(let item), .aiReview(let item): item.id
        case .reviewRequests(let group): group.id
        }
    }

    public var itemIDs: [String] {
        switch self {
        case .item(let item), .aiReview(let item): [item.id]
        case .reviewRequests(let group): group.items.map(\.id)
        }
    }

    /// Review requests closer together than this (and by the same actor, uninterrupted) collapse into one row.
    public static let reviewRequestWindow: TimeInterval = 5 * 60

    public static func entries(
        for items: [TimelineItem], collapseAI: Bool = false, window: TimeInterval = reviewRequestWindow
    ) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        var run: [TimelineItem] = []

        func flush() {
            defer { run = [] }
            guard let first = run.first else { return }
            guard run.count > 1 else {
                entries.append(.item(first))
                return
            }
            var reviewers: [String] = []
            for item in run {
                guard case .event(_, let detail) = item.payload, let detail, !detail.isEmpty,
                      !reviewers.contains(where: { $0.caseInsensitiveCompare(detail) == .orderedSame })
                else { continue }
                reviewers.append(detail)
            }
            entries.append(.reviewRequests(ReviewRequestGroup(actor: first.actor, reviewers: reviewers, items: run)))
        }

        for item in items {
            guard case .event(.reviewRequested, _) = item.payload else {
                flush()
                entries.append(collapseAI && AIReviewers.isAIActivity(item) ? .aiReview(item) : .item(item))
                continue
            }
            if let last = run.last,
               last.actor.login.caseInsensitiveCompare(item.actor.login) != .orderedSame
                || item.createdAt.timeIntervalSince(last.createdAt) > window
            {
                flush()
            }
            run.append(item)
        }
        flush()
        return entries
    }
}
