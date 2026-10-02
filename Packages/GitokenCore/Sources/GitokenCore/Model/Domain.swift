import Foundation

// MARK: - Identity

/// GitHub notification thread id (`/notifications/threads/{id}`). One thread per subject (PR/issue) per user,
/// so a thread is the unit Gitoken groups activity under.
public struct ThreadID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Account scope for every persisted row. v1 ships a single github.com account, but storage is keyed by account.
public struct AccountKey: Hashable, Codable, Sendable {
    public let host: String
    public let login: String
    public init(host: String = "github.com", login: String) {
        self.host = host
        self.login = login
    }
}

public struct RepoRef: Hashable, Codable, Sendable {
    public let owner: String
    public let name: String
    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }
    public var fullName: String { "\(owner)/\(name)" }
}

public struct Actor: Hashable, Codable, Sendable {
    public let login: String
    public let name: String?
    public let avatarURL: URL?
    public let isBot: Bool
    public init(login: String, name: String? = nil, avatarURL: URL? = nil, isBot: Bool = false) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
        self.isBot = isBot
    }
    public var displayName: String { name?.isEmpty == false ? name! : login }
    /// Up to two initials, used for the initials-avatar fallback while images load or when none exists.
    public var initials: String {
        let words = displayName.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

// MARK: - Notification threads (REST /notifications)

public enum SubjectKind: String, Codable, Sendable {
    case pullRequest = "PullRequest"
    case issue = "Issue"
    case discussion = "Discussion"
    case release = "Release"
    case commit = "Commit"
    case checkSuite = "CheckSuite"
    case other

    public init(apiValue: String) { self = SubjectKind(rawValue: apiValue) ?? .other }
}

/// GitHub's notification `reason`. Unknown values decode to `.other`.
public enum NotificationReason: String, Codable, Sendable, CaseIterable {
    case reviewRequested = "review_requested"
    case mention
    case teamMention = "team_mention"
    case author
    case comment
    case assign
    case stateChange = "state_change"
    case manual
    case subscribed
    case ciActivity = "ci_activity"
    case securityAlert = "security_alert"
    case invitation
    case approvalRequested = "approval_requested"
    case other

    public init(apiValue: String) { self = NotificationReason(rawValue: apiValue) ?? .other }

    /// v1 inbox scope: review requests, mentions, the user's own PRs/issues, and threads they participate in.
    public var isInInboxScope: Bool {
        switch self {
        case .reviewRequested, .mention, .teamMention, .author, .comment, .assign, .stateChange, .manual, .ciActivity:
            return true
        case .subscribed, .securityAlert, .invitation, .approvalRequested, .other:
            return false
        }
    }
}

public enum SubjectState: String, Codable, Sendable {
    case open, closed, merged, draft, unknown
}

/// One row of `GET /notifications`, normalized.
public struct NotificationThread: Hashable, Codable, Sendable, Identifiable {
    public let id: ThreadID
    public let repo: RepoRef
    public let kind: SubjectKind
    /// PR/issue number parsed from `subject.url`; nil for subjects without one.
    public let number: Int?
    public let title: String
    public let reason: NotificationReason
    public let unread: Bool
    public let updatedAt: Date
    public let lastReadAt: Date?
    /// API URL of the subject (`subject.url`).
    public let subjectAPIURL: URL?
    /// API URL of the latest comment (`subject.latest_comment_url`).
    public let latestCommentAPIURL: URL?
    public let repoOwnerAvatarURL: URL?

    public init(
        id: ThreadID, repo: RepoRef, kind: SubjectKind, number: Int?, title: String, reason: NotificationReason,
        unread: Bool, updatedAt: Date, lastReadAt: Date?, subjectAPIURL: URL?, latestCommentAPIURL: URL?,
        repoOwnerAvatarURL: URL?
    ) {
        self.id = id
        self.repo = repo
        self.kind = kind
        self.number = number
        self.title = title
        self.reason = reason
        self.unread = unread
        self.updatedAt = updatedAt
        self.lastReadAt = lastReadAt
        self.subjectAPIURL = subjectAPIURL
        self.latestCommentAPIURL = latestCommentAPIURL
        self.repoOwnerAvatarURL = repoOwnerAvatarURL
    }

    /// Browser URL for "Open on GitHub".
    public var htmlURL: URL {
        let base = "https://github.com/\(repo.fullName)"
        switch (kind, number) {
        case (.pullRequest, let n?): return URL(string: "\(base)/pull/\(n)")!
        case (.issue, let n?): return URL(string: "\(base)/issues/\(n)")!
        case (.discussion, let n?): return URL(string: "\(base)/discussions/\(n)")!
        default: return URL(string: base)!
        }
    }
}

public enum NotificationPoll: Sendable, Equatable {
    /// 304: nothing changed since `Last-Modified`. Not counted against the rate limit.
    case notModified(pollInterval: TimeInterval)
    /// Full listing (all pages, `all=true`) of threads GitHub still considers not-done.
    case updated(threads: [NotificationThread], lastModified: String?, pollInterval: TimeInterval)
}

// MARK: - Conversation (GraphQL hydration)

public enum ReviewState: String, Codable, Sendable {
    case approved, changesRequested, commented, dismissed, pending
}

public enum CheckStatus: String, Codable, Sendable {
    case pending, success, failure, neutral
}

public struct CheckSummary: Hashable, Codable, Sendable {
    public let status: CheckStatus
    public let commitSHA: String
    public let failedChecks: [String]
    public let passedCount: Int
    public let pendingCount: Int
    public init(status: CheckStatus, commitSHA: String, failedChecks: [String], passedCount: Int, pendingCount: Int) {
        self.status = status
        self.commitSHA = commitSHA
        self.failedChecks = failedChecks
        self.passedCount = passedCount
        self.pendingCount = pendingCount
    }
}

/// A review comment anchored to code.
public struct ReviewComment: Hashable, Codable, Sendable, Identifiable {
    /// GraphQL node id.
    public let id: String
    /// REST id, needed for `POST /pulls/{n}/comments/{id}/replies`.
    public let databaseID: Int
    public let author: Actor
    public let body: String
    public let createdAt: Date
    public let path: String
    /// Unified diff hunk ending at the commented line (GitHub `diffHunk`).
    public let diffHunk: String
    public let line: Int?
    /// Node id of the comment this one replies to, when threaded.
    public let replyToID: String?
    public let url: URL?
    public init(
        id: String, databaseID: Int, author: Actor, body: String, createdAt: Date, path: String, diffHunk: String,
        line: Int?, replyToID: String?, url: URL?
    ) {
        self.id = id
        self.databaseID = databaseID
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.path = path
        self.diffHunk = diffHunk
        self.line = line
        self.replyToID = replyToID
        self.url = url
    }
}

public enum TimelineEventKind: String, Codable, Sendable {
    case opened, closed, reopened, merged, reviewRequested, readyForReview, convertedToDraft, assigned, headRefForcePushed
}

public enum TimelinePayload: Hashable, Codable, Sendable {
    case comment(body: String)
    case review(state: ReviewState, body: String, comments: [ReviewComment])
    case commits(count: Int, headlines: [String])
    case checks(CheckSummary)
    case event(TimelineEventKind, detail: String?)
}

public struct TimelineItem: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let actor: Actor
    public let createdAt: Date
    public let payload: TimelinePayload
    public let url: URL?
    public init(id: String, actor: Actor, createdAt: Date, payload: TimelinePayload, url: URL?) {
        self.id = id
        self.actor = actor
        self.createdAt = createdAt
        self.payload = payload
        self.url = url
    }
}

