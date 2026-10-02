import Foundation

public enum InboxBucket: String, Sendable, CaseIterable {
    /// Unseen activity (counts toward the notch badge).
    case new
    /// Seen but not done. Shown separately from the unseen count.
    case pending
    case snoozed
    case done
}

/// Why a group came back to attention; drives the "Back in inbox" / "Snooze ended" tags.
public enum ResurfaceReason: String, Codable, Sendable {
    case reopenedFromDone
    case snoozeEnded
}

/// One PR/issue with all of its activity. Seen and done are independent:
/// opening marks seen (GitHub read) but never done.
public struct InboxGroup: Identifiable, Hashable, Sendable {
    public var id: ThreadID { thread.id }
    public var thread: NotificationThread
    public var state: SubjectState
    /// Newest activity not authored by the viewer (falls back to newest overall).
    public var preview: ActivityPreview?
    /// Most recent distinct non-viewer participants, newest last, at most 3.
    public var actors: [Actor]
    /// Unseen means GitHub `unread` (kept optimistic locally after marking read).
    public var isUnseen: Bool
    /// Items by others newer than `lastVisitAt` (0 if never hydrated; UI shows a dot then).
    public var unseenCount: Int
    /// When the user last opened the conversation; drives the "since your last visit" divider.
    public var lastVisitAt: Date?
    public var doneAt: Date?
    public var snoozedUntil: Date?
    public var resurfaced: ResurfaceReason?

    public init(
        thread: NotificationThread, state: SubjectState, preview: ActivityPreview?, actors: [Actor], isUnseen: Bool,
        unseenCount: Int, lastVisitAt: Date?, doneAt: Date?, snoozedUntil: Date?, resurfaced: ResurfaceReason?
    ) {
        self.thread = thread
        self.state = state
        self.preview = preview
        self.actors = actors
        self.isUnseen = isUnseen
        self.unseenCount = unseenCount
        self.lastVisitAt = lastVisitAt
        self.doneAt = doneAt
        self.snoozedUntil = snoozedUntil
        self.resurfaced = resurfaced
    }

    public func bucket(at now: Date) -> InboxBucket {
        if doneAt != nil { return .done }
        if let until = snoozedUntil, until > now { return .snoozed }
        return isUnseen ? .new : .pending
    }

    public var lastActivityAt: Date { preview?.at ?? thread.updatedAt }
}

/// What the notch announces. Same-group events merge into the current arrival (stable `id`, rising `updateCount`)
/// instead of restarting the animation.
public struct Arrival: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case activity(groupID: ThreadID, latest: ActivityPreview, reopened: Bool)
        case snoozeEnded(groupID: ThreadID)
        /// Shown when global snooze / quiet mode / quiet hours end and activity was collected meanwhile.
        case summary(updates: Int, groups: Int, actors: [Actor], endedReason: QuietReason)
        /// Replaces `.summary` when scheduled quiet hours end: overnight activity by repo plus PR Shelf changes.
        case morningSummary(MorningSummary)
    }

    public let id: UUID
    public var kind: Kind
    /// Number of merged events (1 for a fresh arrival).
    public var updateCount: Int
    /// Distinct actors across merged events, newest last, at most 3.
    public var actors: [Actor]

    public init(id: UUID = UUID(), kind: Kind, updateCount: Int, actors: [Actor]) {
        self.id = id
        self.kind = kind
        self.updateCount = updateCount
        self.actors = actors
    }

    public var groupID: ThreadID? {
        switch kind {
        case .activity(let id, _, _), .snoozeEnded(let id): id
        case .summary, .morningSummary: nil
        }
    }
}

/// "Overnight: N updates in M conversations", grouped by repository, plus what changed on the PR Shelf.
public struct MorningSummary: Equatable, Sendable {
    public struct RepoUpdates: Equatable, Sendable {
        public let repo: RepoRef
        public let updates: Int
        public init(repo: RepoRef, updates: Int) {
            self.repo = repo
            self.updates = updates
        }
    }

    public static let maxRepos = 3

    public let updates: Int
    public let conversations: Int
    /// Busiest repositories first, at most `maxRepos`.
    public let topRepos: [RepoUpdates]
    /// PR Shelf changes overnight, e.g. "#142 is ready to merge".
    public let shelfChanges: [String]
    public let actors: [Actor]

    public init(updates: Int, conversations: Int, topRepos: [RepoUpdates], shelfChanges: [String], actors: [Actor]) {
        self.updates = updates
        self.conversations = conversations
        self.topRepos = topRepos
        self.shelfChanges = shelfChanges
        self.actors = actors
    }

    public var isEmpty: Bool { updates == 0 && shelfChanges.isEmpty }
}

public struct ConversationState: Equatable, Sendable {
    public var detail: ThreadDetail?
    /// Visit boundary captured when the conversation was opened (the previous `lastVisitAt`).
    /// Items newer than this render below the "since your last visit" divider; nil = first visit (show all).
    public var lastVisitAt: Date?
    public var isLoading: Bool
    public var error: GitHubError?

    public init(detail: ThreadDetail? = nil, lastVisitAt: Date? = nil, isLoading: Bool = false, error: GitHubError? = nil) {
        self.detail = detail
        self.lastVisitAt = lastVisitAt
        self.isLoading = isLoading
        self.error = error
    }
}

public enum StorePhase: Equatable, Sendable {
    case starting
    case ready(viewer: Actor)
    /// Blocking state: gh missing / logged out / token rejected. UI shows `AuthError.instructions` + Retry.
    case blocked(AuthError)
}
