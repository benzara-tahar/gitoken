import Foundation
import Synchronization
import Testing
@testable import GitokenCore

// MARK: - Support

private let webRepo = RepoRef(owner: "platform", name: "web")

private func ref(_ number: Int, repo: RepoRef = webRepo) -> PullRequestRef { PullRequestRef(repo: repo, number: number) }

private func pr(
    _ number: Int, repo: RepoRef = webRepo, author: Actor = me, state: SubjectState = .open, ci: CheckStatus? = .pending,
    sha: String = "aaa111", decision: ReviewDecision = .reviewRequired, mergeable: MergeableState = .mergeable,
    activity: ActivityPreview? = nil, updatedAt: Date = t0
) -> PullRequestStatus {
    PullRequestStatus(
        nodeID: "PR_\(number)", ref: ref(number, repo: repo), title: "PR \(number)", author: author, state: state, isDraft: false,
        headRefName: "branch-\(number)", headRefOID: sha, baseRefName: "main", isCrossRepository: false,
        checks: ci.map { CheckSummary(status: $0, commitSHA: sha, failedChecks: $0 == .failure ? ["unit-tests"] : [], passedCount: 3, pendingCount: 0) },
        reviewDecision: decision, mergeable: mergeable, unresolvedThreadCount: 0, latestHumanActivity: activity,
        updatedAt: updatedAt, viewerCanMerge: true, allowedMergeMethods: [.squash]
    )
}

/// In-memory GitHub for the shelf: `mine` is what the "my open PRs" search returns; lookups see `mine` + `others`.
private final class FakePullRequests: PullRequestService {
    struct State {
        var mine: [PullRequestStatus] = []
        var others: [PullRequestStatus] = []
        var merges: [(PullRequestRef, MergeMethod, String)] = []
        var lookups: [[PullRequestRef]] = []
    }
    let state = Mutex(State())

    func setMine(_ statuses: [PullRequestStatus]) { state.withLock { $0.mine = statuses } }
    func setOthers(_ statuses: [PullRequestStatus]) { state.withLock { $0.others = statuses } }

    func myOpenPullRequests() async throws(GitHubError) -> [PullRequestStatus] { state.withLock { $0.mine } }

    func pullRequests(_ refs: [PullRequestRef]) async throws(GitHubError) -> [PullRequestStatus] {
        state.withLock { state in
            state.lookups.append(refs)
            let all = state.mine + state.others
            return refs.compactMap { ref in all.first { $0.ref == ref } }
        }
    }

    func merge(_ pr: PullRequestStatus, method: MergeMethod) async throws(GitHubError) {
        state.withLock { state in
            state.merges.append((pr.ref, method, pr.headRefOID))
            state.mine.removeAll { $0.ref == pr.ref }
            state.others.removeAll { $0.ref == pr.ref }
            state.others.append(GitokenCoreTests.pr(pr.ref.number, state: .merged, ci: .success, decision: .approved))
        }
    }

    func agentContext(for ref: PullRequestRef) async throws(GitHubError) -> String { "" }
}

@MainActor
private final class ShelfHarness {
    let service = FakePullRequests()
    let database: GitokenDatabase
    var settings = ShelfSettings()
    var quiet: QuietReason?
    var account: AccountKey? = AccountKey(login: "akim")

    init(database: GitokenDatabase? = nil) throws {
        self.database = try database ?? .inMemory()
    }

    func makeStore() -> ShelfStore {
        ShelfStore(
            service: service, database: database, now: OffsetNow.fixed(t0),
            account: { [unowned self] in self.account }, settings: { [unowned self] in self.settings },
            quietReason: { [unowned self] in self.quiet })
    }
}

// MARK: - Event detection

