import Foundation

public enum DiffSide: String, Codable, Sendable { case left, right }

/// One PullRequestReviewThread with its comments, oldest first.
public struct ReviewThread: Hashable, Sendable, Identifiable {
    /// Thread node id (resolve/unresolve).
    public let id: String
    public var isResolved: Bool
    public let isOutdated: Bool
    public let path: String
    public let diffSide: DiffSide
    /// At head; nil when outdated.
    public let line: Int?
    /// Multi-line start at head.
    public let startLine: Int?
    public let originalLine: Int?
    public let originalStartLine: Int?
    /// The first comment's `originalCommit.oid`.
    public let originalCommitOID: String?
    public var comments: [ReviewComment]
    public let viewerCanResolve: Bool
    public let viewerCanUnresolve: Bool
    public let viewerCanReply: Bool

    public init(
        id: String, isResolved: Bool, isOutdated: Bool, path: String, diffSide: DiffSide, line: Int?, startLine: Int?,
        originalLine: Int?, originalStartLine: Int?, originalCommitOID: String?, comments: [ReviewComment],
        viewerCanResolve: Bool, viewerCanUnresolve: Bool, viewerCanReply: Bool
    ) {
        self.id = id
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.path = path
        self.diffSide = diffSide
        self.line = line
        self.startLine = startLine
        self.originalLine = originalLine
        self.originalStartLine = originalStartLine
        self.originalCommitOID = originalCommitOID
        self.comments = comments
        self.viewerCanResolve = viewerCanResolve
        self.viewerCanUnresolve = viewerCanUnresolve
        self.viewerCanReply = viewerCanReply
    }

    public var root: ReviewComment? { comments.first }

    /// Every comment is in the viewer's pending (unsubmitted) review.
    public var isPending: Bool { !comments.isEmpty && comments.allSatisfy(\.isPending) }
}

public struct PullRequestReviewThreads: Hashable, Sendable {
    public let ref: PullRequestRef
    /// Pull request node id.
    public let pullRequestID: String
    public let headOID: String
    public let baseOID: String
    public let headRefName: String
    /// "owner/name" of the head repository (the fork for cross-repository PRs); nil when it was deleted.
    public let headRepository: String?
    /// The viewer's pending review, if any.
    public let pendingReviewID: String?
    /// The viewer opened the pull request (GitHub refuses their Approve / Request changes).
    public let viewerIsAuthor: Bool
    public var threads: [ReviewThread]
    public let fetchedAt: Date

    public init(
        ref: PullRequestRef, pullRequestID: String, headOID: String, baseOID: String, headRefName: String,
        headRepository: String?, pendingReviewID: String?, viewerIsAuthor: Bool, threads: [ReviewThread], fetchedAt: Date
    ) {
        self.ref = ref
        self.pullRequestID = pullRequestID
        self.headOID = headOID
        self.baseOID = baseOID
        self.headRefName = headRefName
        self.headRepository = headRepository
        self.pendingReviewID = pendingReviewID
        self.viewerIsAuthor = viewerIsAuthor
        self.threads = threads
        self.fetchedAt = fetchedAt
    }

    /// Comments in the viewer's pending review.
    public var pendingCommentCount: Int {
        threads.reduce(0) { count, thread in count + thread.comments.count { $0.isPending } }
    }

    public func threads(on path: String) -> [ReviewThread] {
        threads.filter { $0.path == path }
    }

    public func thread(containing commentID: String) -> ReviewThread? {
        threads.first { $0.comments.contains { $0.id == commentID } }
    }

    /// The same threads at another head (a commit pushed from here, before GitHub's answer reflects it).
    func with(headOID: String) -> PullRequestReviewThreads {
        PullRequestReviewThreads(
            ref: ref, pullRequestID: pullRequestID, headOID: headOID, baseOID: baseOID, headRefName: headRefName,
            headRepository: headRepository, pendingReviewID: pendingReviewID, viewerIsAuthor: viewerIsAuthor,
            threads: threads, fetchedAt: fetchedAt)
    }
}

/// One entry of a pull request's changed files.
public struct ChangedFile: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let previousPath: String?
    public let status: FilePatch.Status
    public let additions: Int
    public let deletions: Int
    /// The value `pullRequestFilePatch` returns for this path.
    public let patch: FilePatch

    public init(path: String, previousPath: String?, status: FilePatch.Status, additions: Int, deletions: Int, patch: FilePatch) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
    }
}

/// Where a new review comment attaches (GitHub `addPullRequestReviewThread` semantics).
public struct CommentPosition: Hashable, Sendable {
    public let path: String
    public let side: DiffSide
    /// Last line of the range, on `side`.
    public let line: Int
    /// Nil for a single line; on the same side as `line`.
    public let startLine: Int?

