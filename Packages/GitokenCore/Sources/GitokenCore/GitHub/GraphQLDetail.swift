import Foundation

enum GraphQLQueries {
    static let actorFragment = """
        fragment ActorFields on Actor { __typename login avatarUrl ... on User { name } }
        """

    static let reviewCommentFields = """
        id databaseId author { ...ActorFields } body bodyHTML bodyText createdAt path diffHunk line originalLine replyTo { id } url state \(reactionFields)
        """

    static let reactionFields = "reactionGroups { content viewerHasReacted reactors { totalCount } }"

    static let pullRequest = """
        query PullRequestDetail($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              id title state isDraft merged url body bodyHTML bodyText createdAt \(reactionFields)
              author { ...ActorFields }
              timelineItems(last: 60, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, REVIEW_REQUESTED_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, HEAD_REF_FORCE_PUSHED_EVENT]) {
                pageInfo { hasPreviousPage }
                nodes {
                  __typename
                  ... on IssueComment { id author { ...ActorFields } body bodyHTML bodyText createdAt url \(reactionFields) }
                  ... on PullRequestReview {
                    id author { ...ActorFields } body bodyHTML bodyText state createdAt url \(reactionFields)
                    comments(first: 30) { nodes { \(reviewCommentFields) } }
                  }
                  ... on PullRequestCommit {
                    id url
                    commit { oid messageHeadline committedDate author { name user { ...ActorFields } } }
                  }
                  ... on ReviewRequestedEvent {
                    id actor { ...ActorFields } createdAt
                    requestedReviewer { __typename ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Team { teamName: combinedSlug } }
                  }
                  ... on MergedEvent { id actor { ...ActorFields } createdAt mergeCommit: commit { abbreviatedOid } }
                  ... on ClosedEvent { id actor { ...ActorFields } createdAt }
                  ... on ReopenedEvent { id actor { ...ActorFields } createdAt }
                  ... on ReadyForReviewEvent { id actor { ...ActorFields } createdAt }
                  ... on ConvertToDraftEvent { id actor { ...ActorFields } createdAt }
                  ... on HeadRefForcePushedEvent { id actor { ...ActorFields } createdAt }
                }
              }
              commits(last: 1) {
                nodes {
                  commit {
                    oid committedDate
                    statusCheckRollup {
                      state
                      contexts(first: 50) {
                        nodes {
                          __typename
                          ... on CheckRun { name conclusion status completedAt checkSuite { app { slug name } } }
                          ... on StatusContext { context contextState: state createdAt }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        \(actorFragment)
        """

    static let issue = """
        query IssueDetail($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            issue(number: $number) {
              id title state url body bodyHTML bodyText createdAt \(reactionFields)
              author { ...ActorFields }
              timelineItems(last: 60, itemTypes: [ISSUE_COMMENT, CLOSED_EVENT, REOPENED_EVENT, ASSIGNED_EVENT]) {
                pageInfo { hasPreviousPage }
                nodes {
                  __typename
                  ... on IssueComment { id author { ...ActorFields } body bodyHTML bodyText createdAt url \(reactionFields) }
                  ... on ClosedEvent { id actor { ...ActorFields } createdAt }
                  ... on ReopenedEvent { id actor { ...ActorFields } createdAt }
                  ... on AssignedEvent {
                    id actor { ...ActorFields } createdAt
                    assignee { __typename ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Organization { login } }
                  }
                }
              }
            }
          }
        }
        \(actorFragment)
        """

    static let addReaction = """
        mutation AddReaction($subjectId: ID!, $content: ReactionContent!) {
          addReaction(input: {subjectId: $subjectId, content: $content}) { reaction { content } }
        }
        """
}

struct GraphQLRequest<Variables: Encodable>: Encodable {
    let query: String
    let variables: Variables
}

struct SubjectVariables: Encodable {
    let owner: String
    let name: String
    let number: Int
}

struct AddReactionVariables: Encodable {
    let subjectId: String
    let content: String
}

struct GQLAddReactionData: Decodable {
    struct Payload: Decodable {
        struct Reaction: Decodable { let content: String }
        let reaction: Reaction?
    }
    let addReaction: Payload?
}

struct GraphQLResponse<Payload: Decodable>: Decodable {
    struct Message: Decodable { let message: String }
    let data: Payload?
    let errors: [Message]?
}

struct GQLNodes<Node: Decodable>: Decodable {
    let nodes: [Node?]
    var items: [Node] { nodes.compactMap { $0 } }
}

struct GQLActor: Decodable {
    let typename: String?
    let login: String
    let avatarUrl: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename", login, avatarUrl, name
    }

    var actor: Actor {
        Actor(login: login, name: name, avatarURL: avatarUrl.flatMap(URL.init(string:)), isBot: typename == "Bot")
    }
}