@MainActor
@Suite struct ShelfStoreEventTests {
    @Test func firstLoadIsSilentEvenForInterestingStates() async throws {
        let h = try ShelfHarness()
        h.service.setMine([
            pr(1, ci: .failure), pr(2, ci: .success, decision: .approved), pr(3, ci: .success, mergeable: .conflicting),
        ])
        let store = h.makeStore()
        await store.refresh()
        #expect(store.items.map(\.id) == [ref(1), ref(2), ref(3)])
        #expect(store.pulse == nil)
        #expect(store.overnightChanges.isEmpty)
    }

    @Test func ciFailureFiresOnceAndANewFailingCommitFiresAgain() async throws {
        let h = try ShelfHarness()
        h.service.setMine([pr(1, ci: .pending)])
        let store = h.makeStore()
        await store.refresh()

        h.service.setMine([pr(1, ci: .failure)])
        await store.refresh()
        let first = try #require(store.pulse)
        #expect(first.events.map(\.kind) == [.ciFailed])
        #expect(first.events.first?.summary == "CI failed on #1")

        await store.refresh()
        #expect(store.pulse == first)

        h.service.setMine([pr(1, ci: .failure, sha: "bbb222")])
        await store.refresh()
        #expect(store.pulse?.id == first.id + 1)
        #expect(store.pulse?.events.map(\.kind) == [.ciFailed])
    }

    @Test func readyToMergeFiresOnceWhenTheLastConditionFlips() async throws {
        let h = try ShelfHarness()
        h.service.setMine([pr(1, ci: .success, decision: .approved, mergeable: .conflicting)])
        let store = h.makeStore()
        await store.refresh()

        h.service.setMine([pr(1, ci: .success, decision: .approved, mergeable: .mergeable)])
        await store.refresh()
        let pulse = try #require(store.pulse)
        #expect(pulse.events.map(\.kind) == [.readyToMerge])
        #expect(store.status(for: ref(1))?.isReadyToMerge == true)

        await store.refresh()
        #expect(store.pulse == pulse)
    }

    @Test func approvalOnAGreenPRFiresApprovedAndReadyToMergeWithTheReviewer() async throws {
        let h = try ShelfHarness()
        h.service.setMine([pr(1, ci: .success)])
        let store = h.makeStore()
        await store.refresh()

        let approval = ActivityPreview(actor: sarah, verb: .approved, snippet: "LGTM", at: t0.addingTimeInterval(60))
        h.service.setMine([pr(1, ci: .success, decision: .approved, activity: approval)])
        await store.refresh()
        let events = try #require(store.pulse).events
        #expect(events.map(\.kind) == [.approved, .readyToMerge])
        #expect(events.first?.actor == sarah)
    }

    @Test func disabledKindsNeitherPulseNorLog() async throws {
        let h = try ShelfHarness()
        h.settings.events = [.approved]
        h.service.setMine([pr(1, ci: .pending), pr(2, ci: .pending)])
        let store = h.makeStore()
        await store.refresh()

        h.service.setMine([pr(1, ci: .failure), pr(2, ci: .pending)])
        await store.refresh()
        #expect(store.pulse == nil)

        h.quiet = .manual
        h.service.setMine([pr(1, ci: .failure, sha: "bbb222"), pr(2, ci: .pending, decision: .approved)])
        await store.refresh()
        #expect(store.overnightChanges.map(\.kind) == [.approved])
    }

    @Test func newHumanCommentFiresButARepeatedPollDoesNot() async throws {
        let h = try ShelfHarness()
        let old = ActivityPreview(actor: sarah, verb: .commented, snippet: "hm", at: t0)
        h.service.setMine([pr(1, activity: old)])
        let store = h.makeStore()
        await store.refresh()

        let reply = ActivityPreview(actor: omar, verb: .commented, snippet: "Fixed?", at: t0.addingTimeInterval(120))
        h.service.setMine([pr(1, activity: reply)])
        await store.refresh()
        #expect(store.pulse?.events.map(\.kind) == [.newComment])
        #expect(store.pulse?.events.first?.summary == "omar commented on #1")
        let id = store.pulse?.id
        await store.refresh()
        #expect(store.pulse?.id == id)
    }

