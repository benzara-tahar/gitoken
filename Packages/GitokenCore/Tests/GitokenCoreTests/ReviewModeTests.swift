import Foundation
import Synchronization
import Testing
@testable import GitokenCore

// MARK: - Comment positions

@Suite struct CommentPositionTests {
    /// 0 header · 1 ` a` · 2 `-b` · 3 `+B` · 4 `+C` · 5 ` c` · 6 ` d` · 7 header · 8 ` x` · 9 `-y` · 10 `+Y`
    let patch = "@@ -1,4 +1,5 @@\n a\n-b\n+B\n+C\n c\n d\n@@ -10,2 +11,2 @@\n x\n-y\n+Y"

    func document(_ mode: PreviewMode) -> PreviewDocument {
        let file = (1...14).map { "line \($0)" }.joined(separator: "\n") + "\n"
        return PreviewDocument.build(mode: mode, path: "a.ts", fileText: file, patch: patch, threads: [], viewing: .head("h"))
    }

    func right(_ line: Int, from start: Int? = nil) -> CommentPosition {
        CommentPosition(path: "a.ts", side: .right, line: line, startLine: start)
    }

    @Test func diffSelectionsStayInOneHunkOnOneSide() {
        let diff = document(.diff)
        func position(_ a: Int, _ b: Int) -> CommentPosition? { diff.commentPosition(from: a, to: b, path: "a.ts", patch: patch) }

        #expect(position(3, 3) == right(2), "an added line comments on its new line")
        #expect(position(2, 2) == CommentPosition(path: "a.ts", side: .left, line: 2, startLine: nil), "removed → left")
        #expect(position(9, 9) == CommentPosition(path: "a.ts", side: .left, line: 11, startLine: nil))
        #expect(position(4, 2) == right(3, from: 2), "mixed ranges use the right lines, in either drag direction")
        #expect(position(1, 2) == right(1), "context plus removed keeps only the single right line")
        #expect(position(5, 6) == right(5, from: 4))
        #expect(position(8, 10) == right(12, from: 11))
        #expect(position(6, 8) == nil, "a range may not cross hunks")
        #expect(position(0, 0) == nil && position(7, 7) == nil, "hunk headers are never commentable")
        #expect(position(10, 11) == nil && position(-1, 1) == nil)
    }

    @Test func fileSelectionsMustFallInsideOneHunksNewSide() {
        let file = document(.file)
        func position(_ a: Int, _ b: Int, patch: String?) -> CommentPosition? {
            file.commentPosition(from: a, to: b, path: "a.ts", patch: patch)
        }

        #expect(position(1, 2, patch: patch) == right(3, from: 2))
        #expect(position(0, 4, patch: patch) == right(5, from: 1), "the whole new side of the first hunk")
        #expect(position(10, 11, patch: patch) == right(12, from: 11))
        #expect(position(6, 6, patch: patch) == nil, "line 7 is outside every hunk")
        #expect(position(4, 10, patch: patch) == nil, "lines 5…11 span two hunks")
        #expect(position(1, 1, patch: nil) == nil, "nothing is commentable without a patch")
        #expect(position(1, 1, patch: "@@ -3,2 +2,0 @@\n-x\n-y") == nil, "pure deletions have no new side")
    }
}

// MARK: - Suggestions

@Suite struct SuggestionsTests {
    @Test func blocksAreSuggestionFencesOnly() {
        let markdown = """
            Two things:
            ```suggestion
            foo
              bar
            ```
            Not this one:
            ```ts
            const x = 1;
            ```
            ~~~~ suggestion with words
            baz
            ~~~~
            """
        #expect(Suggestions.blocks(in: markdown) == ["foo\n  bar", "baz"])
        #expect(Suggestions.blocks(in: "Fix:\r\n```suggestion\r\nx\r\ny\r\n```\r\n") == ["x\ny"], "CRLF bodies")
        #expect(Suggestions.blocks(in: "```suggestion\n```") == [""], "empty suggestion deletes")
        #expect(Suggestions.blocks(in: "```suggestion\n\n```") == ["\n"], "one blank line is not a deletion")
        #expect(Suggestions.blocks(in: "````md\n```suggestion\nx\n```\n````") == [], "fences inside other blocks")
        #expect(Suggestions.blocks(in: "```suggestion\nrest of the comment") == ["rest of the comment"], "unclosed")
        #expect(Suggestions.blocks(in: "```suggestions\nx\n```") == [])
    }

