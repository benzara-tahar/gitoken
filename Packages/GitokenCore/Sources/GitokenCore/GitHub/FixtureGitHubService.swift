import Foundation
import Synchronization

/// Fictional, deterministic `GitHubService` for SwiftUI previews, `--fixtures` debug launches, and store tests.
/// Behaves like GitHub: done threads leave the listing until new activity, reads clear `unread`, and every scripted
/// arrival makes the next poll return `.updated`. Timestamps are relative to `now` at init (seed) or call time.
public final class FixtureGitHubService: GitHubService {
    public static let pollInterval: TimeInterval = 60

    let now: any NowProvider
    let state: Mutex<State>

    struct FixtureThread {
        let id: ThreadID
        let subject: FixtureSeed.Subject
        var state: SubjectState
        var unread: Bool
        var updatedAt: Date
        var lastReadAt: Date?
        var done: Bool
        var items: [TimelineItem]

        var repo: RepoRef { RepoRef(owner: "platform", name: subject.repo) }
        /// Fictional GraphQL node id of the PR/issue (`addReaction` subject for its description).
        var nodeID: String { "\(subject.kind == .pullRequest ? "PR" : "I")_fx\(id.rawValue)" }

        var notification: NotificationThread {
            let segment = subject.kind == .pullRequest ? "pulls" : "issues"
            return NotificationThread(
                id: id, repo: repo, kind: subject.kind, number: subject.number, title: subject.title,
                reason: subject.reason, unread: unread, updatedAt: updatedAt, lastReadAt: lastReadAt,
                subjectAPIURL: URL(string: "https://api.github.com/repos/\(repo.fullName)/\(segment)/\(subject.number)"),
                latestCommentAPIURL: nil, repoOwnerAvatarURL: nil
            )
        }
    }

    struct State {
        var threads: [FixtureThread] = []
        var version = 1
        var nextItem = 1
        var nextCommentDatabaseID = 9001
        var notifyCursor = 0
        var reopenCursor = 0
        /// Threads the client marked done, oldest call first.
        var doneCalls: [ThreadID] = []
        /// `addReaction` calls in order, as (subject node id, content).
        var reactions: [(subjectID: String, content: ReactionContent)] = []
        /// PR Shelf pull requests (see `FixtureGitHubService+PullRequests.swift`).
        var shelf: [FixtureShelfPR] = []

        func index(of key: String) -> Int? { threads.firstIndex { $0.subject.key == key } }
        func index(of id: ThreadID) -> Int? { threads.firstIndex { $0.id == id } }
        func index(repo: RepoRef, number: Int) -> Int? {
            threads.firstIndex { $0.repo == repo && $0.subject.number == number }
        }
    }

    public init(now: any NowProvider = SystemNow()) {
        self.now = now
        let start = now.now()
        var state = State()
        for seed in FixtureSeed.threads {
            Self.create(seed, relativeTo: start, in: &state)
        }
        state.shelf = FixtureSeed.shelfPullRequests(relativeTo: start)
        self.state = Mutex(state)
    }

    // MARK: Scripted arrivals

    public func enqueueNotification() async {
        let at = now.now()
        state.withLock { state in
            let arrival = FixtureSeed.notifications[state.notifyCursor % FixtureSeed.notifications.count]
            state.notifyCursor += 1
            var index = state.index(of: arrival.key)
            if index == nil, let create = arrival.create {
                Self.create(create, relativeTo: at, in: &state)
                index = state.threads.count - 1
            }
            guard let index else { return }
            Self.record(arrival.event, by: arrival.actor, at: at, onThreadAt: index, in: &state)
            Self.surface(index, at: at, in: &state)
        }
    }

    public func enqueueBurst() async {
        let at = now.now()
        state.withLock { state in
            guard let index = state.index(of: FixtureSeed.web142.key) else { return }
            let burst = FixtureSeed.burst
            for (offset, step) in burst.enumerated() {
                let time = at.addingTimeInterval(TimeInterval(offset - burst.count + 1))
                Self.record(step.event, by: step.actor, at: time, onThreadAt: index, in: &state)
            }
            Self.surface(index, at: at, in: &state)
        }
    }

