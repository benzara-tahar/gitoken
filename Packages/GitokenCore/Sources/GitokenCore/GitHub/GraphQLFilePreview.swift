import Foundation

// GraphQL and REST payloads for the file preview: review threads with their commits, compare files, resolve, pending
// reviews, and commits of applied suggestions.

enum FilePreviewQueries {
    static let reviewThreads = """
        query FilePreviewThreads($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              id headRefOid baseRefOid headRefName headRepository { nameWithOwner } viewerDidAuthor
              reviews(states: [PENDING], first: 1) { nodes { id } }
              reviewThreads(first: 100) {
                nodes {
                  id isResolved isOutdated path diffSide line startLine originalLine originalStartLine
                  viewerCanResolve viewerCanUnresolve viewerCanReply
                  comments(first: 50) { nodes { \(GraphQLQueries.reviewCommentFields) originalCommit { oid } } }
                }
              }
            }
          }
        }
        \(GraphQLQueries.actorFragment)
        """

    static let resolveThread = """
        mutation ResolveReviewThread($threadId: ID!) {
          resolveReviewThread(input: {threadId: $threadId}) { thread { id isResolved } }
        }
        """

    static let unresolveThread = """
        mutation UnresolveReviewThread($threadId: ID!) {
          unresolveReviewThread(input: {threadId: $threadId}) { thread { id isResolved } }
        }
        """

    static let startReview = """
        mutation StartPendingReview($pullRequestId: ID!, $commitOID: GitObjectID!) {
          addPullRequestReview(input: {pullRequestId: $pullRequestId, commitOID: $commitOID}) { pullRequestReview { id } }
        }
        """

    static let addThread = """
        mutation AddPendingThread($pullRequestReviewId: ID!, $path: String!, $body: String!, $line: Int!, \
        $side: DiffSide!, $startLine: Int, $startSide: DiffSide) {
          addPullRequestReviewThread(input: {pullRequestReviewId: $pullRequestReviewId, path: $path, body: $body, \
        line: $line, side: $side, startLine: $startLine, startSide: $startSide}) { thread { id } }
        }
        """

    static let deleteComment = """
        mutation DeletePendingComment($id: ID!) {
          deletePullRequestReviewComment(input: {id: $id}) { pullRequestReview { id } }
        }
        """

    static let submitReview = """
        mutation SubmitPendingReview($pullRequestReviewId: ID!, $event: PullRequestReviewEvent!, $body: String) {
          submitPullRequestReview(input: {pullRequestReviewId: $pullRequestReviewId, event: $event, body: $body}) {
            pullRequestReview { id }
          }
        }
        """

    static let addReview = """
        mutation AddReview($pullRequestId: ID!, $event: PullRequestReviewEvent!, $body: String) {
          addPullRequestReview(input: {pullRequestId: $pullRequestId, event: $event, body: $body}) { pullRequestReview { id } }
        }
        """

    static let deleteReview = """
        mutation DeletePendingReview($pullRequestReviewId: ID!) {
          deletePullRequestReview(input: {pullRequestReviewId: $pullRequestReviewId}) { pullRequestReview { id } }
        }
        """

    static let createCommit = """
        mutation CommitSuggestions($input: CreateCommitOnBranchInput!) {
          createCommitOnBranch(input: $input) { commit { oid } }
        }
        """
}

struct ReviewThreadIDVariables: Encodable {
    let threadId: String
}

struct StartReviewVariables: Encodable {
    let pullRequestId: String
    let commitOID: String
}

/// Nil `startLine` / `startSide` are omitted (single-line comment).
struct AddThreadVariables: Encodable {
    let pullRequestReviewId: String
    let path: String
    let body: String
    let line: Int
    let side: String
    let startLine: Int?
    let startSide: String?

    init(reviewID: String, position: CommentPosition, body: String) {
        pullRequestReviewId = reviewID
        path = position.path
        self.body = body
        line = position.line
        side = position.side.graphQLValue
        startLine = position.startLine
        startSide = position.startLine == nil ? nil : position.side.graphQLValue
    }
}

struct NodeIDVariables: Encodable {
    let id: String
}

struct SubmitReviewVariables: Encodable {
    let pullRequestReviewId: String
    let event: String
    let body: String
}

struct AddReviewVariables: Encodable {
    let pullRequestId: String
    let event: String
    let body: String
}

struct ReviewIDVariables: Encodable {
    let pullRequestReviewId: String
}

struct CreateCommitVariables: Encodable {
    struct Input: Encodable {
        struct Branch: Encodable {
            let repositoryNameWithOwner: String
            let branchName: String
        }
        struct Message: Encodable {
            let headline: String
            let body: String?
        }
        struct Addition: Encodable {
            let path: String
            /// Base64.
            let contents: String
        }
        struct FileChanges: Encodable {
            let additions: [Addition]
        }
        let branch: Branch
        let message: Message
        let expectedHeadOid: String
        let fileChanges: FileChanges
    }
    let input: Input
}