    func thread(
        _ body: String, side: DiffSide = .right, line: Int? = 5, startLine: Int? = 3, outdated: Bool = false,
        resolved: Bool = false, pending: Bool = false
    ) -> ReviewThread {
        let comment = ReviewComment(
            id: "C1", databaseID: 1, author: Actor(login: "schen"), body: RichBody(markdown: body), createdAt: Date(),
            path: "a.ts", diffHunk: "", line: line, replyToID: nil, url: nil, isPending: pending)
        return ReviewThread(
            id: "T1", isResolved: resolved, isOutdated: outdated, path: "a.ts", diffSide: side, line: line,
            startLine: startLine, originalLine: line, originalStartLine: startLine, originalCommitOID: "h", comments: [comment],
            viewerCanResolve: true, viewerCanUnresolve: true, viewerCanReply: true)
    }

    @Test func itemsOnlyForCurrentRightSideThreadsWithOneBlock() throws {
        let body = "Try:\n```suggestion\nnew\n```"
        let current = thread(body)
        #expect(Suggestions.item(for: try #require(current.root), in: current)
            == SuggestionItem(commentID: "C1", threadID: "T1", path: "a.ts", startLine: 3, endLine: 5, replacement: "new"))
        let single = thread(body, startLine: nil)
        #expect(Suggestions.item(for: try #require(single.root), in: single)?.startLine == 5)

        for rejected in [
            thread(body, outdated: true), thread(body, resolved: true), thread(body, pending: true),
            thread(body, side: .left), thread(body, line: nil), thread("No suggestion here"),
            thread("```suggestion\na\n```\n```suggestion\nb\n```"),
        ] {
            #expect(Suggestions.item(for: try #require(rejected.root), in: rejected) == nil)
        }
    }

    func item(_ id: String, _ start: Int, _ end: Int, _ replacement: String, path: String = "a.ts") -> SuggestionItem {
        SuggestionItem(commentID: id, threadID: "T\(id)", path: path, startLine: start, endLine: end, replacement: replacement)
    }

    @Test func applyReplacesBottomUpAndKeepsLineEndings() {
        let text = "1\n2\n3\n4\n5\n"
        #expect(Suggestions.apply([item("a", 4, 5, "four"), item("b", 2, 2, "two\ntwo-b")], to: text) == "1\ntwo\ntwo-b\n3\nfour\n")
        #expect(Suggestions.apply([item("a", 2, 3, "")], to: text) == "1\n4\n5\n", "empty replacement deletes")
        #expect(Suggestions.apply([item("a", 2, 2, "\n")], to: text) == "1\n\n3\n4\n5\n", "a blank line replaces")
        #expect(Suggestions.apply([], to: text) == text)

        #expect(Suggestions.apply([item("a", 2, 2, "B")], to: "a\nb") == "a\nB", "no trailing newline stays absent")
        #expect(Suggestions.apply([item("a", 2, 2, "B")], to: "a\nb\n") == "a\nB\n")
        #expect(Suggestions.apply([item("a", 3, 3, "")], to: "a\nb\nc") == "a\nb", "deleting the last line keeps no newline")
        #expect(Suggestions.apply([item("a", 2, 2, "")], to: "a\r\nb\n") == "a\r\n", "the survivor keeps its own ending")
        #expect(Suggestions.apply([item("a", 2, 3, "")], to: "a\nb\r\nc\r\n") == "a\n")
        #expect(Suggestions.apply([item("a", 2, 2, "")], to: "a\r\nb") == "a")
        #expect(Suggestions.apply([item("a", 1, 3, "")], to: "a\nb\nc\n") == "")

        #expect(Suggestions.apply([item("a", 2, 2, "x\ny")], to: "a\r\nb\r\nc\r\n") == "a\r\nx\r\ny\r\nc\r\n", "CRLF preserved")
        #expect(Suggestions.apply([item("a", 3, 3, "C")], to: "a\r\nb\r\nc") == "a\r\nb\r\nC")
    }

    @Test func applyRejectsOverlapsOutOfBoundsAndMixedPaths() {
        let text = "1\n2\n3\n4\n5\n"
        #expect(Suggestions.apply([item("a", 2, 3, "x"), item("b", 3, 4, "y")], to: text) == nil)
        #expect(Suggestions.apply([item("a", 5, 6, "x")], to: text) == nil)
        #expect(Suggestions.apply([item("a", 0, 1, "x")], to: text) == nil)
        #expect(Suggestions.apply([item("a", 3, 2, "x")], to: text) == nil)
        #expect(Suggestions.apply([item("a", 1, 1, "x"), item("b", 2, 2, "y", path: "b.ts")], to: text) == nil)
    }
}

