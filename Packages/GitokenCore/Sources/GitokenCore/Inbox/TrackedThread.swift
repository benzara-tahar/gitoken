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

    init(thread: NotificationThread) { self.thread = thread }

    var id: ThreadID { thread.id }

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

    mutating func absorb(_ detail: ThreadDetail, viewer: Actor) {
        preview = ActivityAnalysis.preview(of: detail, viewer: viewer) ?? .generic(at: thread.updatedAt)
        actors = ActivityAnalysis.actors(in: detail, viewer: viewer)
        unseenCount = ActivityAnalysis.items(in: detail, byOthersThan: viewer, after: lastVisitAt ?? thread.lastReadAt).count
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