struct GQLReviewComment: Decodable {
    let id: String
    let databaseId: Int?
    let author: GQLActor?
    let body: String
    let bodyHTML: String?
    let bodyText: String?
    let createdAt: Date
    let path: String
    let diffHunk: String
    let line: Int?
    let originalLine: Int?
    let replyTo: GQLNodeRef?
    let url: String?
    let reactionGroups: [GQLReactionGroup]?
    /// `PENDING` or `SUBMITTED`.
    let state: String?

    var reviewComment: ReviewComment {
        ReviewComment(
            id: id, databaseID: databaseId ?? 0, author: author?.actor ?? .ghost,
            body: RichBody(markdown: body, html: bodyHTML, plain: bodyText), createdAt: createdAt,
            path: path, diffHunk: diffHunk, line: line ?? originalLine, replyToID: replyTo?.id,
            url: url.flatMap(URL.init(string:)), reactions: GQLReactionGroup.counts(reactionGroups),
            isPending: state == "PENDING"
        )
    }
}

struct GQLReactionGroup: Decodable {
    struct Reactors: Decodable { let totalCount: Int }
    let content: String
    let viewerHasReacted: Bool
    let reactors: Reactors

    /// Non-empty groups Gitoken can show, in `ReactionContent` order (👎 😄 aren't offered, so they're dropped).
    static func counts(_ groups: [GQLReactionGroup]?) -> [ReactionCount] {
        let byContent = Dictionary(
            (groups ?? []).compactMap { group in
                ReactionContent(rawValue: group.content).flatMap { content in
                    group.reactors.totalCount > 0
                        ? (content, ReactionCount(content: content, count: group.reactors.totalCount, viewerHasReacted: group.viewerHasReacted))
                        : nil
                }
            },
            uniquingKeysWith: { first, _ in first })
        return ReactionContent.allCases.compactMap { byContent[$0] }
    }
}

struct GQLNodeRef: Decodable {
    let id: String
}

struct GQLLoginRef: Decodable {
    let login: String?
    let teamName: String?
}

struct GQLTimelineNode: Decodable {
    struct PRCommit: Decodable {
        struct GitActor: Decodable {
            let name: String?
            let user: GQLActor?
        }
        let oid: String
        let messageHeadline: String
        let committedDate: Date
        let author: GitActor?
    }

    struct MergeCommit: Decodable {
        let abbreviatedOid: String
    }

    let typename: String
    let id: String?
    let author: GQLActor?
    let actor: GQLActor?
    let body: String?
    let bodyHTML: String?
    let bodyText: String?
    let state: String?
    let createdAt: Date?
    let url: String?
    let comments: GQLNodes<GQLReviewComment>?
    let commit: PRCommit?
    let mergeCommit: MergeCommit?
    let requestedReviewer: GQLLoginRef?
    let assignee: GQLLoginRef?
    let reactionGroups: [GQLReactionGroup]?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename", id, author, actor, body, bodyHTML, bodyText, state, createdAt, url, comments, commit
        case mergeCommit
        case requestedReviewer, assignee, reactionGroups
    }

    var richBody: RichBody { RichBody(markdown: body ?? "", html: bodyHTML, plain: bodyText) }
}

struct GQLTimeline: Decodable {
    struct PageInfo: Decodable { let hasPreviousPage: Bool }
    let pageInfo: PageInfo
    let nodes: [GQLTimelineNode?]
}

struct GQLCheckContext: Decodable {
    struct CheckSuite: Decodable {
        struct App: Decodable {
            let slug: String
            let name: String
        }
        let app: App?
    }

    let typename: String
    let name: String?
    let conclusion: String?
    let status: String?
    let completedAt: Date?
    let checkSuite: CheckSuite?
    let context: String?
    let contextState: String?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename", name, conclusion, status, completedAt, checkSuite, context, contextState, createdAt
    }
}

struct GQLLastCommit: Decodable {
    struct Commit: Decodable {
        struct Rollup: Decodable {
            let state: String
            let contexts: GQLNodes<GQLCheckContext>
        }
        let oid: String
        let committedDate: Date
        let statusCheckRollup: Rollup?
    }
    let commit: Commit
}

struct GQLPullRequest: Decodable {
    let id: String
    let title: String
    let state: String
    let isDraft: Bool
    let merged: Bool
    let url: String
    let body: String
    let bodyHTML: String?
    let bodyText: String?
    let createdAt: Date
    let author: GQLActor?
    let timelineItems: GQLTimeline
    let commits: GQLNodes<GQLLastCommit>
    let reactionGroups: [GQLReactionGroup]?

    var richBody: RichBody { RichBody(markdown: body, html: bodyHTML, plain: bodyText) }
}