// MARK: - GitHub client mutations (serialized with the other StubServer tests)

private let mutationResponse = Data("""
    {"data": {
      "addPullRequestReview": {"pullRequestReview": {"id": "PRR_new"}},
      "addPullRequestReviewThread": {"thread": {"id": "PRRT_new"}},
      "deletePullRequestReviewComment": {"pullRequestReview": {"id": "PRR_new"}},
      "submitPullRequestReview": {"pullRequestReview": {"id": "PRR_new"}},
      "deletePullRequestReview": {"pullRequestReview": {"id": "PRR_new"}},
      "createCommitOnBranch": {"commit": {"oid": "new0000"}}
    }}
    """.utf8)

extension GitHubClientTests {
    private func sent(_ request: URLRequest?) throws -> (query: String, variables: [String: Any]) {
        let body = try JSONSerialization.jsonObject(with: try #require(request?.httpBody)) as? [String: Any]
        return (body?["query"] as? String ?? "", body?["variables"] as? [String: Any] ?? [:])
    }

    @Test func reviewMutationsSendGitHubInputNames() async throws {
        let stub = StubServer { _ in .init(status: 200, body: mutationResponse) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)

        #expect(try await client.startPendingReview(pullRequestID: "PR_1", commitOID: "head0000") == "PRR_new")
        var (query, variables) = try sent(stub.requests.last)
        #expect(query.contains("addPullRequestReview(input: {pullRequestId: $pullRequestId, commitOID: $commitOID})"))
        #expect(variables["pullRequestId"] as? String == "PR_1" && variables["commitOID"] as? String == "head0000")

        let range = CommentPosition(path: "src/a.ts", side: .right, line: 12, startLine: 10)
        try await client.addPendingThread(reviewID: "PRR_new", position: range, body: "Extract this")
        (query, variables) = try sent(stub.requests.last)
        #expect(query.contains("addPullRequestReviewThread(input: {pullRequestReviewId: $pullRequestReviewId, path: $path"))
        #expect(query.contains("startLine: $startLine, startSide: $startSide"))
        #expect(variables["pullRequestReviewId"] as? String == "PRR_new")
        #expect(variables["path"] as? String == "src/a.ts" && variables["body"] as? String == "Extract this")
        #expect(variables["line"] as? Int == 12 && variables["side"] as? String == "RIGHT")
        #expect(variables["startLine"] as? Int == 10 && variables["startSide"] as? String == "RIGHT")

        try await client.addPendingThread(
            reviewID: "PRR_new", position: CommentPosition(path: "src/a.ts", side: .left, line: 4, startLine: nil), body: "Why?")
        (_, variables) = try sent(stub.requests.last)
        #expect(variables["side"] as? String == "LEFT" && variables["line"] as? Int == 4)
        #expect(variables["startLine"] == nil && variables["startSide"] == nil, "single-line comments omit the start")

        try await client.deletePendingComment("PRRC_9")
        (query, variables) = try sent(stub.requests.last)
        #expect(query.contains("deletePullRequestReviewComment(input: {id: $id})"))
        #expect(variables["id"] as? String == "PRRC_9")

        try await client.submitReview(pullRequestID: "PR_1", reviewID: "PRR_new", event: .requestChanges, body: "See inline")
        (query, variables) = try sent(stub.requests.last)
        #expect(query.contains("submitPullRequestReview(input: {pullRequestReviewId: $pullRequestReviewId, event: $event, body: $body})"))
        #expect(variables["pullRequestReviewId"] as? String == "PRR_new")
        #expect(variables["event"] as? String == "REQUEST_CHANGES" && variables["body"] as? String == "See inline")

        try await client.submitReview(pullRequestID: "PR_1", reviewID: nil, event: .approve, body: "")
        (query, variables) = try sent(stub.requests.last)
        #expect(query.contains("addPullRequestReview(input: {pullRequestId: $pullRequestId, event: $event, body: $body})"))
        #expect(variables["pullRequestId"] as? String == "PR_1" && variables["event"] as? String == "APPROVE")

        try await client.discardPendingReview("PRR_new")
        (query, variables) = try sent(stub.requests.last)
        #expect(query.contains("deletePullRequestReview(input: {pullRequestReviewId: $pullRequestReviewId})"))
        #expect(variables["pullRequestReviewId"] as? String == "PRR_new")
        #expect(stub.requests.allSatisfy { $0.url?.absoluteString == "https://api.github.com/graphql" && $0.httpMethod == "POST" })
    }

    @Test func commitFilesSendsBase64AdditionsWithTheExpectedHead() async throws {
        let stub = StubServer { _ in .init(status: 200, body: mutationResponse) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)

        let oid = try await client.commitFiles(
            repository: "fork/web", branch: "akim/debounce", expectedHeadOID: "head0000",
            headline: "Apply suggestions from code review", body: nil, files: [(path: "src/a.ts", contents: Data("x\n".utf8))])

        #expect(oid == "new0000")
        let (query, variables) = try sent(stub.requests.last)
        #expect(query.contains("createCommitOnBranch(input: $input)"))
        let input = try #require(variables["input"] as? [String: Any])
        #expect(input["branch"] as? [String: String] == ["repositoryNameWithOwner": "fork/web", "branchName": "akim/debounce"])
        #expect(input["message"] as? [String: String] == ["headline": "Apply suggestions from code review"])
        #expect(input["expectedHeadOid"] as? String == "head0000")
        let additions = (input["fileChanges"] as? [String: Any])?["additions"] as? [[String: String]]
        #expect(additions == [["path": "src/a.ts", "contents": "eAo="]])
    }

    @Test func pullRequestFilesListEveryPageWithCounts() async throws {
        let files = "https://api.github.com/repos/platform/web/pulls/142/files"
        let stub = StubServer { request in
            if request.url?.query?.contains("page=2") == true {
                return .init(status: 200, body: Data("""
                    [{"filename": "src/new.ts", "previous_filename": "src/old.ts", "status": "renamed", "additions": 1,
                      "deletions": 1, "patch": "@@ -1 +1 @@\\n-a\\n+b"}]
                    """.utf8))
            }
            return .init(
                status: 200, headers: ["Link": "<\(files)?per_page=100&page=2>; rel=\"next\""],
                body: Data(#"[{"filename": "logo.png", "status": "added", "additions": 0, "deletions": 0}]"#.utf8))
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)

        let listed = try await client.pullRequestFiles(PullRequestRef(repo: RepoRef(owner: "platform", name: "web"), number: 142))

        #expect(listed == [
            ChangedFile(path: "logo.png", previousPath: nil, status: .added, additions: 0, deletions: 0,
                        patch: FilePatch(status: .added, previousPath: nil, patch: nil)),
            ChangedFile(path: "src/new.ts", previousPath: "src/old.ts", status: .renamed, additions: 1, deletions: 1,
                        patch: FilePatch(status: .renamed, previousPath: "src/old.ts", patch: "@@ -1 +1 @@\n-a\n+b")),
        ])
        #expect(stub.requests.count == 2)
    }
}

// MARK: - Store against the fixture service

@MainActor
@Suite struct ReviewStoreTests {
    let uiKit = PullRequestRef(repo: RepoRef(owner: "platform", name: "ui-kit"), number: 298)
    let web = PullRequestRef(repo: RepoRef(owner: "platform", name: "web"), number: 142)
    let scss = "src/tokens/_spacing.scss"
    let codemod = "scripts/codemods/spacing.ts"

