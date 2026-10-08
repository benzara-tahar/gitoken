import Foundation
import Synchronization
import Testing
@testable import GitokenCore

// MARK: - GitHub client (serialized with the other StubServer tests)

extension GitHubClientTests {
    @Test func reviewThreadsMapThreadsCommentsAndCommits() async throws {
        let stub = StubServer { _ in .init(status: 200, body: Data(reviewThreadsResponse.utf8)) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        let ref = PullRequestRef(repo: RepoRef(owner: "platform", name: "web"), number: 142)

        let result = try await client.reviewThreads(ref)

        #expect(result.ref == ref)
        #expect(result.headOID == "head0000")
        #expect(result.baseOID == "base0000")
        #expect(result.pullRequestID == "PR_kwDO142")
        #expect(result.headRefName == "akim/debounce-search")
        #expect(result.headRepository == "akim/web")
        #expect(result.pendingReviewID == "PRR_pending")
        #expect(result.viewerIsAuthor)
        #expect(result.pendingCommentCount == 1)
        #expect(result.threads.map(\.id) == ["PRRT_1", "PRRT_2"])

        let current = try #require(result.threads.first)
        #expect(!current.isResolved && !current.isOutdated)
        #expect(current.path == "src/components/SearchBox.tsx")
        #expect(current.diffSide == .right)
        #expect(current.line == 37 && current.startLine == 35)
        #expect(current.originalCommitOID == "head0000")
        #expect(current.viewerCanReply && current.viewerCanResolve && !current.viewerCanUnresolve)
        #expect(current.comments.map(\.id) == ["PRRC_1", "PRRC_3"])
        #expect(current.root?.databaseID == 9001)
        #expect(current.root?.author.login == "schen")
        #expect(current.comments.last?.replyToID == "PRRC_1")
        #expect(current.comments.last?.reactions == [ReactionCount(content: .thumbsUp, count: 2, viewerHasReacted: true)])
        #expect(current.comments.map(\.isPending) == [false, true])
        #expect(!current.isPending, "a submitted root keeps the thread out of the pending review")

        let outdated = try #require(result.threads.last)
        #expect(outdated.isResolved && outdated.isOutdated)
        #expect(outdated.diffSide == .left)
        #expect(outdated.line == nil && outdated.originalLine == 12)
        #expect(outdated.originalCommitOID == "orig0000", "first comment's original commit")
        #expect(outdated.root?.line == 12, "comment line falls back to originalLine")

        #expect(result.thread(containing: "PRRC_3")?.id == "PRRT_1")
        #expect(result.threads(on: "src/components/ResultList.tsx").map(\.id) == ["PRRT_2"])
    }

    @Test func pullRequestFilesFollowPagesAndMatchRenamesByPreviousName() async throws {
        let files = "https://api.github.com/repos/platform/web/pulls/142/files"
        let stub = StubServer { request in
            if request.url?.query?.contains("page=2") == true {
                return .init(status: 200, body: Data("""
                    [{"filename": "src/new/Search.tsx", "previous_filename": "src/old/Search.tsx", "status": "renamed",
                      "patch": "@@ -1,2 +1,2 @@\\n-a\\n+b\\n c"}]
                    """.utf8))
            }
            return .init(
                status: 200, headers: ["Link": "<\(files)?per_page=100&page=2>; rel=\"next\""],
                body: Data(#"[{"filename": "README.md", "status": "modified", "patch": "@@ -1 +1 @@\n-x\n+y"}]"#.utf8))
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        let ref = PullRequestRef(repo: RepoRef(owner: "platform", name: "web"), number: 142)

        let renamed = try await client.pullRequestFilePatch(ref, path: "src/old/Search.tsx")
        #expect(renamed == FilePatch(status: .renamed, previousPath: "src/old/Search.tsx", patch: "@@ -1,2 +1,2 @@\n-a\n+b\n c"))
        let requests = stub.requests
        #expect(requests.count == 2)
        #expect(requests.first?.url?.path == "/repos/platform/web/pulls/142/files")
        let firstQuery = URLComponents(url: try #require(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(firstQuery.contains(URLQueryItem(name: "per_page", value: "100")))

        #expect(try await client.pullRequestFilePatch(ref, path: "src/Absent.tsx") == .unchanged)
    }

    @Test func comparePatchReadsFilesFromTheFirstPageOnly() async throws {
        let stub = StubServer { request in
            .init(
                status: 200, headers: ["Link": "<\(request.url!.absoluteString)&page=2>; rel=\"next\""],
                body: Data(#"{"commits": [], "files": [{"filename": "src/a.ts", "status": "added", "patch": "diff --git a/src/a.ts b/src/a.ts\n@@ -0,0 +1 @@\n+x"}]}"#.utf8))
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        let repo = RepoRef(owner: "platform", name: "web")

        let added = try await client.filePatch(repo: repo, base: "base0000", head: "orig0000", path: "src/a.ts")
        #expect(added == FilePatch(status: .added, previousPath: nil, patch: "@@ -0,0 +1 @@\n+x"))
        #expect(try await client.filePatch(repo: repo, base: "base0000", head: "orig0000", path: "src/b.ts") == .unchanged)
        #expect(stub.requests.count == 2, "compare's Link pages list commits, never more files")
        #expect(stub.requests.first?.url?.path == "/repos/platform/web/compare/base0000...orig0000")
    }

    @MainActor
    @Test(arguments: [false, true])
    func remotePreviewKeepsFileDiffAndFocusedThreadAtTheViewedCommit(outdated: Bool) async throws {
        let path = outdated ? "src/components/ResultList.tsx" : "src/components/SearchBox.tsx"
        let commit = outdated ? "orig0000" : "head0000"
        let commentID = outdated ? "PRRC_2" : "PRRC_1"
        let threadID = outdated ? "PRRT_2" : "PRRT_1"
        let text = (1...40).map { "remote line \($0)" }.joined(separator: "\n") + "\n"
        let patch = outdated
            ? "@@ -10,4 +10,4 @@\n one\n two\n-old\n+new\n four"
            : "@@ -35,3 +35,3 @@\n a\n-b\n+c\n d"
        let file: [String: String] = ["filename": path, "status": "modified", "patch": patch]
        let diffResponse = if outdated {
            try JSONSerialization.data(withJSONObject: ["files": [file]])
        } else {
            try JSONSerialization.data(withJSONObject: [file])
        }
        let diffPath = outdated
            ? "/repos/platform/web/compare/base0000...orig0000"
            : "/repos/platform/web/pulls/142/files"
        let stub = StubServer { request in
            if request.url?.path == "/graphql" {
                return .init(status: 200, body: Data(reviewThreadsResponse.utf8))
            }
            if request.url?.path == "/repos/platform/web/contents/\(path)" {
                let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
                guard query?.contains(URLQueryItem(name: "ref", value: commit)) == true else {
                    return .init(status: 404, body: Data())
                }
                return .init(status: 200, body: Data(text.utf8))
            }
            if request.url?.path == diffPath {
                return .init(status: 200, body: diffResponse)
            }
            return .init(status: 404, body: Data())
        }
        let store = FilePreviewStore(
            service: GitHubClient(tokens: StubTokens(), session: stub.session),
            now: SystemNow(), postReply: { _, _, _ in })
        let target = PreviewTarget(
            threadID: ThreadID("1"), ref: PullRequestRef(repo: RepoRef(owner: "platform", name: "web"), number: 142),
            path: path, commentID: commentID)

        let loaded = await store.load(target, commit: nil, forceLarge: false)
        guard case .loaded(let content) = loaded else {
            Issue.record("The remote preview failed to load: \(loaded)")
            return
        }
        #expect(content.viewing == (outdated ? .original(commit) : .head(commit)))
        #expect(content.file == .text(text))
        #expect(content.patch == FilePatch(status: .modified, previousPath: nil, patch: patch))
        let document = await store.document(for: content, mode: .diff)
        #expect(document.anchors.map(\.threadID) == [threadID])
        #expect(document.unanchored.isEmpty)
        let fileDocument = await store.document(for: content, mode: .file)
        #expect(fileDocument.lines.count == 40)
        #expect(fileDocument.lines.first?.text == "remote line 1")
        #expect(fileDocument.lines.last?.text == "remote line 40")
        #expect(store.threads[target.ref]?.thread(containing: commentID)?.root?.body.plainText
            == (outdated ? "Old key" : "Use a ref"))
        #expect(store.threads[target.ref]?.pendingCommentCount == 1)
    }
}

private let reviewThreadsResponse = """
    {"data": {"repository": {"pullRequest": {
      "id": "PR_kwDO142", "headRefOid": "head0000", "baseRefOid": "base0000", "headRefName": "akim/debounce-search",
      "headRepository": {"nameWithOwner": "akim/web"}, "viewerDidAuthor": true,
      "reviews": {"nodes": [{"id": "PRR_pending"}]},
      "reviewThreads": {"nodes": [
        {"id": "PRRT_1", "isResolved": false, "isOutdated": false, "path": "src/components/SearchBox.tsx",
         "diffSide": "RIGHT", "line": 37, "startLine": 35, "originalLine": 37, "originalStartLine": 35,
         "viewerCanResolve": true, "viewerCanUnresolve": false, "viewerCanReply": true,
         "comments": {"nodes": [
           {"id": "PRRC_1", "databaseId": 9001,
            "author": {"__typename": "User", "login": "schen", "avatarUrl": null, "name": "Sarah Chen"},
            "body": "Use a ref", "bodyHTML": "<p>Use a ref</p>", "bodyText": "Use a ref", "createdAt": "2026-09-30T13:30:00Z",
            "path": "src/components/SearchBox.tsx", "diffHunk": "@@ -28,13 +28,18 @@", "line": 37, "originalLine": 37,
            "replyTo": null, "url": "https://github.com/platform/web/pull/142#discussion_r9001", "reactionGroups": [],
            "state": "SUBMITTED", "originalCommit": {"oid": "head0000"}},
           {"id": "PRRC_3", "databaseId": 9003,
            "author": {"__typename": "User", "login": "leom", "avatarUrl": null, "name": "Leo Martins"},
            "body": "+1", "bodyHTML": null, "bodyText": "+1", "createdAt": "2026-09-30T13:49:00Z",
            "path": "src/components/SearchBox.tsx", "diffHunk": "@@ -28,13 +28,18 @@", "line": 37, "originalLine": 37,
            "replyTo": {"id": "PRRC_1"}, "url": null,
            "reactionGroups": [{"content": "THUMBS_UP", "viewerHasReacted": true, "reactors": {"totalCount": 2}}],
            "state": "PENDING", "originalCommit": {"oid": "head0000"}}
         ]}},
        {"id": "PRRT_2", "isResolved": true, "isOutdated": true, "path": "src/components/ResultList.tsx",
         "diffSide": "LEFT", "line": null, "startLine": null, "originalLine": 12, "originalStartLine": null,
         "viewerCanResolve": false, "viewerCanUnresolve": true, "viewerCanReply": true,
         "comments": {"nodes": [
           {"id": "PRRC_2", "databaseId": 9002,
            "author": {"__typename": "Bot", "login": "copilot", "avatarUrl": null},
            "body": "Old key", "createdAt": "2026-09-30T13:31:00Z",
            "path": "src/components/ResultList.tsx", "diffHunk": "@@ -10,4 +10,4 @@", "line": null, "originalLine": 12,
            "replyTo": null, "url": null, "originalCommit": {"oid": "orig0000"}}
         ]}}
      ]}
    }}}}
    """

// MARK: - Store

@MainActor
@Suite struct FilePreviewStoreTests {
    let ref = PullRequestRef(repo: RepoRef(owner: "platform", name: "web"), number: 142)

    @Test func overlappingResolvesOnlyLetTheNewestRollBackToTheConfirmedState() async throws {
        let service = GatedResolveService(ref: ref)
        let store = FilePreviewStore(
            service: service, now: SystemNow(), postReply: { _, _, _ in })
        _ = await store.load(PreviewTarget(threadID: ThreadID("1"), ref: ref, path: "a.ts", commentID: nil), commit: nil, forceLarge: false)
        func resolved() -> Bool? { store.threads[ref]?.threads.first?.isResolved }
        #expect(resolved() == false)

        // Resolve, then unresolve before GitHub answers; the stale resolve fails after the unresolve landed.
        let resolve = Task { try await store.setResolved("T", in: ref, resolved: true) }
        await service.waitForCalls(1)
        #expect(resolved() == true)
        let unresolve = Task { try await store.setResolved("T", in: ref, resolved: false) }
        await service.waitForCalls(2)
        service.answer(1, succeed: true)
        try await unresolve.value
        service.answer(0, succeed: false)
        await #expect(throws: GitHubError.self) { try await resolve.value }
        #expect(resolved() == false, "an older failure never overrides a newer change")

        // Double resolve where both fail: back to the last confirmed state, not the first call's optimistic one.
        let first = Task { try await store.setResolved("T", in: ref, resolved: true) }
        await service.waitForCalls(3)
        let second = Task { try await store.setResolved("T", in: ref, resolved: true) }
        await service.waitForCalls(4)
        service.answer(2, succeed: false)
        await #expect(throws: GitHubError.self) { try await first.value }
        #expect(resolved() == true, "the newer call is still in flight")
        service.answer(3, succeed: false)
        await #expect(throws: GitHubError.self) { try await second.value }
        #expect(resolved() == false)
    }
}

/// Holds every `setThreadResolved` call until the test answers it.
private final class GatedResolveService: FilePreviewService {
    private let threads: PullRequestReviewThreads
    private let calls = Mutex<[CheckedContinuation<Bool, Never>?]>([])

    init(ref: PullRequestRef) {
        let thread = ReviewThread(
            id: "T", isResolved: false, isOutdated: false, path: "a.ts", diffSide: .right, line: 1, startLine: nil,
            originalLine: 1, originalStartLine: nil, originalCommitOID: "aaaa1111", comments: [], viewerCanResolve: true,
            viewerCanUnresolve: true, viewerCanReply: true)
        threads = PullRequestReviewThreads(
            ref: ref, pullRequestID: "PR_1", headOID: "aaaa1111", baseOID: "bbbb2222", headRefName: "feature",
            headRepository: ref.repo.fullName, pendingReviewID: nil, viewerIsAuthor: false, threads: [thread],
            fetchedAt: Date())
    }

    func waitForCalls(_ count: Int) async {
        while calls.withLock({ $0.count }) < count { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func answer(_ index: Int, succeed: Bool) {
        let continuation = calls.withLock { calls in
            defer { calls[index] = nil }
            return calls[index]
        }
        continuation?.resume(returning: succeed)
    }

    func reviewThreads(_ ref: PullRequestRef) async throws(GitHubError) -> PullRequestReviewThreads { threads }
    func fileContents(repo: RepoRef, path: String, commit: String) async throws(GitHubError) -> Data? { Data("x".utf8) }
    func pullRequestFilePatch(_ ref: PullRequestRef, path: String) async throws(GitHubError) -> FilePatch { .unchanged }
    func filePatch(repo: RepoRef, base: String, head: String, path: String) async throws(GitHubError) -> FilePatch { .unchanged }
    func setThreadResolved(_ threadID: String, resolved: Bool) async throws(GitHubError) {
        let succeed = await withCheckedContinuation { continuation in calls.withLock { $0.append(continuation) } }
        if !succeed { throw .http(status: 502, message: nil) }
    }
    func pullRequestFiles(_ ref: PullRequestRef) async throws(GitHubError) -> [ChangedFile] { [] }
    func startPendingReview(pullRequestID: String, commitOID: String) async throws(GitHubError) -> String {
        throw .http(status: 501, message: nil)
    }
    func addPendingThread(reviewID: String, position: CommentPosition, body: String) async throws(GitHubError) {}
    func deletePendingComment(_ commentID: String) async throws(GitHubError) {}
    func submitReview(pullRequestID: String, reviewID: String?, event: ReviewEvent, body: String) async throws(GitHubError) {}
    func discardPendingReview(_ reviewID: String) async throws(GitHubError) {}
    func commitFiles(
        repository: String, branch: String, expectedHeadOID: String, headline: String, body: String?,
        files: [(path: String, contents: Data)]
    ) async throws(GitHubError) -> String { throw .http(status: 501, message: nil) }
}

