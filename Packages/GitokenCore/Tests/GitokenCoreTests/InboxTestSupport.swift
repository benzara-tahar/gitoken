import Foundation
import Synchronization
@testable import GitokenCore

let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// 2026-10-02 14:00 UTC.
let t0 = utc.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 0))!

let me = Actor(login: "akim", name: "Akim")
let sarah = Actor(login: "sarah")
let omar = Actor(login: "omar")
let lea = Actor(login: "lea")
let nina = Actor(login: "nina")
let ciBot = Actor(login: "ci-bot", isBot: true)

let repo = RepoRef(owner: "acme", name: "web")

func makeThread(
    _ id: String, updatedAt: Date, unread: Bool = true, reason: NotificationReason = .reviewRequested,
    kind: SubjectKind = .pullRequest, lastReadAt: Date? = nil
) -> NotificationThread {
    NotificationThread(
        id: ThreadID(id), repo: repo, kind: kind, number: Int(id) ?? 1, title: "PR \(id)", reason: reason, unread: unread,
        updatedAt: updatedAt, lastReadAt: lastReadAt, subjectAPIURL: nil, latestCommentAPIURL: nil, repoOwnerAvatarURL: nil)
}

func comment(_ id: String, by actor: Actor, at date: Date, _ body: String = "Looks good") -> TimelineItem {
    TimelineItem(id: id, actor: actor, createdAt: date, payload: .comment(body: body), url: nil)
}

func review(_ id: String, by actor: Actor, at date: Date, _ state: ReviewState, comments: [ReviewComment] = []) -> TimelineItem {
    TimelineItem(id: id, actor: actor, createdAt: date, payload: .review(state: state, body: "", comments: comments), url: nil)
}

func reviewComment(_ id: String, databaseID: Int, by actor: Actor, at date: Date, _ body: String) -> ReviewComment {
    ReviewComment(
        id: id, databaseID: databaseID, author: actor, body: body, createdAt: date, path: "src/app.ts",
        diffHunk: "@@ -1,2 +1,2 @@\n-a\n+b", line: 2, replyToID: nil, url: nil)
}

extension NotificationThread {
    func with(updatedAt: Date? = nil, unread: Bool? = nil) -> NotificationThread {
        NotificationThread(
            id: id, repo: repo, kind: kind, number: number, title: title, reason: reason, unread: unread ?? self.unread,
            updatedAt: updatedAt ?? self.updatedAt, lastReadAt: lastReadAt, subjectAPIURL: subjectAPIURL,
            latestCommentAPIURL: latestCommentAPIURL, repoOwnerAvatarURL: repoOwnerAvatarURL)
    }
}

/// Scriptable in-memory GitHub: the listing holds threads GitHub considers not-done; `markDone` removes them,
/// `markRead` clears `unread`, new activity bumps `updatedAt` and sets `unread` like GitHub does.
final class ScriptedGitHub: GitHubService {
    struct State {
        var viewer: Result<Actor, GitHubError> = .success(me)
        var listing: [ThreadID: NotificationThread] = [:]
        var timelines: [ThreadID: [TimelineItem]] = [:]
        var version = 0
        var pollError: GitHubError?
        var detailErrors: [ThreadID: GitHubError] = [:]
        var markReadError: GitHubError?
        var postError: GitHubError?
        var markReadCalls: [ThreadID] = []
        var markDoneCalls: [ThreadID] = []
        var detailCalls: [ThreadID] = []
        var pollLastModified: [String?] = []
        var postedBodies: [String] = []
    }

    let state = Mutex(State())
    let clock: OffsetNow

    init(clock: OffsetNow) { self.clock = clock }

    func update<T: Sendable>(_ body: (inout State) -> T) -> T { state.withLock { body(&$0) } }

    /// A thread GitHub lists, with its current timeline.
    func add(_ id: String, at date: Date, unread: Bool = true, reason: NotificationReason = .reviewRequested,
             kind: SubjectKind = .pullRequest, items: [TimelineItem] = []) {
        update {
            $0.listing[ThreadID(id)] = makeThread(id, updatedAt: date, unread: unread, reason: reason, kind: kind)
            $0.timelines[ThreadID(id)] = items
            $0.version += 1
        }
    }