    func makeStore() -> (FilePreviewStore, RecordingPreviewService) {
        let service = RecordingPreviewService(FixtureGitHubService())
        let store = FilePreviewStore(
            service: service, now: SystemNow(), postReply: { _, _, _ in })
        return (store, service)
    }

    @Test func fixturePullRequestListsItsChangedFiles() async throws {
        let (store, _) = makeStore()
        let files = try await store.loadFiles(uiKit)
        #expect(files.map(\.path) == [codemod, scss, "src/tokens/spacing.json"])
        #expect(files.map(\.status) == [.added, .modified, .modified])
        #expect(files.map(\.additions) == [26, 10, 9] && files.map(\.deletions) == [0, 10, 9])
        #expect(store.changedFiles[uiKit] == files)
    }

    @Test func reviewCommentsStartOnePendingReviewThenSubmit() async throws {
        let (store, service) = makeStore()
        let line = CommentPosition(path: scss, side: .right, line: 5, startLine: nil)
        let range = CommentPosition(path: scss, side: .right, line: 12, startLine: 10)

        async let first: Void = store.addReviewComment("Why 2xs?", at: line, in: uiKit)
        async let second: Void = store.addReviewComment("Group these?", at: range, in: uiKit)
        _ = try await (first, second)
        try await store.addReviewComment("Removed on purpose?", at: CommentPosition(path: scss, side: .left, line: 4, startLine: nil), in: uiKit)

        #expect(service.calls("startPendingReview") == 1, "concurrent first comments share one pending review")
        var threads = try #require(store.threads[uiKit])
        #expect(threads.pendingReviewID != nil && threads.pendingCommentCount == 3)
        let pending = threads.threads.filter(\.isPending)
        #expect(pending.map(\.diffSide).sorted { $0.rawValue < $1.rawValue } == [.left, .right, .right])
        #expect(pending.first { $0.startLine == 10 }?.line == 12)
        #expect(pending.allSatisfy { Suggestions.item(for: $0.root!, in: $0) == nil })

        try await store.deletePendingComment(try #require(pending.first { $0.diffSide == .left }?.root?.id), in: uiKit)
        #expect(store.threads[uiKit]?.pendingCommentCount == 2)

        try await store.submitReview(.requestChanges, body: "A few naming questions.", in: uiKit)
        threads = try #require(store.threads[uiKit])
        #expect(threads.pendingReviewID == nil && threads.pendingCommentCount == 0)
        #expect(threads.threads.contains { $0.root?.body.markdown == "Group these?" && !$0.isPending })

        try await store.addReviewComment("One more", at: line, in: uiKit)
        #expect(service.calls("startPendingReview") == 2, "a submitted review is never reused")
        try await store.discardPendingReview(in: uiKit)
        #expect(store.threads[uiKit]?.pendingReviewID == nil)
        #expect(store.threads[uiKit]?.threads.contains { $0.root?.body.markdown == "One more" } == false)
    }

    @Test func ownPullRequestCannotBeApprovedOrRejected() async throws {
        let (store, service) = makeStore()
        for event in [ReviewEvent.approve, .requestChanges] {
            await #expect(throws: GitHubError.http(status: 422, message: FilePreviewStore.ownPullRequestMessage)) {
                try await store.submitReview(event, body: "LGTM", in: web)
            }
        }
        #expect(service.calls("submitReview") == 0)
        try await store.submitReview(.comment, body: "Notes to self", in: web)
        #expect(service.calls("submitReview") == 1)
    }