    @Test func quietSuppressesThePulseButKeepsStateAndTheOvernightLog() async throws {
        let h = try ShelfHarness()
        h.service.setMine([pr(1, ci: .pending), pr(2, ci: .success, decision: .approved, mergeable: .conflicting)])
        let store = h.makeStore()
        await store.refresh()

        h.quiet = .quietHours(until: ClockTime(hour: 9, minute: 0))
        h.service.setMine([pr(1, ci: .failure), pr(2, ci: .success, decision: .approved, mergeable: .mergeable)])
        await store.refresh()
        #expect(store.pulse == nil)
        #expect(store.status(for: ref(1))?.checks?.status == .failure)
        #expect(Set(store.overnightChanges.map(\.kind)) == [.ciFailed, .readyToMerge])

        // Survives a relaunch until the morning summary takes it.
        let relaunched = h.makeStore()
        #expect(relaunched.overnightChanges.map(\.id) == store.overnightChanges.map(\.id))
        let lines = ShelfEvent.overnightLines(relaunched.takeOvernightChanges())
        #expect(Set(lines) == ["CI failed on #1", "#2 is ready to merge"])
        #expect(relaunched.overnightChanges.isEmpty)
        #expect(h.makeStore().overnightChanges.isEmpty)

        h.quiet = nil
        h.service.setMine([pr(1, ci: .success), pr(2, ci: .success, decision: .approved, mergeable: .mergeable)])
        await relaunched.refresh()
        #expect(relaunched.pulse?.events.map(\.kind) == [.ciPassed])
    }

    @Test func changesWhileTheAppWasClosedFireAfterRelaunch() async throws {
        let h = try ShelfHarness()
        h.service.setMine([pr(1, ci: .pending)])
        await h.makeStore().refresh()

        h.service.setMine([pr(1, ci: .success)])
        let relaunched = h.makeStore()
        #expect(relaunched.items.map(\.id) == [ref(1)])
        await relaunched.refresh()
        #expect(relaunched.pulse?.events.map(\.kind) == [.ciPassed])
    }

    @Test func ownPRMergedElsewhereAnnouncesMergedAndLeavesTheShelf() async throws {
        let h = try ShelfHarness()
        h.settings.events.insert(.merged)
        h.service.setMine([pr(1), pr(2)])
        let store = h.makeStore()
        await store.refresh()

        h.service.setMine([pr(2)])
        h.service.setOthers([pr(1, state: .merged, ci: .success, decision: .approved)])
        await store.refresh()
        #expect(store.pulse?.events.map(\.kind) == [.merged])
        #expect(store.items.map(\.id) == [ref(2)])

        await store.refresh()
        #expect(h.service.state.withLock { $0.lookups } == [[ref(1)]])
    }

    @Test func mergingFromTheShelfSendsTheHeadSHAAndRaisesNoEvent() async throws {
        let h = try ShelfHarness()
        h.service.setMine([pr(1, ci: .success, sha: "c0ffee", decision: .approved)])
        let store = h.makeStore()
        await store.refresh()

        try await store.merge(ref(1), method: .squash)
        #expect(h.service.state.withLock { $0.merges.map(\.2) } == ["c0ffee"])
        #expect(store.items.isEmpty)
        await store.refresh()
        #expect(store.pulse == nil)
    }
}

// MARK: - Pins

@MainActor
@Suite struct ShelfPinTests {
    @Test func pinsAndUnpinsPersistAcrossStoreRecreation() async throws {
        let h = try ShelfHarness()
        h.service.setMine([pr(1)])
        h.service.setOthers([pr(87, author: sarah, ci: .success)])
        let store = h.makeStore()
        await store.refresh()

        let pinned = try await store.pin(url: URL(string: "https://github.com/platform/web/pull/87/files#diff-1")!)
        #expect(pinned == ref(87))
        #expect(store.pulse == nil)

        let relaunched = h.makeStore()
        let item = try #require(relaunched.items.first { $0.id == ref(87) })
        #expect(item.isPinned && !item.isMine)
        await relaunched.refresh()
        #expect(relaunched.items.map(\.id).contains(ref(87)))

        relaunched.unpin(ref(87))
        #expect(!relaunched.items.map(\.id).contains(ref(87)))
        let again = h.makeStore()
        #expect(again.items.map(\.id) == [ref(1)])
        await again.refresh()
        #expect(again.items.map(\.id) == [ref(1)])
    }