    public func enqueueActivityOnDoneThread() async {
        let at = now.now()
        state.withLock { state in
            let threads = state.threads
            let oldestFirst = { (a: Int, b: Int) in threads[a].updatedAt < threads[b].updatedAt }
            let clientDone = state.doneCalls.reversed().compactMap { id in threads.firstIndex { $0.id == id } }
            let target = clientDone.first { threads[$0].done }
                ?? threads.indices.filter { threads[$0].done }.min(by: oldestFirst)
                ?? threads.indices.min(by: oldestFirst)
            guard let index = target else { return }
            let thread = state.threads[index]
            let scripts = thread.subject.kind == .issue ? FixtureSeed.reopenIssue : FixtureSeed.reopenPullRequest
            let event = scripts[state.reopenCursor % scripts.count]
            state.reopenCursor += 1
            Self.record(event, by: Self.otherActor(thread), at: at, onThreadAt: index, in: &state)
            Self.surface(index, at: at, in: &state)
        }
    }

    // MARK: GitHubService

    public func viewer() async throws(GitHubError) -> Actor {
        FixtureSeed.person(FixtureSeed.viewerLogin)
    }

    public func pollNotifications(lastModified: String?) async throws(GitHubError) -> NotificationPoll {
        state.withLock { state in
            let stamp = "fixture-\(state.version)"
            if lastModified == stamp { return .notModified(pollInterval: Self.pollInterval) }
            let threads = state.threads.filter { !$0.done }.sorted { $0.updatedAt > $1.updatedAt }.map(\.notification)
            return .updated(threads: threads, lastModified: stamp, pollInterval: Self.pollInterval)
        }
    }

    public func threadDetail(for thread: NotificationThread) async throws(GitHubError) -> ThreadDetail {
        guard thread.kind == .pullRequest || thread.kind == .issue else {
            throw .http(status: 404, message: "unsupported subject")
        }
        let fetchedAt = now.now()
        let detail: ThreadDetail? = state.withLock { state in
            guard let index = state.index(of: thread.id) else { return nil }
            let fixture = state.threads[index]
            let checks = fixture.items.reversed().lazy.compactMap { item -> CheckSummary? in
                if case .checks(let summary) = item.payload { return summary }
                return nil
            }.first
            return ThreadDetail(
                threadID: fixture.id, title: fixture.subject.title, state: fixture.state,
                author: FixtureSeed.person(fixture.subject.author), htmlURL: fixture.notification.htmlURL,
                items: fixture.items, checks: checks, fetchedAt: fetchedAt
            )
        }
        guard let detail else { throw .http(status: 404, message: "Not Found") }
        return detail
    }

    public func markRead(_ id: ThreadID) async throws(GitHubError) {
        let at = now.now()
        let found = state.withLock { state in
            guard let index = state.index(of: id) else { return false }
            state.threads[index].unread = false
            state.threads[index].lastReadAt = at
            state.version += 1
            return true
        }
        if !found { throw .http(status: 404, message: "Not Found") }
    }

    public func markDone(_ id: ThreadID) async throws(GitHubError) {
        let found = state.withLock { state in
            guard let index = state.index(of: id) else { return false }
            state.threads[index].done = true
            state.threads[index].unread = false
            state.doneCalls.removeAll { $0 == id }
            state.doneCalls.append(id)
            state.version += 1
            return true
        }
        if !found { throw .http(status: 404, message: "Not Found") }
    }

    public func postComment(repo: RepoRef, number: Int, body: String) async throws(GitHubError) -> TimelineItem {
        let at = now.now()
        let item: TimelineItem? = state.withLock { state in
            guard let index = state.index(repo: repo, number: number) else { return nil }
            Self.record(.comment(RichBody(markdown: body)), by: FixtureSeed.viewerLogin, at: at, onThreadAt: index, in: &state)
            return state.threads[index].items.last
        }
        guard let item else { throw .http(status: 404, message: "Not Found") }
        return item
    }

