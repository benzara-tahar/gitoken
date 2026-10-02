import Foundation

/// Why Gitoken cannot talk to GitHub. Auth is the `gh` CLI token only; every failure blocks with instructions.
public enum AuthError: Error, Equatable, Sendable {
    /// No `gh` executable at any known location (GUI apps don't inherit the shell PATH).
    case ghNotInstalled(searched: [String])
    /// `gh auth token` failed or printed nothing: user must run `gh auth login`.
    case notLoggedIn(detail: String)
    /// GitHub rejected the token (401), or it lacks access to /notifications (403, e.g. fine-grained token).
    case tokenRejected(status: Int, scopes: String?)

    /// One-line instruction shown in the blocking UI.
    public var instructions: String {
        switch self {
        case .ghNotInstalled:
            return "Install the GitHub CLI (brew install gh), then run gh auth login."
        case .notLoggedIn:
            return "Run gh auth login in Terminal, then retry."
        case .tokenRejected:
            return "GitHub rejected the gh token. Run gh auth login with a classic OAuth login (not a fine-grained token), then retry."
        }
    }
}

public enum GitHubError: Error, Equatable, Sendable {
    case auth(AuthError)
    case rateLimited(resetAt: Date?)
    case http(status: Int, message: String?)
    case graphQL([String])
    case decoding(String)
    case transport(String)
}

/// Supplies the token used for every request. Implementation: `GHCLITokenProvider` (runs `gh auth token`).
public protocol TokenProvider: Sendable {
    func token() async throws(AuthError) -> String
    /// Drop any cached token so the next call re-runs `gh` (after a 401 or user-initiated retry).
    func invalidate() async
}

/// Everything the inbox needs from GitHub. Implementation: `GitHubClient` (URLSession REST + GraphQL).
public protocol GitHubService: Sendable {
    /// Authenticated user (`GET /user`).
    func viewer() async throws(GitHubError) -> Actor

    /// `GET /notifications?all=true` (all pages) with `If-Modified-Since: lastModified`.
    /// Returns `.notModified` on 304. Honors `X-Poll-Interval` (min 60s) in the returned interval.
    func pollNotifications(lastModified: String?) async throws(GitHubError) -> NotificationPoll

    /// GraphQL hydration of a PR/issue timeline, review comments with diff hunks, and latest check rollup.
    /// Throws `.http(404, …)` style errors for subjects that cannot be hydrated (e.g. Release, Commit).
    func threadDetail(for thread: NotificationThread) async throws(GitHubError) -> ThreadDetail

    /// `PATCH /notifications/threads/{id}` — GitHub "read". Gitoken's "seen".
    func markRead(_ id: ThreadID) async throws(GitHubError)

    /// `DELETE /notifications/threads/{id}` — GitHub "done".
    func markDone(_ id: ThreadID) async throws(GitHubError)

    /// `POST /repos/{owner}/{repo}/issues/{number}/comments`. Works for PRs and issues.
    func postComment(repo: RepoRef, number: Int, body: String) async throws(GitHubError) -> TimelineItem

    /// `POST /repos/{owner}/{repo}/pulls/{number}/comments/{commentID}/replies`.
    func replyToReviewComment(repo: RepoRef, number: Int, commentDatabaseID: Int, body: String) async throws(GitHubError)
        -> ReviewComment

    /// GraphQL `addReaction(input: {subjectId, content})`. `subjectID` is the node id of the PR/issue, comment,
    /// review, or review comment.
    func addReaction(_ content: ReactionContent, subjectID: String) async throws(GitHubError)
}
