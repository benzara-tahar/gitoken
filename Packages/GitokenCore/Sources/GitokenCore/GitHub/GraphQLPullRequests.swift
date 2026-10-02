import Foundation

// GraphQL for the PR Shelf: status lists (search + aliased lookups) and the agent-context query.

enum ShelfQueries {
    private static let actorFragment = """
        fragment ShelfActor on Actor { __typename login avatarUrl ... on User { name } }
        """

    private static let pullRequestFragment = """
        fragment ShelfPullRequest on PullRequest {
          id number title state isDraft merged updatedAt headRefName headRefOid baseRefName isCrossRepository
          reviewDecision mergeable
          author { ...ShelfActor }
          repository { name owner { login } viewerPermission mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed }
          reviewThreads(first: 100) { nodes { isResolved } }
          comments(last: 10) { nodes { author { ...ShelfActor } bodyText createdAt } }
          reviews(last: 10) { nodes { author { ...ShelfActor } state bodyText submittedAt } }
          commits(last: 1) {
            nodes {
              commit {
                oid committedDate
                statusCheckRollup {
                  state
                  contexts(first: 100) {
                    nodes {
                      __typename
                      ... on CheckRun { name conclusion status completedAt }
                      ... on StatusContext { context contextState: state createdAt }
                    }
                  }
                }
              }
            }
          }
        }
        """

    static let mine = """
        query ShelfMine($query: String!) {
          viewer { login }
          search(type: ISSUE, query: $query, first: 50) {
            nodes { __typename ... on PullRequest { ...ShelfPullRequest } }
          }
        }
        \(pullRequestFragment)
        \(actorFragment)
        """

    static let mineSearch = "is:pr is:open author:@me archived:false sort:updated-desc"

    /// One aliased `repository { pullRequest }` per ref (`r0`, `r1`, …) with `$o<i>`, `$n<i>`, `$p<i>` variables.
    static func lookup(count: Int) -> String {
        let parameters = (0..<count).map { "$o\($0): String!, $n\($0): String!, $p\($0): Int!" }.joined(separator: ", ")
        let fields = (0..<count).map {
            "r\($0): repository(owner: $o\($0), name: $n\($0)) { pullRequest(number: $p\($0)) { ...ShelfPullRequest } }"
        }.joined(separator: "\n  ")
        return """
            query ShelfLookup(\(parameters)) {
              viewer { login }
              \(fields)
            }
            \(pullRequestFragment)
            \(actorFragment)
            """
    }

    static let agentContext = """
        query ShelfAgentContext($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              number title body headRefName baseRefName
              reviewThreads(first: 100) {
                nodes {
                  isResolved isOutdated path line originalLine
                  comments(first: 30) { nodes { author { login } body diffHunk } }
                }
              }
              commits(last: 1) {
                nodes {
                  commit {
                    oid
                    statusCheckRollup {
                      contexts(first: 100) {
                        nodes {
                          __typename
                          ... on CheckRun { databaseId name conclusion status detailsUrl summary checkSuite { app { slug } } }
                          ... on StatusContext { context contextState: state description targetUrl }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """
}

/// Variables of mixed scalar types (the aliased lookup query).
enum GraphQLScalar: Encodable {
    case string(String)
    case int(Int)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        }
    }
}

struct SearchVariables: Encodable {
    let query: String
}

/// GraphQL envelope that keeps error types, so lookups can tolerate per-alias `NOT_FOUND` / `FORBIDDEN`.
struct ShelfGraphQLResponse<Payload: Decodable>: Decodable {
    struct Message: Decodable {
        let message: String
        let type: String?
    }
    let data: Payload?
    let errors: [Message]?
}

struct GQLViewerLogin: Decodable {
    let login: String
}