    public func replyToReviewComment(repo: RepoRef, number: Int, commentDatabaseID: Int, body: String)
        async throws(GitHubError) -> ReviewComment
    {
        let at = now.now()
        let reply: ReviewComment? = state.withLock { state in
            guard let index = state.index(repo: repo, number: number),
                let parent = Self.reviewComments(in: state.threads[index]).first(where: { $0.databaseID == commentDatabaseID })
            else { return nil }
            let comment = Self.makeReply(
                to: parent, by: FixtureSeed.viewerLogin, body: RichBody(markdown: body), at: at, in: &state)
            Self.appendReview(state: .commented, body: .empty, comments: [comment], by: FixtureSeed.viewerLogin, at: at, onThreadAt: index, in: &state)
            return comment
        }
        guard let reply else { throw .http(status: 404, message: "Not Found") }
        return reply
    }

    /// Records the call and adds the viewer's reaction to the matching description, comment, review, or review comment,
    /// so the next `threadDetail` shows it like GitHub would.
    public func addReaction(_ content: ReactionContent, subjectID: String) async throws(GitHubError) {
        let found = state.withLock { state in
            state.reactions.append((subjectID, content))
            for t in state.threads.indices {
                guard let items = state.threads[t].items.addingReaction(content, to: subjectID) else { continue }
                state.threads[t].items = items
                return true
            }
            return false
        }
        if !found { throw .graphQL(["Could not resolve to a node with the global id of '\(subjectID)'"]) }
    }

    /// `addReaction` calls so far, oldest first.
    public var reactionCalls: [(subjectID: String, content: ReactionContent)] { state.withLock { $0.reactions } }

    // MARK: State building

    private static func threadID(for subject: FixtureSeed.Subject) -> ThreadID {
        let repoCode = ["web": 1, "api": 2, "ui-kit": 3][subject.repo] ?? 9
        return ThreadID(String(repoCode * 100_000 + subject.number))
    }

    private static func create(_ seed: FixtureSeed.Thread, relativeTo start: Date, in state: inout State) {
        let subject = seed.subject
        state.threads.append(FixtureThread(
            id: threadID(for: subject), subject: subject, state: .open, unread: true, updatedAt: start, lastReadAt: nil,
            done: false, items: []
        ))
        let index = state.threads.count - 1
        for step in seed.steps {
            record(step.event, by: step.actor, at: start.addingTimeInterval(-step.minutesAgo * 60), onThreadAt: index, in: &state)
        }
        let items = state.threads[index].items
        state.threads[index].updatedAt = items.last?.createdAt ?? start
        switch seed.seen {
        case .none:
            break
        case .through(let count):
            state.threads[index].lastReadAt = items[min(count, items.count) - 1].createdAt
        case .all:
            state.threads[index].unread = false
            state.threads[index].lastReadAt = state.threads[index].updatedAt.addingTimeInterval(60)
        }
        if let doneMinutesAgo = seed.doneMinutesAgo {
            state.threads[index].done = true
            state.threads[index].unread = false
            state.threads[index].lastReadAt = start.addingTimeInterval(-doneMinutesAgo * 60)
        }
    }

    /// New activity: GitHub bumps `updated_at`, marks the thread unread, and resurfaces it if it was done.
    private static func surface(_ index: Int, at: Date, in state: inout State) {
        state.threads[index].updatedAt = at
        state.threads[index].unread = true
        state.threads[index].done = false
        state.version += 1
    }