struct GQLIssue: Decodable {
    let id: String
    let title: String
    let state: String
    let url: String
    let body: String
    let bodyHTML: String?
    let bodyText: String?
    let createdAt: Date
    let author: GQLActor?
    let timelineItems: GQLTimeline
    let reactionGroups: [GQLReactionGroup]?

    var richBody: RichBody { RichBody(markdown: body, html: bodyHTML, plain: bodyText) }
}

struct GQLPullRequestData: Decodable {
    struct Repository: Decodable { let pullRequest: GQLPullRequest? }
    let repository: Repository?
}

struct GQLIssueData: Decodable {
    struct Repository: Decodable { let issue: GQLIssue? }
    let repository: Repository?
}

// MARK: - Mapping to domain

enum TimelineMapper {
    struct SubjectDetail {
        let title: String
        let state: SubjectState
        let author: Actor?
        let htmlURL: URL
        let items: [TimelineItem]
        let checks: CheckSummary?

        func thread(id: ThreadID, fetchedAt: Date) -> ThreadDetail {
            ThreadDetail(threadID: id, title: title, state: state, author: author, htmlURL: htmlURL,
                         items: items, checks: checks, fetchedAt: fetchedAt)
        }

        func search(id: SearchItemID, fetchedAt: Date) -> SearchSubjectDetail {
            SearchSubjectDetail(id: id, title: title, state: state, author: author, htmlURL: htmlURL,
                                items: items, checks: checks, fetchedAt: fetchedAt)
        }
    }

    static func detail(threadID: ThreadID, pullRequest: GQLPullRequest, fetchedAt: Date) -> ThreadDetail {
        subject(pullRequest: pullRequest).thread(id: threadID, fetchedAt: fetchedAt)
    }

    static func subject(pullRequest pr: GQLPullRequest) -> SubjectDetail {
        let author = pr.author?.actor ?? .ghost
        let url = URL(string: pr.url)
        var items: [TimelineItem] = []
        if !pr.timelineItems.pageInfo.hasPreviousPage {
            items.append(opened(
                id: pr.id, author: author, body: pr.richBody, createdAt: pr.createdAt, url: url,
                reactions: GQLReactionGroup.counts(pr.reactionGroups)))
        }
        for node in pr.timelineItems.nodes.compactMap({ $0 }) {
            append(node, to: &items)
        }

        var checks: CheckSummary?
        if let lastCommit = pr.commits.items.last?.commit, let rollup = lastCommit.statusCheckRollup {
            let summary = checkSummary(sha: lastCommit.oid, rollup: rollup)
            checks = summary
            let contexts = rollup.contexts.items
            let finishedAt = contexts.compactMap { $0.completedAt ?? $0.createdAt }.max()
            let at = max(lastCommit.committedDate, finishedAt ?? lastCommit.committedDate)
            let item = TimelineItem(
                id: "checks-\(lastCommit.oid)", actor: checksActor(contexts), createdAt: at, payload: .checks(summary),
                url: URL(string: "\(pr.url)/checks")
            )
            let index = items.firstIndex(where: { $0.createdAt > at }) ?? items.endIndex
            items.insert(item, at: index)
        }

        let state: SubjectState
        if pr.merged {
            state = .merged
        } else if pr.state == "CLOSED" {
            state = .closed
        } else {
            state = pr.isDraft ? .draft : .open
        }
        return SubjectDetail(
            title: pr.title, state: state, author: pr.author?.actor,
            htmlURL: url ?? URL(string: "https://github.com")!, items: items, checks: checks
        )
    }

    static func detail(threadID: ThreadID, issue: GQLIssue, fetchedAt: Date) -> ThreadDetail {
        subject(issue: issue).thread(id: threadID, fetchedAt: fetchedAt)
    }

    static func subject(issue: GQLIssue) -> SubjectDetail {
        let author = issue.author?.actor ?? .ghost
        let url = URL(string: issue.url)
        var items: [TimelineItem] = []
        if !issue.timelineItems.pageInfo.hasPreviousPage {
            items.append(opened(
                id: issue.id, author: author, body: issue.richBody, createdAt: issue.createdAt, url: url,
                reactions: GQLReactionGroup.counts(issue.reactionGroups)))
        }
        for node in issue.timelineItems.nodes.compactMap({ $0 }) {
            append(node, to: &items)
        }
        return SubjectDetail(
            title: issue.title, state: issue.state == "CLOSED" ? .closed : .open,
            author: issue.author?.actor, htmlURL: url ?? URL(string: "https://github.com")!, items: items, checks: nil
        )
    }

    private static func opened(id: String, author: Actor, body: RichBody, createdAt: Date, url: URL?, reactions: [ReactionCount])
        -> TimelineItem
    {
        TimelineItem(
            id: "\(TimelineItem.openedPrefix)\(id)", actor: author, createdAt: createdAt, payload: .opened(body: body), url: url,
            reactions: reactions)
    }