    public init(path: String, side: DiffSide, line: Int, startLine: Int?) {
        self.path = path
        self.side = side
        self.line = line
        self.startLine = startLine
    }
}

public enum ReviewEvent: String, Sendable, CaseIterable {
    case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES"
}

/// A ```suggestion block applied to its thread's line range at head.
public struct SuggestionItem: Hashable, Sendable, Identifiable {
    public var id: String { commentID }
    public let commentID: String
    public let threadID: String
    public let path: String
    /// 1-based, inclusive, at head (right side).
    public let startLine: Int
    public let endLine: Int
    /// The suggestion body; "" deletes the lines.
    public let replacement: String

    public init(commentID: String, threadID: String, path: String, startLine: Int, endLine: Int, replacement: String) {
        self.commentID = commentID
        self.threadID = threadID
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.replacement = replacement
    }
}

public struct FilePatch: Hashable, Sendable {
    public enum Status: String, Sendable { case added, removed, modified, renamed, copied, changed, unchanged }
    public let status: Status
    public let previousPath: String?
    /// Unified diff body starting at the first `@@` line. Nil when GitHub omitted it (binary / too large) or unchanged.
    public let patch: String?

    public init(status: Status, previousPath: String?, patch: String?) {
        self.status = status
        self.previousPath = previousPath
        self.patch = patch
    }

    public static let unchanged = FilePatch(status: .unchanged, previousPath: nil, patch: nil)
}

/// Which commit the preview shows.
public enum PreviewCommit: Hashable, Sendable {
    case head(String)
    /// An outdated thread's original commit.
    case original(String)

    public var oid: String {
        switch self {
        case .head(let oid), .original(let oid): oid
        }
    }

    public var isOriginal: Bool {
        if case .original = self { return true }
        return false
    }
}

public protocol FilePreviewService: Sendable {
    /// GraphQL: pullRequest { id headRefOid baseRefOid headRefName headRepository viewerDidAuthor reviews(PENDING)
    /// reviewThreads(first: 100) { … comments(first: 50) { … state originalCommit { oid } } } }
    func reviewThreads(_ ref: PullRequestRef) async throws(GitHubError) -> PullRequestReviewThreads
    /// Raw bytes at `commit` (REST contents API, raw media type). Nil on 404 (file absent at that commit).
    func fileContents(repo: RepoRef, path: String, commit: String) async throws(GitHubError) -> Data?
    /// `path`'s entry in the pull request's files (REST `pulls/{n}/files`, every page; renames match their previous
    /// path). `.unchanged` with nil patch when absent.
    func pullRequestFilePatch(_ ref: PullRequestRef, path: String) async throws(GitHubError) -> FilePatch
    /// `path`'s entry in `base...head` (REST compare, first page: at most 300 files). `.unchanged` with nil patch when
    /// absent. For other commits than the PR's head.
    func filePatch(repo: RepoRef, base: String, head: String, path: String) async throws(GitHubError) -> FilePatch
    /// GraphQL resolveReviewThread / unresolveReviewThread.
    func setThreadResolved(_ threadID: String, resolved: Bool) async throws(GitHubError)
    /// All changed files with patches (`GET pulls/{n}/files`, every page; the call `pullRequestFilePatch` uses).
    func pullRequestFiles(_ ref: PullRequestRef) async throws(GitHubError) -> [ChangedFile]
    /// GraphQL addPullRequestReview(input: {pullRequestId, commitOID}) → the pending review's id.
    func startPendingReview(pullRequestID: String, commitOID: String) async throws(GitHubError) -> String
    /// GraphQL addPullRequestReviewThread(input: {pullRequestReviewId, path, body, line, side, startLine, startSide}).
    func addPendingThread(reviewID: String, position: CommentPosition, body: String) async throws(GitHubError)
    /// GraphQL deletePullRequestReviewComment(input: {id}).
    func deletePendingComment(_ commentID: String) async throws(GitHubError)
    /// GraphQL submitPullRequestReview(input: {pullRequestReviewId, event, body}) when `reviewID` is non-nil, else
    /// addPullRequestReview(input: {pullRequestId, event, body}) (submits at once, without comments).
    func submitReview(pullRequestID: String, reviewID: String?, event: ReviewEvent, body: String) async throws(GitHubError)
    /// GraphQL deletePullRequestReview(input: {pullRequestReviewId}).
    func discardPendingReview(_ reviewID: String) async throws(GitHubError)
    /// GraphQL createCommitOnBranch(input: {branch: {repositoryNameWithOwner, branchName}, message: {headline, body},
    /// expectedHeadOid, fileChanges: {additions: [{path, contents (base64)}]}}) → the new head oid.
    func commitFiles(
        repository: String, branch: String, expectedHeadOID: String, headline: String, body: String?,
        files: [(path: String, contents: Data)]
    ) async throws(GitHubError) -> String
}
