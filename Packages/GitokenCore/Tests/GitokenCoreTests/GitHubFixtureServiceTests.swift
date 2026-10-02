import Foundation
import Testing
@testable import GitokenCore

@Suite struct GitHubFixtureServiceTests {
    let now = OffsetNow.fixed(Date(timeIntervalSince1970: 1_790_000_000))

    private func listing(_ service: FixtureGitHubService, since lastModified: String? = nil) async throws
        -> (threads: [NotificationThread], lastModified: String?)
    {
        guard case .updated(let threads, let stamp, let interval) = try await service.pollNotifications(lastModified: lastModified) else {
            Issue.record("expected .updated")
            return ([], nil)
        }
        #expect(interval >= 60)
        return (threads, stamp)
    }

    private func thread(_ threads: [NotificationThread], _ repo: String, _ number: Int) throws -> NotificationThread {
        try #require(threads.first { $0.repo.name == repo && $0.number == number })
    }

    @Test func seedListsNotDoneThreadsNewestFirstThenReportsNotModified() async throws {
        let service = FixtureGitHubService(now: now)
        let (threads, stamp) = try await listing(service)

        #expect(threads.map { "\($0.repo.name)#\($0.number!)" } == [
            "ui-kit#311", "api#87", "web#142", "web#128", "api#91", "ui-kit#298", "ui-kit#305",
        ])
        #expect(threads.allSatisfy { $0.updatedAt <= now.now() })
        #expect(try thread(threads, "api", 87).updatedAt == now.now().addingTimeInterval(-22 * 60))
        #expect(try thread(threads, "web", 142).unread)
        #expect(try thread(threads, "web", 142).lastReadAt != nil, "partially read thread keeps a read boundary")
        #expect(try !thread(threads, "api", 91).unread)
        #expect(try thread(threads, "api", 87).reason == .reviewRequested)

        #expect(try await service.pollNotifications(lastModified: stamp) == .notModified(pollInterval: 60))
    }

    @Test func doneThreadLeavesListingUntilNewActivity() async throws {
        let service = FixtureGitHubService(now: now)
        let (threads, _) = try await listing(service)
        let target = try thread(threads, "api", 91)

        try await service.markDone(target.id)
        let (afterDone, stamp) = try await listing(service)
        #expect(!afterDone.contains { $0.id == target.id })

        now.advance(by: 120)
        await service.enqueueActivityOnDoneThread()
        let (afterActivity, _) = try await listing(service, since: stamp)
        let resurfaced = try #require(afterActivity.first)
        #expect(resurfaced.id == target.id, "newest activity sorts first")
        #expect(resurfaced.unread)
        #expect(resurfaced.updatedAt == now.now())

        let detail = try await service.threadDetail(for: resurfaced)
        let last = try #require(detail.items.last)
        #expect(last.createdAt == now.now())
        #expect(last.actor.login != "akim")
    }

    @Test func activityOnDoneThreadWithoutClientDonePicksOldestDoneThread() async throws {
        let service = FixtureGitHubService(now: now)
        await service.enqueueActivityOnDoneThread()
        let (threads, _) = try await listing(service)
        let reopened = try thread(threads, "api", 80)
        #expect(reopened.unread)
        let detail = try await service.threadDetail(for: reopened)
        #expect(detail.state == .open, "issue script reopens it")
        #expect(detail.items.last?.payload == .event(.reopened, detail: "Still reproducible on v2.14.1 — reopening."))
    }

    @Test func burstLandsOnWeb142AsOneUpdate() async throws {
        let service = FixtureGitHubService(now: now)
        let (_, stamp) = try await listing(service)
        let before = try await service.threadDetail(for: try thread(try await listing(service).threads, "web", 142)).items.count

        await service.enqueueBurst()

        let (threads, _) = try await listing(service, since: stamp)
        let pr = try thread(threads, "web", 142)
        #expect(threads.first?.id == pr.id)
        let detail = try await service.threadDetail(for: pr)
        let added = Array(detail.items.dropFirst(before))
        #expect(added.count == 4)
        #expect(added.contains { if case .review(.changesRequested, _, _) = $0.payload { return true } else { return false } })
        #expect(added.contains { if case .review(_, _, let comments) = $0.payload { return !comments.isEmpty } else { return false } })
        #expect(detail.checks?.status == .failure)
        #expect(detail.checks?.failedChecks == ["unit-tests"])
    }

    @Test func enqueueNotificationCreatesScriptedNewThread() async throws {
        let service = FixtureGitHubService(now: now)
        await service.enqueueNotification()
        let (threads, _) = try await listing(service)
        let created = try thread(threads, "web", 147)
        #expect(threads.first?.id == created.id)
        #expect(created.reason == .reviewRequested)
        #expect(created.kind == .pullRequest)
        let detail = try await service.threadDetail(for: created)
        #expect(detail.items.map(\.payload).last == .event(.reviewRequested, detail: "akim"))
    }

    @Test func reviewCommentsCarryDiffHunkEndingAtCommentedLine() async throws {
        let service = FixtureGitHubService(now: now)
        let pr = try thread(try await listing(service).threads, "web", 142)
        let comments = try await service.threadDetail(for: pr).items.flatMap { item -> [ReviewComment] in
            if case .review(_, _, let comments) = item.payload { return comments }
            return []
        }
        let root = try #require(comments.first { $0.line == 37 && $0.replyToID == nil })
        #expect(root.path == "src/components/SearchBox.tsx")
        #expect(root.diffHunk.hasPrefix("@@ -28,13 +28,18 @@"))
        #expect(root.diffHunk.hasSuffix("+  }, [debounced, onSearch]);"))
        let leoReply = try #require(comments.first { $0.replyToID == root.id })
        #expect(leoReply.author.login == "leom")

        let mine = try await service.replyToReviewComment(
            repo: pr.repo, number: 142, commentDatabaseID: leoReply.databaseID, body: "Moved it into a ref."
        )
        #expect(mine.replyToID == root.id, "replies thread under the root comment")
        #expect(mine.author.login == "akim")
        #expect(mine.diffHunk == root.diffHunk)
    }

    @Test func markReadClearsUnreadAndPostCommentAppends() async throws {
        let service = FixtureGitHubService(now: now)
        let issue = try thread(try await listing(service).threads, "ui-kit", 311)
        #expect(issue.unread)

        try await service.markRead(issue.id)
        #expect(try thread(try await listing(service).threads, "ui-kit", 311).unread == false)

        let item = try await service.postComment(repo: issue.repo, number: 311, body: "Looking now.")
        #expect(item.payload == .comment(body: "Looking now."))
        #expect(item.actor.login == "akim")
        #expect(try await service.threadDetail(for: issue).items.last == item)

        await #expect(throws: GitHubError.http(status: 404, message: "Not Found")) {
            try await service.markRead(ThreadID("missing"))
        }
    }
}