struct GQLReviewPayloadData: Decodable {
    struct Payload: Decodable {
        struct Review: Decodable { let id: String }
        let pullRequestReview: Review?
    }
    let addPullRequestReview: Payload?
    let submitPullRequestReview: Payload?
    let deletePullRequestReview: Payload?
    let deletePullRequestReviewComment: Payload?
}

struct GQLAddThreadData: Decodable {
    struct Payload: Decodable { let thread: GQLNodeRef? }
    let addPullRequestReviewThread: Payload?
}

struct GQLCreateCommitData: Decodable {
    struct Payload: Decodable {
        struct Commit: Decodable { let oid: String }
        let commit: Commit?
    }
    let createCommitOnBranch: Payload?
}

extension DiffSide {
    var graphQLValue: String { self == .left ? "LEFT" : "RIGHT" }
}

struct GQLResolveThreadData: Decodable {
    struct Payload: Decodable {
        struct Thread: Decodable {
            let id: String
            let isResolved: Bool
        }
        let thread: Thread?
    }
    let resolveReviewThread: Payload?
    let unresolveReviewThread: Payload?
}

struct GQLFilePreviewData: Decodable {
    struct Repository: Decodable { let pullRequest: GQLFilePreviewPullRequest? }
    let repository: Repository?
}

struct GQLFilePreviewPullRequest: Decodable {
    struct HeadRepository: Decodable { let nameWithOwner: String }
    let id: String
    let headRefOid: String
    let baseRefOid: String
    let headRefName: String
    let headRepository: HeadRepository?
    let viewerDidAuthor: Bool?
    let reviews: GQLNodes<GQLNodeRef>?
    let reviewThreads: GQLNodes<GQLReviewThread>

    func threads(ref: PullRequestRef, fetchedAt: Date) -> PullRequestReviewThreads {
        PullRequestReviewThreads(
            ref: ref, pullRequestID: id, headOID: headRefOid, baseOID: baseRefOid, headRefName: headRefName,
            headRepository: headRepository?.nameWithOwner, pendingReviewID: reviews?.items.first?.id,
            viewerIsAuthor: viewerDidAuthor ?? false, threads: reviewThreads.items.map(\.reviewThread), fetchedAt: fetchedAt)
    }
}

struct GQLReviewThread: Decodable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let path: String
    let diffSide: String?
    let line: Int?
    let startLine: Int?
    let originalLine: Int?
    let originalStartLine: Int?
    let viewerCanResolve: Bool?
    let viewerCanUnresolve: Bool?
    let viewerCanReply: Bool?
    let comments: GQLNodes<GQLThreadComment>

    var reviewThread: ReviewThread {
        let nodes = comments.items
        return ReviewThread(
            id: id, isResolved: isResolved, isOutdated: isOutdated, path: path,
            diffSide: diffSide == "LEFT" ? .left : .right, line: line, startLine: startLine, originalLine: originalLine,
            originalStartLine: originalStartLine, originalCommitOID: nodes.first?.originalCommit?.oid,
            comments: nodes.map(\.comment.reviewComment), viewerCanResolve: viewerCanResolve ?? false,
            viewerCanUnresolve: viewerCanUnresolve ?? false, viewerCanReply: viewerCanReply ?? false)
    }
}

/// A thread comment: the timeline's review comment fields plus the commit it was written against.
struct GQLThreadComment: Decodable {
    struct Commit: Decodable { let oid: String }
    let comment: GQLReviewComment
    let originalCommit: Commit?

    private enum CodingKeys: String, CodingKey { case originalCommit }

    init(from decoder: any Decoder) throws {
        comment = try GQLReviewComment(from: decoder)
        originalCommit = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Commit.self, forKey: .originalCommit)
    }
}

/// One entry of `GET /repos/{owner}/{repo}/pulls/{number}/files` or of a compare's `files`.
struct RESTChangedFile: Decodable {
    let filename: String
    let previousFilename: String?
    let status: String
    let additions: Int?
    let deletions: Int?
    let patch: String?

    var filePatch: FilePatch {
        let status = FilePatch.Status(rawValue: status) ?? .changed
        return FilePatch(status: status, previousPath: previousFilename, patch: patch.flatMap(FilePatch.trimmedToFirstHunk))
    }

    var changedFile: ChangedFile {
        let patch = filePatch
        return ChangedFile(
            path: filename, previousPath: previousFilename, status: patch.status, additions: additions ?? 0,
            deletions: deletions ?? 0, patch: patch)
    }
}

/// `GET /repos/{owner}/{repo}/compare/{base}...{head}`, files only.
struct RESTCompare: Decodable {
    let files: [RESTChangedFile]?
}

extension FilePatch {
    /// Drops anything before the first `@@` line (git's `diff --git` / `index` / `---` / `+++` headers).
    /// Nil when there is no hunk (binary, mode-only, or empty diffs).
    static func trimmedToFirstHunk(_ diff: String) -> String? {
        if diff.hasPrefix("@@") { return diff }
        guard let range = diff.range(of: "\n@@") else { return nil }
        return String(diff[diff.index(after: range.lowerBound)...])
    }
}