struct GQLShelfPullRequest: Decodable {
    struct Repository: Decodable {
        struct Owner: Decodable { let login: String }
        let name: String
        let owner: Owner
        let viewerPermission: String?
        let mergeCommitAllowed: Bool
        let squashMergeAllowed: Bool
        let rebaseMergeAllowed: Bool
    }
    struct ThreadState: Decodable { let isResolved: Bool }
    struct Comment: Decodable {
        let author: GQLActor?
        let bodyText: String
        let createdAt: Date
    }
    struct Review: Decodable {
        let author: GQLActor?
        let state: String
        let bodyText: String
        let submittedAt: Date?
    }

    let id: String
    let number: Int
    let title: String
    let state: String
    let isDraft: Bool
    let merged: Bool
    let updatedAt: Date
    let headRefName: String
    let headRefOid: String
    let baseRefName: String
    let isCrossRepository: Bool
    let reviewDecision: String?
    let mergeable: String
    let author: GQLActor?
    let repository: Repository
    let reviewThreads: GQLNodes<ThreadState>
    let comments: GQLNodes<Comment>
    let reviews: GQLNodes<Review>
    let commits: GQLNodes<GQLLastCommit>

    enum CodingKeys: String, CodingKey {
        case id, number, title, state, isDraft, merged, updatedAt, headRefName, headRefOid, baseRefName, isCrossRepository
        case reviewDecision, mergeable, author, repository, reviewThreads, comments, reviews, commits
    }

    func status(viewerLogin: String) -> PullRequestStatus {
        let repo = RepoRef(owner: repository.owner.login, name: repository.name)
        let subjectState: SubjectState = merged ? .merged : state == "CLOSED" ? .closed : .open
        let decision: ReviewDecision = switch reviewDecision {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: .none
        }
        let mergeableState: MergeableState = switch mergeable {
        case "MERGEABLE": .mergeable
        case "CONFLICTING": .conflicting
        default: .unknown
        }
        var methods: [MergeMethod] = []
        if repository.mergeCommitAllowed { methods.append(.merge) }
        if repository.squashMergeAllowed { methods.append(.squash) }
        if repository.rebaseMergeAllowed { methods.append(.rebase) }
        let checks = commits.items.last.flatMap { last in
            last.commit.statusCheckRollup.map { TimelineMapper.checkSummary(sha: last.commit.oid, rollup: $0) }
        }
        return PullRequestStatus(
            nodeID: id, ref: PullRequestRef(repo: repo, number: number), title: title, author: author?.actor ?? .ghost,
            state: subjectState, isDraft: isDraft, headRefName: headRefName, headRefOID: headRefOid,
            baseRefName: baseRefName, isCrossRepository: isCrossRepository, checks: checks, reviewDecision: decision,
            mergeable: mergeableState, unresolvedThreadCount: reviewThreads.items.filter { !$0.isResolved }.count,
            latestHumanActivity: latestHumanActivity(viewerLogin: viewerLogin), updatedAt: updatedAt,
            viewerCanMerge: ["ADMIN", "MAINTAIN", "WRITE"].contains(repository.viewerPermission ?? ""),
            allowedMergeMethods: methods
        )
    }

    /// Newest comment or submitted review by a human (not a bot, not an AI reviewer) other than the viewer.
    func latestHumanActivity(viewerLogin: String) -> ActivityPreview? {
        let viewer = Actor(login: viewerLogin)
        func human(_ author: GQLActor?) -> Actor? {
            guard let actor = author?.actor, !actor.isBot, !AIReviewers.isAI(actor),
                  !ActivityAnalysis.isViewer(actor, viewer) else { return nil }
            return actor
        }
        var candidates: [ActivityPreview] = []
        for comment in comments.items {
            guard let actor = human(comment.author) else { continue }
            let verb: ActivityVerb = ActivityAnalysis.mentions(viewer, in: comment.bodyText) ? .mentioned : .commented
            candidates.append(ActivityPreview(
                actor: actor, verb: verb, snippet: ActivityAnalysis.snippet(comment.bodyText), at: comment.createdAt))
        }
        for review in reviews.items {
            guard let actor = human(review.author), let at = review.submittedAt else { continue }
            let verb: ActivityVerb
            switch review.state {
            case "APPROVED": verb = .approved
            case "CHANGES_REQUESTED": verb = .requestedChanges
            case "COMMENTED": verb = .reviewed
            default: continue
            }
            candidates.append(ActivityPreview(actor: actor, verb: verb, snippet: ActivityAnalysis.snippet(review.bodyText), at: at))
        }
        return candidates.max { $0.at < $1.at }
    }
}