    private static func append(_ node: GQLTimelineNode, to items: inout [TimelineItem]) {
        let url = node.url.flatMap(URL.init(string:))
        func event(_ kind: TimelineEventKind, detail: String? = nil) {
            guard let id = node.id, let createdAt = node.createdAt else { return }
            items.append(TimelineItem(
                id: id, actor: node.actor?.actor ?? .ghost, createdAt: createdAt, payload: .event(kind, detail: detail),
                url: url
            ))
        }

        switch node.typename {
        case "IssueComment":
            guard let id = node.id, let createdAt = node.createdAt else { return }
            items.append(TimelineItem(
                id: id, actor: node.author?.actor ?? .ghost, createdAt: createdAt, payload: .comment(body: node.richBody),
                url: url, reactions: GQLReactionGroup.counts(node.reactionGroups)
            ))
        case "PullRequestReview":
            guard let id = node.id, let createdAt = node.createdAt else { return }
            let comments = node.comments?.items.map(\.reviewComment) ?? []
            items.append(TimelineItem(
                id: id, actor: node.author?.actor ?? .ghost, createdAt: createdAt,
                payload: .review(state: reviewState(node.state), body: node.richBody, comments: comments), url: url,
                reactions: GQLReactionGroup.counts(node.reactionGroups)
            ))
        case "PullRequestCommit":
            guard let id = node.id, let commit = node.commit else { return }
            let actor = commit.author?.user?.actor ?? Actor(login: commit.author?.name ?? "unknown", name: commit.author?.name)
            if let last = items.last, case .commits(let count, let headlines) = last.payload,
                last.actor.login == actor.login
            {
                items[items.count - 1] = TimelineItem(
                    id: last.id, actor: last.actor, createdAt: max(last.createdAt, commit.committedDate),
                    payload: .commits(count: count + 1, headlines: headlines + [commit.messageHeadline]), url: url
                )
            } else {
                items.append(TimelineItem(
                    id: id, actor: actor, createdAt: commit.committedDate,
                    payload: .commits(count: 1, headlines: [commit.messageHeadline]), url: url
                ))
            }
        case "ReviewRequestedEvent":
            event(.reviewRequested, detail: node.requestedReviewer.flatMap { $0.login ?? $0.teamName })
        case "MergedEvent":
            event(.merged, detail: node.mergeCommit?.abbreviatedOid)
        case "ClosedEvent":
            event(.closed)
        case "ReopenedEvent":
            event(.reopened)
        case "ReadyForReviewEvent":
            event(.readyForReview)
        case "ConvertToDraftEvent":
            event(.convertedToDraft)
        case "HeadRefForcePushedEvent":
            event(.headRefForcePushed)
        case "AssignedEvent":
            event(.assigned, detail: node.assignee?.login)
        default:
            return
        }
    }

    private static func reviewState(_ raw: String?) -> ReviewState {
        switch raw {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "DISMISSED": return .dismissed
        case "PENDING": return .pending
        default: return .commented
        }
    }

    static func checkSummary(sha: String, rollup: GQLLastCommit.Commit.Rollup) -> CheckSummary {
        var failed: [String] = []
        var passed = 0
        var pending = 0
        for context in rollup.contexts.items {
            switch context.typename {
            case "CheckRun":
                let name = context.name ?? "check"
                if context.status != "COMPLETED" {
                    pending += 1
                } else {
                    switch context.conclusion {
                    case "SUCCESS", "NEUTRAL", "SKIPPED": passed += 1
                    case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": failed.append(name)
                    default: break
                    }
                }
            case "StatusContext":
                switch context.contextState {
                case "SUCCESS": passed += 1
                case "FAILURE", "ERROR": failed.append(context.context ?? "status")
                case "PENDING", "EXPECTED": pending += 1
                default: break
                }
            default:
                break
            }
        }
        let status: CheckStatus
        switch rollup.state {
        case "SUCCESS": status = .success
        case "FAILURE", "ERROR": status = .failure
        case "PENDING", "EXPECTED": status = .pending
        default: status = .neutral
        }
        return CheckSummary(status: status, commitSHA: sha, failedChecks: failed, passedCount: passed, pendingCount: pending)
    }

    /// The app behind the first failing check run (else any check run); commit statuses have no actor.
    private static func checksActor(_ contexts: [GQLCheckContext]) -> Actor {
        let runs = contexts.filter { $0.typename == "CheckRun" }
        let failing = runs.first { ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains($0.conclusion ?? "") }
        if let app = (failing ?? runs.first)?.checkSuite?.app {
            return Actor(login: app.slug, name: app.name, isBot: true)
        }
        return Actor(login: "checks", name: "Checks", isBot: true)
    }
}