    @Test func pinnedPRsReportEventsAndStayAfterMerging() async throws {
        let h = try ShelfHarness()
        h.settings.events.insert(.merged)
        h.service.setOthers([pr(87, author: sarah, ci: .pending)])
        let store = h.makeStore()
        await store.refresh()
        try await store.pin(ref(87))

        h.service.setOthers([pr(87, author: sarah, ci: .failure)])
        await store.refresh()
        #expect(store.pulse?.events.map(\.kind) == [.ciFailed])

        h.service.setOthers([pr(87, author: sarah, state: .merged, ci: .success)])
        await store.refresh()
        #expect(store.pulse?.events.map(\.kind) == [.merged])
        #expect(store.items.first?.status.state == .merged)
    }

    @Test func unpinningAnOwnPRKeepsItOnTheShelf() async throws {
        let h = try ShelfHarness()
        h.service.setMine([pr(1)])
        let store = h.makeStore()
        await store.refresh()
        try await store.pin(ref(1))
        #expect(store.items.first?.isPinned == true)
        store.unpin(ref(1))
        #expect(store.items.map(\.id) == [ref(1)])
        #expect(store.items.first?.isPinned == false)
    }

    @Test func rejectsNonPullRequestURLsAndUnknownPRs() async throws {
        let h = try ShelfHarness()
        let store = h.makeStore()
        await #expect(throws: ShelfError.notAPullRequestURL) {
            try await store.pin(url: URL(string: "https://github.com/platform/web/issues/12")!)
        }
        await #expect(throws: ShelfError.notFound) {
            try await store.pin(url: URL(string: "https://github.com/platform/web/pull/404")!)
        }
        #expect(store.items.isEmpty)
        #expect(h.makeStore().items.isEmpty)
    }

    @Test func pinsAreScopedToTheAccount() async throws {
        let h = try ShelfHarness()
        h.service.setOthers([pr(87, author: sarah)])
        let store = h.makeStore()
        try await store.pin(ref(87))

        h.account = AccountKey(login: "someone-else")
        h.service.setMine([])
        await store.refresh()
        #expect(store.items.isEmpty)
    }
}

// MARK: - Overnight summary lines

@Suite struct ShelfOvernightLineTests {
    @Test func laterResultsSupersedeEarlierOnes() {
        func event(_ kind: ShelfEventKind, _ number: Int, _ minutes: Double) -> ShelfEvent {
            ShelfEvent(kind: kind, ref: ref(number), title: "PR", at: t0.addingTimeInterval(minutes * 60))
        }
        let lines = ShelfEvent.overnightLines([
            event(.ciFailed, 1, 0), event(.ciPassed, 1, 10), event(.approved, 1, 11), event(.readyToMerge, 1, 11),
            event(.ciPassed, 2, 0), event(.ciFailed, 2, 30), event(.ciFailed, 2, 40),
            event(.newComment, 3, 5), event(.merged, 3, 50),
        ])
        #expect(lines == ["#1 is ready to merge", "CI failed on #2", "#3 was merged"])
    }
}

// MARK: - URL parsing