    @Test func batchRejectsOverlapsOnTheSamePath() throws {
        let (store, _) = makeStore()
        func item(_ id: String, _ path: String, _ start: Int, _ end: Int) -> SuggestionItem {
            SuggestionItem(commentID: id, threadID: "T\(id)", path: path, startLine: start, endLine: end, replacement: "x")
        }
        try store.addToBatch(item("a", scss, 4, 6), in: uiKit)
        #expect(throws: GitHubError.self) { try store.addToBatch(item("b", scss, 6, 8), in: uiKit) }
        try store.addToBatch(item("c", codemod, 6, 8), in: uiKit)
        try store.addToBatch(item("a", scss, 4, 6), in: uiKit)
        try store.addToBatch(item("d", scss, 7, 8), in: uiKit)
        #expect(store.suggestionBatches[uiKit]?.map(\.commentID) == ["a", "c", "d"])
        store.removeFromBatch("a", in: uiKit)
        store.removeFromBatch("c", in: uiKit)
        store.removeFromBatch("d", in: uiKit)
        #expect(store.suggestionBatches[uiKit] == nil)
    }

    /// Batches every applicable fixture suggestion on ui-kit#298.
    func batchFixtureSuggestions(_ store: FilePreviewStore) async throws -> [SuggestionItem] {
        _ = try await store.loadFiles(uiKit)
        let threads = try #require(store.threads[uiKit])
        let items = threads.threads.flatMap { thread in thread.comments.compactMap { Suggestions.item(for: $0, in: thread) } }
        for item in items { try store.addToBatch(item, in: uiKit) }
        return items
    }