    /// New activity by someone else: GitHub re-lists the thread (even if it was done) as unread with a newer date.
    func activity(on id: String, _ item: TimelineItem) {
        update {
            let key = ThreadID(id)
            $0.timelines[key, default: []].append(item)
            let base = $0.listing[key] ?? makeThread(id, updatedAt: item.createdAt)
            $0.listing[key] = base.with(updatedAt: item.createdAt, unread: true)
            $0.version += 1
        }
    }

    /// Marked done on github.com: no longer in the listing.
    func doneElsewhere(_ id: String) {
        update {
            $0.listing[ThreadID(id)] = nil
            $0.version += 1
        }
    }

    func viewer() async throws(GitHubError) -> Actor { try update { $0.viewer }.get() }

    func pollNotifications(lastModified: String?) async throws(GitHubError) -> NotificationPoll {
        let result: Result<NotificationPoll, GitHubError> = update { s in
            s.pollLastModified.append(lastModified)
            if let error = s.pollError { return .failure(error) }
            let stamp = "v\(s.version)"
            if lastModified == stamp { return .success(.notModified(pollInterval: 60)) }
            let threads = s.listing.values.sorted { $0.id.rawValue < $1.id.rawValue }
            return .success(.updated(threads: threads, lastModified: stamp, pollInterval: 60))
        }
        return try result.get()
    }

    func threadDetail(for thread: NotificationThread) async throws(GitHubError) -> ThreadDetail {
        let now = clock.now()
        let result: Result<ThreadDetail, GitHubError> = update { s in
            s.detailCalls.append(thread.id)
            if let error = s.detailErrors[thread.id] { return .failure(error) }
            return .success(ThreadDetail(
                threadID: thread.id, title: thread.title, state: .open, author: sarah, htmlURL: thread.htmlURL,
                items: s.timelines[thread.id] ?? [], checks: nil, fetchedAt: now))
        }
        return try result.get()
    }

    func markRead(_ id: ThreadID) async throws(GitHubError) {
        let error: GitHubError? = update { s in
            s.markReadCalls.append(id)
            if let error = s.markReadError { return error }
            if let thread = s.listing[id] { s.listing[id] = thread.with(unread: false) }
            s.version += 1
            return nil
        }
        if let error { throw error }
    }

    func markDone(_ id: ThreadID) async throws(GitHubError) {
        update { s in
            s.markDoneCalls.append(id)
            s.listing[id] = nil
            s.version += 1
        }
    }

    func postComment(repo: RepoRef, number: Int, body: String) async throws(GitHubError) -> TimelineItem {
        let now = clock.now()
        let result: Result<TimelineItem, GitHubError> = update { s in
            if let error = s.postError { return .failure(error) }
            s.postedBodies.append(body)
            let item = TimelineItem(id: "posted-\(s.postedBodies.count)", actor: me, createdAt: now, payload: .comment(body: body), url: nil)
            s.timelines[ThreadID(String(number)), default: []].append(item)
            return .success(item)
        }
        return try result.get()
    }

    func replyToReviewComment(repo: RepoRef, number: Int, commentDatabaseID: Int, body: String)
        async throws(GitHubError) -> ReviewComment
    {
        let now = clock.now()
        return update { s in
            s.postedBodies.append(body)
            return ReviewComment(
                id: "reply-\(s.postedBodies.count)", databaseID: 9000 + s.postedBodies.count, author: me, body: body,
                createdAt: now, path: "src/app.ts", diffHunk: "", line: 2, replyToID: nil, url: nil)
        }
    }
}

@MainActor
struct Harness {
    let clock: OffsetNow
    let github: ScriptedGitHub
    let database: GitokenDatabase
    var store: InboxStore

    init(at instant: Date = t0) throws {
        clock = OffsetNow.fixed(instant)
        github = ScriptedGitHub(clock: clock)
        database = try GitokenDatabase.inMemory()
        store = InboxStore(service: github, database: database, now: clock, calendar: utc)
    }

    /// A second store over the same database, as after an app relaunch.
    func relaunched() -> InboxStore {
        InboxStore(service: github, database: database, now: clock, calendar: utc)
    }

    func group(_ id: String) -> InboxGroup? { store.groups.first { $0.id == ThreadID(id) } }

    func bucket(_ id: String) -> InboxBucket? { group(id)?.bucket(at: clock.now()) }

    /// Moves the clock and runs the store's time-based checks, like the minute timer would.
    func advance(minutes: Double) {
        clock.advance(by: minutes * 60)
        store.tick()
    }

    var now: Date { clock.now() }
}