struct GQLShelfSearchData: Decodable {
    struct Search: Decodable { let nodes: [GQLShelfSearchNode?] }
    let viewer: GQLViewerLogin
    let search: Search
}

/// Search results may contain issues; only pull requests decode to a value.
struct GQLShelfSearchNode: Decodable {
    let pullRequest: GQLShelfPullRequest?

    private enum Keys: String, CodingKey { case typename = "__typename" }

    init(from decoder: any Decoder) throws {
        let typename = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .typename)
        pullRequest = typename == "PullRequest" ? try GQLShelfPullRequest(from: decoder) : nil
    }
}

/// `viewer` plus the aliased `r<i>` repositories of `ShelfQueries.lookup(count:)`.
struct GQLShelfLookupData: Decodable {
    struct Repository: Decodable { let pullRequest: GQLShelfPullRequest? }

    let viewerLogin: String
    /// Indexed by alias number; nil where the repository or PR could not be resolved.
    let pullRequests: [Int: GQLShelfPullRequest]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        viewerLogin = try container.decode(GQLViewerLogin.self, forKey: Key(stringValue: "viewer")).login
        var found: [Int: GQLShelfPullRequest] = [:]
        for key in container.allKeys where key.stringValue.hasPrefix("r") {
            guard let index = Int(key.stringValue.dropFirst()),
                  let pr = try container.decodeIfPresent(Repository.self, forKey: key)?.pullRequest else { continue }
            found[index] = pr
        }
        pullRequests = found
    }
}

struct GQLAgentContextData: Decodable {
    struct Repository: Decodable { let pullRequest: PullRequest? }
    struct PullRequest: Decodable {
        let number: Int
        let title: String
        let body: String
        let headRefName: String
        let baseRefName: String
        let reviewThreads: GQLNodes<Thread>
        let commits: GQLNodes<LastCommit>
    }
    struct Thread: Decodable {
        let isResolved: Bool
        let isOutdated: Bool
        let path: String
        let line: Int?
        let originalLine: Int?
        let comments: GQLNodes<Comment>
    }
    struct Comment: Decodable {
        let author: GQLLoginRef?
        let body: String
        let diffHunk: String
    }
    struct LastCommit: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable { let contexts: GQLNodes<Context> }
            let oid: String
            let statusCheckRollup: Rollup?
        }
        let commit: Commit
    }
    struct Context: Decodable {
        struct CheckSuite: Decodable {
            struct App: Decodable { let slug: String }
            let app: App?
        }
        let typename: String
        let databaseId: Int?
        let name: String?
        let conclusion: String?
        let status: String?
        let detailsUrl: String?
        let summary: String?
        let checkSuite: CheckSuite?
        let context: String?
        let contextState: String?
        let description: String?
        let targetUrl: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename", databaseId, name, conclusion, status, detailsUrl, summary, checkSuite, context
            case contextState, description, targetUrl
        }

        static let failedConclusions: Set<String> = ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]

        var isFailing: Bool {
            switch typename {
            case "CheckRun": status == "COMPLETED" && Self.failedConclusions.contains(conclusion ?? "")
            case "StatusContext": contextState == "FAILURE" || contextState == "ERROR"
            default: false
            }
        }

        /// GitHub Actions check runs share their database id with the job, whose log can be downloaded.
        var actionsJobID: Int? {
            typename == "CheckRun" && checkSuite?.app?.slug == "github-actions" ? databaseId : nil
        }
    }

    let repository: Repository?
}