    @Test func commitBatchAppliesSuggestionsAtANewHead() async throws {
        let (store, service) = makeStore()
        let items = try await batchFixtureSuggestions(store)
        #expect(Set(items.map(\.path)) == [scss, codemod])
        let oldHead = try #require(store.threads[uiKit]?.headOID)
        let before = try #require(try await service.fileContents(repo: uiKit.repo, path: scss, commit: oldHead))

        try await store.commitBatch(in: uiKit)

        let threads = try #require(store.threads[uiKit])
        #expect(threads.headOID != oldHead)
        #expect(store.suggestionBatches[uiKit] == nil)
        #expect(Set(items.map(\.threadID)).allSatisfy { id in threads.threads.first { $0.id == id }?.isResolved == true })
        #expect(store.changedFiles[uiKit] == nil, "the file list was listed at the old head")

        let scssText = String(decoding: try #require(try await service.fileContents(repo: uiKit.repo, path: scss, commit: threads.headOID)), as: UTF8.self)
        let expected = String(decoding: before, as: UTF8.self).replacingOccurrences(
            of: "  @return map.get((3xs: $space-3xs, 2xs: $space-2xs, xs: $space-xs), $step);",
            with: "  @return map.get((\"3xs\": $space-3xs, \"2xs\": $space-2xs, \"xs\": $space-xs), $step);")
        #expect(scssText == expected)

        let load = await store.load(PreviewTarget(threadID: ThreadID("1"), ref: uiKit, path: codemod, commentID: nil), commit: nil, forceLarge: false)
        guard case .loaded(let content) = load, case .text(let codemodText) = content.file else {
            Issue.record("expected the codemod at the new head")
            return
        }
        #expect(content.viewing == .head(threads.headOID))
        #expect(codemodText.contains("      if (typeof value === \"string\" && Object.hasOwn(renames, value)) {\n"))
        #expect(content.patch.patch?.contains("+      if (typeof value === \"string\" && Object.hasOwn(renames, value)) {") == true)

        let files = try await store.loadFiles(uiKit)
        #expect(files.first { $0.path == scss }?.patch.patch?.contains("+  @return map.get((\"3xs\"") == true)
        #expect(files.first { $0.path == "src/tokens/spacing.json" }?.additions == 9, "untouched files keep their seeded patch")
    }

    @Test func commitBatchReportsAMovedBranch() async throws {
        let (store, service) = makeStore()
        _ = try await batchFixtureSuggestions(store)
        service.pushBeforeCommit = true

        await #expect(throws: GitHubError.http(status: 409, message: FilePreviewStore.branchMovedMessage)) {
            try await store.commitBatch(in: uiKit, headline: "Apply")
        }
        #expect(store.suggestionBatches[uiKit]?.count == 2, "the batch survives a failed commit")
    }

