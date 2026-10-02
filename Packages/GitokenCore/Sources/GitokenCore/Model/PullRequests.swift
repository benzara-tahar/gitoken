import Foundation

public struct PullRequestRef: Hashable, Codable, Sendable {
    public let repo: RepoRef
    public let number: Int

    public init(repo: RepoRef, number: Int) {
        self.repo = repo
        self.number = number
    }

    /// Accepts `https://github.com/<owner>/<repo>/pull/<n>` (trailing segments like `/files` and fragments allowed).
    public init?(url: URL) {
        guard url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let n = Int(parts[3]), n > 0 else { return nil }
        self.init(repo: RepoRef(owner: parts[0], name: parts[1]), number: n)
    }

    public var htmlURL: URL { URL(string: "https://github.com/\(repo.fullName)/pull/\(number)")! }
}

public enum ReviewDecision: String, Codable, Sendable {
    case approved, changesRequested, reviewRequired, none
}

public enum MergeableState: String, Codable, Sendable {
    case mergeable, conflicting, unknown
}

public enum MergeMethod: String, Codable, Sendable, CaseIterable {
    case merge, squash, rebase
}

/// Live state of one pull request on the PR Shelf.
public struct PullRequestStatus: Hashable, Codable, Sendable, Identifiable {
    public var id: PullRequestRef { ref }
    public let nodeID: String
    public let ref: PullRequestRef
    public let title: String
    public let author: Actor
    public let state: SubjectState
    public let isDraft: Bool
    public let headRefName: String
    public let headRefOID: String
    public let baseRefName: String
    /// Head lives in a fork; worktree checkout must go through `gh pr checkout`.
    public let isCrossRepository: Bool
    public let checks: CheckSummary?
    public let reviewDecision: ReviewDecision
    public let mergeable: MergeableState
    public let unresolvedThreadCount: Int
    /// Newest comment/review by a human other than the viewer.
    public let latestHumanActivity: ActivityPreview?
    public let updatedAt: Date
    public let viewerCanMerge: Bool
    /// Methods enabled on the repository, in GitHub's preference order.
    public let allowedMergeMethods: [MergeMethod]

    public init(
        nodeID: String, ref: PullRequestRef, title: String, author: Actor, state: SubjectState, isDraft: Bool,
        headRefName: String, headRefOID: String, baseRefName: String, isCrossRepository: Bool, checks: CheckSummary?,
        reviewDecision: ReviewDecision, mergeable: MergeableState, unresolvedThreadCount: Int,
        latestHumanActivity: ActivityPreview?, updatedAt: Date, viewerCanMerge: Bool, allowedMergeMethods: [MergeMethod]
    ) {
        self.nodeID = nodeID
        self.ref = ref
        self.title = title
        self.author = author
        self.state = state
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.headRefOID = headRefOID
        self.baseRefName = baseRefName
        self.isCrossRepository = isCrossRepository
        self.checks = checks
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.unresolvedThreadCount = unresolvedThreadCount
        self.latestHumanActivity = latestHumanActivity
        self.updatedAt = updatedAt
        self.viewerCanMerge = viewerCanMerge
        self.allowedMergeMethods = allowedMergeMethods
    }

    /// Approved, green, no conflicts, not a draft, still open.
    public var isReadyToMerge: Bool {
        state == .open && !isDraft && reviewDecision == .approved && mergeable == .mergeable && checks?.status == .success
    }
}

/// GitHub access for the PR Shelf. Implemented by `GitHubClient` and `FixtureGitHubService`.
public protocol PullRequestService: Sendable {
    /// GraphQL `search(query: "is:pr is:open author:@me archived:false")`, newest update first.
    func myOpenPullRequests() async throws(GitHubError) -> [PullRequestStatus]
    /// Status for explicitly pinned PRs (any author). Missing/inaccessible refs are omitted.
    func pullRequests(_ refs: [PullRequestRef]) async throws(GitHubError) -> [PullRequestStatus]
    /// `PUT /repos/{owner}/{repo}/pulls/{n}/merge` guarded by `sha = headRefOID`.
    func merge(_ pr: PullRequestStatus, method: MergeMethod) async throws(GitHubError)
    /// Markdown context for pasting into an AI coding agent: PR summary, unresolved review threads with diff hunks,
    /// failing check names with log tails.
    func agentContext(for ref: PullRequestRef) async throws(GitHubError) -> String
}

/// Emoji reactions supported by GitHub's `addReaction` mutation.
public enum ReactionContent: String, Codable, Sendable, CaseIterable {
    case thumbsUp = "THUMBS_UP", hooray = "HOORAY", eyes = "EYES", heart = "HEART", rocket = "ROCKET", confused = "CONFUSED"

    public var emoji: String {
        switch self {
        case .thumbsUp: "👍"
        case .hooray: "🎉"
        case .eyes: "👀"
        case .heart: "❤️"
        case .rocket: "🚀"
        case .confused: "😕"
        }
    }
}

/// One emoji's tally on a PR/issue body, comment, review, or review comment.
public struct ReactionCount: Hashable, Codable, Sendable {
    public let content: ReactionContent
    public let count: Int
    public let viewerHasReacted: Bool

    public init(content: ReactionContent, count: Int, viewerHasReacted: Bool) {
        self.content = content
        self.count = count
        self.viewerHasReacted = viewerHasReacted
    }
}

extension [ReactionCount] {
    /// The viewer's reaction added once: the tally grows unless the viewer already reacted with `content`.
    /// Order follows `ReactionContent.allCases` so chips don't jump around.
    public func adding(_ content: ReactionContent) -> [ReactionCount] {
        var byContent = Dictionary(map { ($0.content, $0) }, uniquingKeysWith: { first, _ in first })
        if let existing = byContent[content] {
            guard !existing.viewerHasReacted else { return self }
            byContent[content] = ReactionCount(content: content, count: existing.count + 1, viewerHasReacted: true)
        } else {
            byContent[content] = ReactionCount(content: content, count: 1, viewerHasReacted: true)
        }
        return ReactionContent.allCases.compactMap { byContent[$0] }
    }
}