@Suite struct PullRequestRefURLTests {
    @Test(arguments: [
        ("https://github.com/platform/web/pull/142", 142),
        ("https://github.com/platform/web/pull/142/files", 142),
        ("https://github.com/platform/web/pull/142/files#diff-3f2a", 142),
        ("https://github.com/platform/web/pull/142#issuecomment-1", 142),
        ("https://github.com/platform/web/pull/142?w=1", 142),
        ("https://github.com/platform/web/pull/142/", 142),
        ("https://GitHub.com/platform/web/pull/7", 7),
        ("http://github.com/platform/web/pull/7", 7),
    ])
    func accepts(_ text: String, _ number: Int) throws {
        let parsed = try #require(PullRequestRef(url: URL(string: text)!))
        #expect(parsed == ref(number))
        #expect(parsed.htmlURL.absoluteString == "https://github.com/platform/web/pull/\(number)")
    }

    @Test(arguments: [
        "https://github.com/platform/web/issues/142",
        "https://github.com/platform/web/pull/",
        "https://github.com/platform/web/pull/abc",
        "https://github.com/platform/web/pull/0",
        "https://github.com/platform/web/pull/-3",
        "https://github.com/platform/web",
        "https://api.github.com/repos/platform/web/pulls/142",
        "https://gitlab.com/platform/web/pull/142",
        "https://github.com.evil.example/platform/web/pull/142",
        "file:///platform/web/pull/142",
    ])
    func rejects(_ text: String) {
        #expect(PullRequestRef(url: URL(string: text)!) == nil)
    }
}

// MARK: - Agent context

@Suite struct AgentContextTests {
    let context = AgentContext(
        ref: ref(142), title: "Debounce search", headRefName: "akim/debounce", baseRefName: "main",
        body: "<!-- template: describe your change -->\nDebounces the input.\n\n\n\nCloses #131.",
        threads: [
            AgentContext.ReviewThread(
                path: "src/SearchBox.tsx", line: 37, isResolved: false, isOutdated: false,
                diffHunk: "@@ -28,3 +28,4 @@\n const a = 1;\n+const debounced = useDebouncedValue(value, 250);",
                comments: [.init(author: "sarah", body: "Keep the callback in a ref?"), .init(author: "omar", body: "+1\n\nAlso the cleanup.")]),
            AgentContext.ReviewThread(
                path: "src/Old.tsx", line: 3, isResolved: true, isOutdated: false, diffHunk: "@@ -1 +1 @@\n+resolved hunk",
                comments: [.init(author: "lea", body: "Already handled")]),
            AgentContext.ReviewThread(
                path: "src/ResultList.tsx", line: nil, isResolved: false, isOutdated: true, diffHunk: "@@ -1 +1 @@\n+key={index}",
                comments: [.init(author: "sarah", body: "Use ```result.id``` here")]),
        ],
        failingChecks: [
            .init(name: "lint", detailsURL: URL(string: "https://github.com/platform/web/actions/runs/1"), summary: nil,
                  logTail: "error  Do not use Array index in keys"),
            .init(name: "ci/circleci: e2e", detailsURL: nil, summary: "Your tests failed on CircleCI", logTail: nil),
        ])

    @Test func includesUnresolvedThreadsWithHunksAndFailingChecks() {
        let md = context.markdown
        #expect(md.contains("## Unresolved review threads (2)"))
        #expect(md.contains("### `src/SearchBox.tsx:37`"))
        #expect(md.contains("```diff\n@@ -28,3 +28,4 @@\n const a = 1;\n+const debounced = useDebouncedValue(value, 250);\n```"))
        #expect(md.contains("**@sarah**:\n> Keep the callback in a ref?"))
        #expect(md.contains("**@omar**:\n> +1\n>\n> Also the cleanup."))
        #expect(md.contains("### `src/ResultList.tsx` (outdated)"))
        #expect(!md.contains("resolved hunk") && !md.contains("Already handled"))
        #expect(md.contains("## Failing checks (2)\n\n### lint\n\nhttps://github.com/platform/web/actions/runs/1"))
        #expect(md.contains("```\nerror  Do not use Array index in keys\n```"))
        #expect(md.contains("### ci/circleci: e2e\n\nYour tests failed on CircleCI"))
    }