public struct ThreadDetail: Hashable, Codable, Sendable {
    public let threadID: ThreadID
    public let title: String
    public let state: SubjectState
    public let author: Actor?
    public let htmlURL: URL
    /// Oldest first. Limited to the most recent items GitHub returns (see client); enough for "since last visit" + context.
    public let items: [TimelineItem]
    public let checks: CheckSummary?
    public let fetchedAt: Date
    public init(
        threadID: ThreadID, title: String, state: SubjectState, author: Actor?, htmlURL: URL, items: [TimelineItem],
        checks: CheckSummary?, fetchedAt: Date
    ) {
        self.threadID = threadID
        self.title = title
        self.state = state
        self.author = author
        self.htmlURL = htmlURL
        self.items = items
        self.checks = checks
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Activity preview (arrival banner + inbox row line)

public enum ActivityVerb: String, Codable, Sendable {
    case commented, mentioned, approved, requestedChanges, reviewed, reviewRequested, pushed, checksFailed, checksPassed
    case opened, closed, reopened, merged, updated
}

/// "Sarah requested changes" + snippet. Built from the newest timeline item not authored by the viewer.
public struct ActivityPreview: Hashable, Codable, Sendable {
    public let actor: Actor?
    public let verb: ActivityVerb
    public let snippet: String?
    public let at: Date
    public init(actor: Actor?, verb: ActivityVerb, snippet: String?, at: Date) {
        self.actor = actor
        self.verb = verb
        self.snippet = snippet
        self.at = at
    }
}
