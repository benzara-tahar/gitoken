import Foundation

/// One persisted inbox row: GitHub's latest view of the thread plus everything Gitoken tracks locally.
struct TrackedThread: Equatable, Sendable {
    var thread: NotificationThread
    var state: SubjectState = .unknown
    var preview: ActivityPreview?
    var actors: [Actor] = []
    var unseenCount = 0
    /// Newest activity (thread `updatedAt` / timeline item date) the user has seen in Gitoken. Keeps the
    /// optimistic "seen" while GitHub still reports `unread` (mark-read failed or the listing lags).
    /// Compared against GitHub timestamps only, so local clock skew cannot hide new activity.
    var seenThrough: Date?
    var lastVisitAt: Date?
    var doneAt: Date?
    var snoozedUntil: Date?
    var resurfaced: ResurfaceReason?
    /// `thread.updatedAt` of the version last hydrated (successfully or not); nil = never hydrated.
    var hydratedThrough: Date?
    /// Un-done locally while GitHub still considers it done, so absence from the listing must not re-done it.
    /// Cleared as soon as the thread is listed again.
    var keptLocally = false
    /// What hydrated timelines showed about the viewer's role. Only grows: timelines are capped to recent items, so an
    /// older review or mention must not be forgotten once it scrolls out.
    var learnedInvolvement: Involvement = []

    init(thread: NotificationThread) { self.thread = thread }

    var id: ThreadID { thread.id }

    var involvement: Involvement { learnedInvolvement.union(Involvement(reason: thread.reason)) }

    var isUnseen: Bool {
        guard thread.unread else { return false }
        if let seenThrough, thread.updatedAt <= seenThrough { return false }
        return true
    }

    var needsHydration: Bool { hydratedThrough.map { $0 < thread.updatedAt } ?? true }

    func isSnoozed(at now: Date) -> Bool { snoozedUntil.map { $0 > now } ?? false }

    mutating func markSeen(through date: Date) {
        seenThrough = max(seenThrough ?? date, date)
    }

    /// `includeAI` false leaves AI reviewers out of the preview, participants and unseen count.
    mutating func absorb(_ detail: ThreadDetail, viewer: Actor, includeAI: Bool) {
        preview = ActivityAnalysis.preview(of: detail, viewer: viewer, includeAI: includeAI) ?? .generic(at: thread.updatedAt)
        actors = ActivityAnalysis.actors(in: detail, viewer: viewer, includeAI: includeAI)
        unseenCount = ActivityAnalysis.items(
            in: detail, byOthersThan: viewer, after: lastVisitAt ?? thread.lastReadAt, includeAI: includeAI
        ).count
        learnedInvolvement.formUnion(ActivityAnalysis.involvement(in: detail, viewer: viewer))
        state = detail.state
        hydratedThrough = thread.updatedAt
    }

    mutating func absorbHydrationFailure() {
        preview = .generic(at: thread.updatedAt)
        hydratedThrough = thread.updatedAt
    }

    var group: InboxGroup {
        InboxGroup(
            thread: thread, state: state, preview: preview, actors: actors, isUnseen: isUnseen,
            unseenCount: unseenCount, lastVisitAt: lastVisitAt, doneAt: doneAt, snoozedUntil: snoozedUntil,
            resurfaced: resurfaced)
    }
}

/// How the viewer relates to a thread, for the "only my work" scope.
struct Involvement: OptionSet, Hashable, Sendable {
    let rawValue: Int
    /// The viewer opened the PR/issue.
    static let author = Involvement(rawValue: 1 << 0)
    /// The viewer reviewed, commented on, closed or merged it.
    static let participant = Involvement(rawValue: 1 << 1)
    /// Someone else @-mentioned the viewer in it.
    static let mentioned = Involvement(rawValue: 1 << 2)
    /// The viewer's own work; any other involvement comes from mentions alone.
    static let ownWork: Involvement = [.author, .participant]

    init(rawValue: Int) { self.rawValue = rawValue }

    /// GitHub keeps one reason per thread and may leave a reviewed PR at `review_requested`, hence the timeline check.
    init(reason: NotificationReason) {
        switch reason {
        case .author: self = .author
        case .comment, .stateChange: self = .participant
        case .mention: self = .mentioned
        default: self = []
        }
    }
}

extension ActivityPreview {
    /// Used when a thread changed but its timeline could not be hydrated.
    static func generic(at date: Date) -> ActivityPreview {
        ActivityPreview(actor: nil, verb: .updated, snippet: nil, at: date)
    }
}


extension SubjectKind {
    /// Subjects with a GraphQL timeline; others (releases, commits, check suites) only get a generic preview.
    var hasTimeline: Bool {
        switch self {
        case .pullRequest, .issue, .discussion: true
        case .release, .commit, .checkSuite, .other: false
        }
    }
}