    @Test func descriptionDropsTemplateCommentsAndBlankRuns() {
        let md = context.markdown
        #expect(!md.contains("template: describe"))
        #expect(md.contains("## Description\n\nDebounces the input.\n\nCloses #131."))
    }

    @Test func longDescriptionsAndHunksAreTrimmed() {
        let longBody = (1...400).map { "Line \($0) of a very long description." }.joined(separator: "\n")
        let hunk = (["@@ -1,60 +1,60 @@"] + (1...60).map { " line \($0)" }).joined(separator: "\n")
        let md = AgentContext(
            ref: ref(1), title: "T", headRefName: "h", baseRefName: "main", body: longBody,
            threads: [.init(path: "a.swift", line: 60, isResolved: false, isOutdated: false, diffHunk: hunk, comments: [])],
            failingChecks: []
        ).markdown
        #expect(md.contains("Line 1 of"))
        #expect(!md.contains("Line 400 of"))
        #expect(md.contains("\n…\n"))
        #expect(md.contains("@@ -1,60 +1,60 @@\n …\n line 37\n"))
        #expect(md.contains(" line 60\n```"))
        #expect(!md.contains(" line 36\n"))
    }

    @Test func logTailStripsTimestampsColorsAndGroupMarkers() {
        let log = """
            2026-10-02T13:12:40.1180000Z ##[group]Run pnpm lint
            2026-10-02T13:12:40.1200000Z ##[endgroup]
            2026-10-02T13:12:49.3310000Z
            2026-10-02T13:12:49.3380000Z \u{1B}[31m✖ 2 problems\u{1B}[39m
            2026-10-02T13:12:49.4010000Z ##[error]Process completed with exit code 1.
            2026-10-02T13:12:49.5000000Z Post job cleanup.
            2026-10-02T13:12:49.5100000Z [command]/usr/bin/git version
            2026-10-02T13:12:49.5200000Z git version 2.52.0
            """
        #expect(AgentContext.logTail(log) == "Run pnpm lint\n✖ 2 problems\n##[error]Process completed with exit code 1.")
        #expect(AgentContext.logTail(log, lines: 1) == "##[error]Process completed with exit code 1.")
    }

    @Test func fixtureContextForAFailingPRCarriesThreadsAndLogTails() async throws {
        let fixtures = FixtureGitHubService(now: OffsetNow.fixed(t0))
        let md = try await fixtures.agentContext(for: PullRequestRef(repo: RepoRef(owner: "platform", name: "web"), number: 142))
        #expect(md.contains("## Unresolved review threads (2)"))
        #expect(md.contains("src/components/SearchBox.tsx:37"))
        #expect(md.contains("## Failing checks (2)"))
        #expect(md.contains("react/no-array-index-key"))
        #expect(!md.contains("2026-10-02T13:"))
    }
}

// MARK: - Fixture transitions

@MainActor
@Suite struct ShelfFixtureTests {
    @Test func scriptedTransitionsDriveShelfEvents() async throws {
        let fixtures = FixtureGitHubService(now: OffsetNow.fixed(t0))
        let store = ShelfStore(
            service: fixtures, database: try .inMemory(), now: OffsetNow.fixed(t0), account: { AccountKey(login: "akim") },
            settings: { ShelfSettings(events: ShelfSettings.defaultEvents.union([.merged])) }, quietReason: { nil })
        await store.refresh()
        #expect(store.items.count == 5)
        #expect(store.items.filter { $0.status.isReadyToMerge }.map(\.id.number) == [305])

        await fixtures.applyShelfTransition(.approve142)
        await fixtures.applyShelfTransition(.ciPasses142)
        await store.refresh()
        #expect(store.pulse?.events.map(\.kind) == [.ciPassed, .approved, .readyToMerge])

        await fixtures.applyShelfTransition(.merged305)
        await store.refresh()
        #expect(store.pulse?.events.map(\.kind) == [.merged])
        #expect(!store.items.map(\.id.number).contains(305))
    }
}