    @Test func commitBatchKeepsTheNewHeadWhenTheRefreshFailsOrLags() async throws {
        for mode in [RecordingPreviewService.AfterCommit.fail, .stale] {
            let (store, service) = makeStore()
            _ = try await batchFixtureSuggestions(store)
            let oldHead = try #require(store.threads[uiKit]?.headOID)
            try await service.snapshotThreads(uiKit)
            service.afterCommit = mode

            try await store.commitBatch(in: uiKit)

            let pushed = try await service.base.reviewThreads(uiKit).headOID
            #expect(pushed != oldHead)
            #expect(store.threads[uiKit]?.headOID == pushed, "\(mode): threads point at the pushed head")
            let load = await store.load(
                PreviewTarget(threadID: ThreadID("1"), ref: uiKit, path: codemod, commentID: nil), commit: nil, forceLarge: false)
            guard case .loaded(let content) = load, case .text(let text) = content.file else {
                Issue.record("\(mode): expected the codemod")
                continue
            }
            #expect(content.viewing == .head(pushed))
            #expect(text.contains("Object.hasOwn(renames, value)"), "\(mode): the preview shows the committed change")
        }
    }

    @Test func suggestionsBatchedDuringTheCommitStayBatched() async throws {
        let (store, service) = makeStore()
        _ = try await batchFixtureSuggestions(store)
        service.hold("commitFiles")
        let commit = Task { try await store.commitBatch(in: uiKit) }
        await service.waitUntilHeld("commitFiles")
        let late = SuggestionItem(
            commentID: "late", threadID: "Tlate", path: "src/tokens/spacing.json", startLine: 2, endLine: 2, replacement: "x")
        try store.addToBatch(late, in: uiKit)
        service.release("commitFiles")
        try await commit.value
        #expect(store.suggestionBatches[uiKit] == [late])
    }

    @Test func submitWaitsForAnAddInFlight() async throws {
        let (store, service) = makeStore()
        service.hold("addPendingThread")
        let add = Task {
            try await store.addReviewComment("Why 2xs?", at: CommentPosition(path: scss, side: .right, line: 5, startLine: nil), in: uiKit)
        }
        await service.waitUntilHeld("addPendingThread")
        let submit = Task { try await store.submitReview(.comment, body: "Two questions.", in: uiKit) }
        for _ in 0..<50 { await Task.yield() }
        #expect(service.calls("submitReview") == 0, "submit waits until the add finished")
        service.release("addPendingThread")
        try await add.value
        try await submit.value

        let threads = try #require(store.threads[uiKit])
        #expect(threads.pendingReviewID == nil && threads.pendingCommentCount == 0)
        #expect(threads.threads.contains { $0.root?.body.markdown == "Why 2xs?" && !$0.isPending }, "the comment was submitted")
        #expect(service.calls("startPendingReview") == 1)
    }
}

/// Forwards to the fixture service, counting calls. `pushBeforeCommit` moves the branch just before `commitFiles`;
/// `afterCommit` makes later thread fetches fail or keep answering the pre-commit threads; `hold(_:)` parks the next
/// call of that name until `release(_:)`.
final class RecordingPreviewService: FilePreviewService {
    enum AfterCommit { case live, fail, stale }

    private struct State {
        var counts: [String: Int] = [:]
        var pushBeforeCommit = false
        var afterCommit = AfterCommit.live
        var preCommitThreads: [PullRequestRef: PullRequestReviewThreads] = [:]
        var committed = false
        var armed: Set<String> = []
        var held: [String: CheckedContinuation<Void, Never>] = [:]
    }

    let base: FixtureGitHubService
    private let state = Mutex(State())

    init(_ base: FixtureGitHubService) { self.base = base }

    var pushBeforeCommit: Bool {
        get { state.withLock { $0.pushBeforeCommit } }
        set { state.withLock { $0.pushBeforeCommit = newValue } }
    }

    var afterCommit: AfterCommit {
        get { state.withLock { $0.afterCommit } }
        set { state.withLock { $0.afterCommit = newValue } }
    }