    private static func record(_ event: FixtureSeed.Event, by login: String, at: Date, onThreadAt index: Int, in state: inout State) {
        let actor = FixtureSeed.person(login)
        let thread = state.threads[index]
        let url = thread.notification.htmlURL
        func append(_ payload: TimelinePayload) {
            let id: String
            if case .opened = payload {
                id = "\(TimelineItem.openedPrefix)\(thread.nodeID)"
            } else {
                id = "fx-item-\(state.nextItem)"
                state.nextItem += 1
            }
            state.threads[index].items.append(TimelineItem(id: id, actor: actor, createdAt: at, payload: payload, url: url))
        }

        switch event {
        case .opened(let body):
            append(.opened(body: body))
        case .comment(let body):
            append(.comment(body: body))
        case .reviewComment(let key, let hunk, let line, let body):
            let databaseID = state.nextCommentDatabaseID
            state.nextCommentDatabaseID += 1
            let comment = ReviewComment(
                id: "PRRC_fx\(key ?? String(databaseID))", databaseID: databaseID, author: actor, body: body,
                createdAt: at, path: hunk.file, diffHunk: hunk.diffHunk(endingAt: line), line: line, replyToID: nil,
                url: url.appending(path: "files")
            )
            appendReview(state: .commented, body: .empty, comments: [comment], by: login, at: at, onThreadAt: index, in: &state)
        case .reply(let key, let body):
            guard let parent = reviewComments(in: thread).first(where: { $0.id == "PRRC_fx\(key)" }) else { return }
            let comment = makeReply(to: parent, by: login, body: body, at: at, in: &state)
            appendReview(state: .commented, body: .empty, comments: [comment], by: login, at: at, onThreadAt: index, in: &state)
        case .review(let reviewState, let body):
            append(.review(state: reviewState, body: body, comments: []))
        case .checks(let summary):
            append(.checks(summary))
        case .push(let headlines):
            append(.commits(count: headlines.count, headlines: headlines))
        case .reviewRequested(let reviewer):
            append(.event(.reviewRequested, detail: reviewer))
        case .merged:
            append(.event(.merged, detail: nil))
            state.threads[index].state = .merged
        case .closed(let detail):
            append(.event(.closed, detail: detail))
            state.threads[index].state = .closed
        case .reopened(let detail):
            append(.event(.reopened, detail: detail))
            state.threads[index].state = .open
        }
    }

    private static func appendReview(
        state reviewState: ReviewState, body: RichBody, comments: [ReviewComment], by login: String, at: Date,
        onThreadAt index: Int, in state: inout State
    ) {
        let id = "fx-item-\(state.nextItem)"
        state.nextItem += 1
        let thread = state.threads[index]
        state.threads[index].items.append(TimelineItem(
            id: id, actor: FixtureSeed.person(login), createdAt: at,
            payload: .review(state: reviewState, body: body, comments: comments), url: thread.notification.htmlURL
        ))
    }

    private static func makeReply(to parent: ReviewComment, by login: String, body: RichBody, at: Date, in state: inout State)
        -> ReviewComment
    {
        let databaseID = state.nextCommentDatabaseID
        state.nextCommentDatabaseID += 1
        return ReviewComment(
            id: "PRRC_fx\(databaseID)", databaseID: databaseID, author: FixtureSeed.person(login), body: body,
            createdAt: at, path: parent.path, diffHunk: parent.diffHunk, line: parent.line,
            replyToID: parent.replyToID ?? parent.id, url: parent.url
        )
    }

    private static func reviewComments(in thread: FixtureThread) -> [ReviewComment] {
        thread.items.flatMap { item -> [ReviewComment] in
            if case .review(_, _, let comments) = item.payload { return comments }
            return []
        }
    }

    /// Most recent non-viewer human on the thread, else its author, else Leo.
    private static func otherActor(_ thread: FixtureThread) -> String {
        if let login = thread.items.reversed().map(\.actor).first(where: { $0.login != FixtureSeed.viewerLogin && !$0.isBot })?.login {
            return login
        }
        return thread.subject.author != FixtureSeed.viewerLogin ? thread.subject.author : "leom"
    }
}