// MARK: - GitHubClient mapping

@Suite(.serialized) struct GitHubClientPullRequestTests {
    @Test func myOpenPullRequestsMapsStatusAndToleratesSSOErrors() async throws {
        let server = ShelfStubServer { request in
            #expect(request.url?.path == "/graphql")
            return ShelfStubReply(status: 200, body: Data(Self.searchResponse.utf8))
        }
        let client = GitHubClient(tokens: ShelfStubTokens(), session: server.session)
        let statuses = try await client.myOpenPullRequests()
        let status = try #require(statuses.first)
        #expect(statuses.count == 1)
        #expect(status.ref == ref(142))
        #expect(status.checks?.status == .failure)
        #expect(status.checks?.failedChecks == ["lint"])
        #expect(status.reviewDecision == .approved)
        #expect(status.mergeable == .conflicting)
        #expect(status.unresolvedThreadCount == 1)
        #expect(status.allowedMergeMethods == [.squash, .rebase])
        #expect(status.viewerCanMerge)
        #expect(status.latestHumanActivity?.actor?.login == "sarah")
        #expect(status.latestHumanActivity?.verb == .approved)

        let body = try #require(server.requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["variables"] as? [String: String])?["query"] == "is:pr is:open author:@me archived:false sort:updated-desc")
    }

    @Test func agentContextFetchesActionsLogsWithoutForwardingTheToken() async throws {
        let server = ShelfStubServer { request in
            switch request.url?.host {
            case "api.github.com" where request.url?.path == "/graphql":
                return ShelfStubReply(status: 200, body: Data(Self.agentContextResponse.utf8))
            case "api.github.com" where request.url?.path == "/repos/platform/web/actions/jobs/77/logs":
                return ShelfStubReply(status: 302, headers: ["Location": "https://logs.example.test/job-77.txt?sig=x"])
            case "logs.example.test":
                return ShelfStubReply(status: 200, body: Data("2026-10-02T13:00:00.0000000Z npm ERR! lint failed\n".utf8))
            default:
                return ShelfStubReply(status: 404)
            }
        }
        let client = GitHubClient(tokens: ShelfStubTokens(), session: server.session)
        let md = try await client.agentContext(for: ref(142))
        #expect(md.contains("### `src/a.ts:9`"))
        #expect(md.contains("+let x = 1"))
        #expect(!md.contains("resolved one"))
        #expect(md.contains("### lint"))
        #expect(md.contains("```\nnpm ERR! lint failed\n```"))
        #expect(md.contains("### ci/legacy"))
        let download = try #require(server.requests.first { $0.url?.host == "logs.example.test" })
        #expect(download.value(forHTTPHeaderField: "Authorization") == nil)
    }