    func calls(_ name: String) -> Int { state.withLock { $0.counts[name] ?? 0 } }
    private func count(_ name: String) { state.withLock { $0.counts[name, default: 0] += 1 } }

    func hold(_ name: String) { state.withLock { _ = $0.armed.insert(name) } }

    func waitUntilHeld(_ name: String) async {
        while state.withLock({ $0.held[name] == nil }) { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func release(_ name: String) {
        state.withLock { $0.held.removeValue(forKey: name) }?.resume()
    }

    private func gate(_ name: String) async {
        guard state.withLock({ $0.armed.remove(name) != nil }) else { return }
        await withCheckedContinuation { continuation in state.withLock { $0.held[name] = continuation } }
    }

    func reviewThreads(_ ref: PullRequestRef) async throws(GitHubError) -> PullRequestReviewThreads {
        let (committed, mode, snapshot) = state.withLock { ($0.committed, $0.afterCommit, $0.preCommitThreads[ref]) }
        if committed {
            switch mode {
            case .live: break
            case .fail: throw .transport("offline")
            case .stale: if let snapshot { return snapshot }
            }
        }
        return try await base.reviewThreads(ref)
    }
    func fileContents(repo: RepoRef, path: String, commit: String) async throws(GitHubError) -> Data? {
        try await base.fileContents(repo: repo, path: path, commit: commit)
    }
    func pullRequestFilePatch(_ ref: PullRequestRef, path: String) async throws(GitHubError) -> FilePatch {
        try await base.pullRequestFilePatch(ref, path: path)
    }
    func filePatch(repo: RepoRef, base baseOID: String, head: String, path: String) async throws(GitHubError) -> FilePatch {
        try await base.filePatch(repo: repo, base: baseOID, head: head, path: path)
    }
    func setThreadResolved(_ threadID: String, resolved: Bool) async throws(GitHubError) {
        try await base.setThreadResolved(threadID, resolved: resolved)
    }
    func pullRequestFiles(_ ref: PullRequestRef) async throws(GitHubError) -> [ChangedFile] {
        try await base.pullRequestFiles(ref)
    }
    func startPendingReview(pullRequestID: String, commitOID: String) async throws(GitHubError) -> String {
        count("startPendingReview")
        return try await base.startPendingReview(pullRequestID: pullRequestID, commitOID: commitOID)
    }
    func addPendingThread(reviewID: String, position: CommentPosition, body: String) async throws(GitHubError) {
        await gate("addPendingThread")
        try await base.addPendingThread(reviewID: reviewID, position: position, body: body)
    }
    func deletePendingComment(_ commentID: String) async throws(GitHubError) {
        try await base.deletePendingComment(commentID)
    }
    func submitReview(pullRequestID: String, reviewID: String?, event: ReviewEvent, body: String) async throws(GitHubError) {
        count("submitReview")
        try await base.submitReview(pullRequestID: pullRequestID, reviewID: reviewID, event: event, body: body)
    }
    func discardPendingReview(_ reviewID: String) async throws(GitHubError) {
        try await base.discardPendingReview(reviewID)
    }
    func commitFiles(
        repository: String, branch: String, expectedHeadOID: String, headline: String, body: String?,
        files: [(path: String, contents: Data)]
    ) async throws(GitHubError) -> String {
        await gate("commitFiles")
        if pushBeforeCommit {
            _ = try await base.commitFiles(
                repository: repository, branch: branch, expectedHeadOID: expectedHeadOID, headline: "Someone else's push",
                body: nil, files: [])
        }
        let oid = try await base.commitFiles(
            repository: repository, branch: branch, expectedHeadOID: expectedHeadOID, headline: headline, body: body,
            files: files)
        state.withLock { $0.committed = true }
        return oid
    }

    /// Remembers `ref`'s threads as they are now, for `afterCommit = .stale`.
    func snapshotThreads(_ ref: PullRequestRef) async throws {
        let threads = try await base.reviewThreads(ref)
        state.withLock { $0.preCommitThreads[ref] = threads }
    }
}