    static let searchResponse = """
        {"data":{"viewer":{"login":"akim"},"search":{"nodes":[
          null,
          {"__typename":"Issue"},
          {"__typename":"PullRequest","id":"PR_1","number":142,"title":"Debounce","state":"OPEN","isDraft":false,"merged":false,
           "updatedAt":"2026-10-02T13:00:00Z","headRefName":"akim/debounce","headRefOid":"abc","baseRefName":"main",
           "isCrossRepository":false,"reviewDecision":"APPROVED","mergeable":"CONFLICTING",
           "author":{"__typename":"User","login":"akim","avatarUrl":null,"name":"Akim"},
           "repository":{"name":"web","owner":{"login":"platform"},"viewerPermission":"WRITE","mergeCommitAllowed":false,
             "squashMergeAllowed":true,"rebaseMergeAllowed":true},
           "reviewThreads":{"nodes":[{"isResolved":true},{"isResolved":false}]},
           "comments":{"nodes":[
             {"author":{"__typename":"User","login":"akim","avatarUrl":null},"bodyText":"mine, newest","createdAt":"2026-10-02T12:59:00Z"},
             {"author":{"__typename":"Bot","login":"ci-bot","avatarUrl":null},"bodyText":"bot","createdAt":"2026-10-02T12:58:00Z"},
             {"author":{"__typename":"User","login":"omar","avatarUrl":null},"bodyText":"older","createdAt":"2026-10-02T11:00:00Z"}]},
           "reviews":{"nodes":[
             {"author":{"__typename":"User","login":"sarah","avatarUrl":null},"state":"APPROVED","bodyText":"LGTM","submittedAt":"2026-10-02T12:00:00Z"},
             {"author":{"__typename":"User","login":"lea","avatarUrl":null},"state":"PENDING","bodyText":"draft","submittedAt":null}]},
           "commits":{"nodes":[{"commit":{"oid":"abc","committedDate":"2026-10-02T10:00:00Z","statusCheckRollup":{"state":"FAILURE",
             "contexts":{"nodes":[
               {"__typename":"CheckRun","name":"lint","conclusion":"FAILURE","status":"COMPLETED","completedAt":"2026-10-02T10:05:00Z"},
               {"__typename":"CheckRun","name":"test","conclusion":"SUCCESS","status":"COMPLETED","completedAt":"2026-10-02T10:06:00Z"}]}}}}]}}
        ]}},
        "errors":[{"type":"FORBIDDEN","message":"Resource protected by organization SAML enforcement.","path":["search","nodes",0]}]}
        """

    static let agentContextResponse = """
        {"data":{"repository":{"pullRequest":{"number":142,"title":"Debounce","body":"Body","headRefName":"h","baseRefName":"main",
          "reviewThreads":{"nodes":[
            {"isResolved":false,"isOutdated":false,"path":"src/a.ts","line":9,"originalLine":9,
             "comments":{"nodes":[{"author":{"login":"sarah"},"body":"Why?","diffHunk":"@@ -1 +9 @@\\n+let x = 1"}]}},
            {"isResolved":true,"isOutdated":false,"path":"src/b.ts","line":1,"originalLine":1,
             "comments":{"nodes":[{"author":{"login":"omar"},"body":"resolved one","diffHunk":"@@ -1 +1 @@"}]}}]},
          "commits":{"nodes":[{"commit":{"oid":"abc","statusCheckRollup":{"contexts":{"nodes":[
            {"__typename":"CheckRun","databaseId":77,"name":"lint","conclusion":"FAILURE","status":"COMPLETED",
             "detailsUrl":"https://github.com/platform/web/actions/runs/1/job/77","summary":null,"checkSuite":{"app":{"slug":"github-actions"}}},
            {"__typename":"CheckRun","databaseId":78,"name":"test","conclusion":"SUCCESS","status":"COMPLETED","detailsUrl":null,
             "summary":null,"checkSuite":{"app":{"slug":"github-actions"}}},
            {"__typename":"StatusContext","context":"ci/legacy","contextState":"ERROR","description":"Build errored","targetUrl":null}
          ]}}}}]}}}}}
        """
}

private final class ShelfStubTokens: TokenProvider {
    func token() async throws(AuthError) -> String { "token-0" }
    func invalidate() async {}
}

private struct ShelfStubReply: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
}

private final class ShelfStubServer: Sendable {
    let session: URLSession

    init(_ handler: @escaping @Sendable (URLRequest) -> ShelfStubReply) {
        ShelfStubProtocol.state.withLock { $0 = (handler, []) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShelfStubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    var requests: [URLRequest] { ShelfStubProtocol.state.withLock { $0.requests } }
}

private final class ShelfStubProtocol: URLProtocol {
    static let state = Mutex<(handler: (@Sendable (URLRequest) -> ShelfStubReply)?, requests: [URLRequest])>((nil, []))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            var body = Data()
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                body.append(buffer, count: read)
            }
            stream.close()
            recorded.httpBody = body
        }
        let handler = Self.state.withLock { state in
            state.requests.append(recorded)
            return state.handler
        }
        let reply = handler?(recorded) ?? ShelfStubReply(status: 500)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
