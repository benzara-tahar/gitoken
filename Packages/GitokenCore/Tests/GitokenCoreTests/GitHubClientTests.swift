import Foundation
import Synchronization
import Testing
@testable import GitokenCore

/// Serialized: every test routes through the process-wide `StubURLProtocol` handler.
@Suite(.serialized) struct GitHubClientTests {
    // MARK: Notifications

    @Test func pollFollowsLinkPagesAndOnlyFirstPageCarriesIfModifiedSince() async throws {
        let page2 = "https://api.github.com/notifications?all=true&per_page=50&page=2"
        let stub = StubServer { request in
            if request.url?.query?.contains("page=2") == true {
                return .init(status: 200, body: fixture("rest-notifications-page2"))
            }
            return .init(
                status: 200,
                headers: [
                    "Link": "<\(page2)>; rel=\"next\", <\(page2)>; rel=\"last\"",
                    "Last-Modified": "Wed, 30 Sep 2026 14:12:05 GMT",
                    "X-Poll-Interval": "120",
                ],
                body: fixture("rest-notifications-page1")
            )
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)

        let poll = try await client.pollNotifications(lastModified: "Tue, 29 Sep 2026 08:00:00 GMT")

        guard case .updated(let threads, let lastModified, let interval) = poll else {
            Issue.record("expected .updated, got \(poll)")
            return
        }
        #expect(threads.map(\.id.rawValue) == ["100142", "300311", "200099", "400012", "200087"])
        #expect(lastModified == "Wed, 30 Sep 2026 14:12:05 GMT")
        #expect(interval == 120)

        let requests = stub.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-Modified-Since") == "Tue, 29 Sep 2026 08:00:00 GMT")
        #expect(requests[1].value(forHTTPHeaderField: "If-Modified-Since") == nil)
        #expect(requests[1].url?.absoluteString == page2)
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "all", value: "true")))
        #expect(query.contains(URLQueryItem(name: "per_page", value: "50")))
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-0")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        }
    }

    @Test func notificationRowsDecodeIntoThreads() async throws {
        let stub = StubServer { _ in .init(status: 200, body: fixture("rest-notifications-page1")) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        guard case .updated(let page1, _, _) = try await client.pollNotifications(lastModified: nil) else {
            Issue.record("expected .updated")
            return
        }
        let page2Stub = StubServer { _ in .init(status: 200, body: fixture("rest-notifications-page2")) }
        guard case .updated(let page2, _, let interval) = try await GitHubClient(tokens: StubTokens(), session: page2Stub.session)
            .pollNotifications(lastModified: nil)
        else {
            Issue.record("expected .updated")
            return
        }
        #expect(interval == 60, "missing X-Poll-Interval falls back to the 60s floor")

        let pr = try #require(page1.first { $0.id == ThreadID("100142") })
        #expect(pr.kind == .pullRequest)
        #expect(pr.number == 142)
        #expect(pr.repo == RepoRef(owner: "platform", name: "web"))
        #expect(pr.reason == .reviewRequested)
        #expect(pr.unread)
        #expect(pr.updatedAt == iso("2026-09-30T14:12:05Z"))
        #expect(pr.lastReadAt == iso("2026-09-30T09:20:00Z"))
        #expect(pr.htmlURL.absoluteString == "https://github.com/platform/web/pull/142")
        #expect(pr.repoOwnerAvatarURL != nil)

        let issue = try #require(page1.first { $0.id == ThreadID("300311") })
        #expect(issue.kind == .issue)
        #expect(issue.number == 311)
        #expect(issue.reason == .mention)
        #expect(issue.lastReadAt == nil)

        let release = try #require(page1.first { $0.id == ThreadID("200099") })
        #expect(release.kind == .release)
        #expect(release.number == nil, "release ids are not issue numbers")
        #expect(release.reason == .other)
        #expect(!release.unread)

        let discussion = try #require(page2.first { $0.id == ThreadID("400012") })
        #expect(discussion.kind == .discussion)
        #expect(discussion.number == 12)
        #expect(discussion.reason == .teamMention)

        let checkSuite = try #require(page2.first { $0.id == ThreadID("200087") })
        #expect(checkSuite.kind == .checkSuite)
        #expect(checkSuite.number == nil)
        #expect(checkSuite.reason == .ciActivity)
    }

    @Test func notModifiedReturnsIntervalWithSixtySecondFloor() async throws {
        let stub = StubServer { _ in .init(status: 304, headers: ["X-Poll-Interval": "30"]) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        let poll = try await client.pollNotifications(lastModified: "Wed, 30 Sep 2026 14:12:05 GMT")
        #expect(poll == .notModified(pollInterval: 60))
        #expect(stub.requests.count == 1)
    }

    // MARK: Auth and rate limits

    @Test func unauthorizedInvalidatesTokenAndRetriesOnce() async throws {
        let stub = StubServer { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer token-0"
                ? .init(status: 401, body: Data(#"{"message":"Bad credentials"}"#.utf8))
                : .init(status: 200, body: Data(#"{"login":"akim","name":"Alex Kim","avatar_url":null,"type":"User"}"#.utf8))
        }
        let tokens = StubTokens()
        let client = GitHubClient(tokens: tokens, session: stub.session)

        let viewer = try await client.viewer()

        #expect(viewer == Actor(login: "akim", name: "Alex Kim"))
        #expect(tokens.invalidations == 1)
        #expect(stub.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-0", "Bearer token-1"])
    }

    @Test func secondUnauthorizedBecomesTokenRejectedWithScopes() async throws {
        let stub = StubServer { _ in .init(status: 401, headers: ["X-OAuth-Scopes": "gist, read:org"]) }
        let tokens = StubTokens()
        let client = GitHubClient(tokens: tokens, session: stub.session)

        await #expect(throws: GitHubError.auth(.tokenRejected(status: 401, scopes: "gist, read:org"))) {
            try await client.pollNotifications(lastModified: nil)
        }
        #expect(stub.requests.count == 2)
        #expect(tokens.invalidations == 2)
    }

    @Test func forbiddenNotificationsMeansTokenLacksAccess() async throws {
        let stub = StubServer { _ in
            .init(status: 403, headers: ["X-OAuth-Scopes": "", "X-RateLimit-Remaining": "4990"],
                  body: Data(#"{"message":"Resource not accessible by personal access token"}"#.utf8))
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        await #expect(throws: GitHubError.auth(.tokenRejected(status: 403, scopes: ""))) {
            try await client.pollNotifications(lastModified: nil)
        }
    }

    @Test func exhaustedPrimaryRateLimitMapsToResetTime() async throws {
        let stub = StubServer { _ in
            .init(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1790000000"])
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        await #expect(throws: GitHubError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_790_000_000))) {
            try await client.pollNotifications(lastModified: nil)
        }
    }

    @Test func secondaryRateLimitUsesRetryAfterFromNow() async throws {
        let now = OffsetNow.fixed(iso("2026-10-02T10:00:00Z"))
        let stub = StubServer { _ in .init(status: 429, headers: ["Retry-After": "90"]) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session, now: now)
        await #expect(throws: GitHubError.rateLimited(resetAt: iso("2026-10-02T10:01:30Z"))) {
            try await client.markRead(ThreadID("100142"))
        }
    }

    @Test func authFailureFromGhSurfacesWithoutNetwork() async throws {
        let stub = StubServer { _ in .init(status: 200) }
        let client = GitHubClient(tokens: StubTokens(failure: .notLoggedIn(detail: "not logged in")), session: stub.session)
        await #expect(throws: GitHubError.auth(.notLoggedIn(detail: "not logged in"))) {
            try await client.viewer()
        }
        #expect(stub.requests.isEmpty)
    }

    // MARK: GraphQL hydration

    @Test func pullRequestTimelineMapsReviewsCommitsAndChecks() async throws {
        let stub = StubServer { _ in .init(status: 200, body: fixture("graphql-pull-request")) }
        let now = OffsetNow.fixed(iso("2026-10-02T10:00:00Z"))
        let client = GitHubClient(tokens: StubTokens(), session: stub.session, now: now)

        let detail = try await client.threadDetail(for: thread(kind: .pullRequest, number: 142))

        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/graphql")
        #expect(request.httpMethod == "POST")
        let sent = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        let variables = sent?["variables"] as? [String: Any]
        #expect(variables?["owner"] as? String == "platform")
        #expect(variables?["name"] as? String == "web")
        #expect(variables?["number"] as? Int == 142)

        #expect(detail.title == "Debounce search input and memoize result rows")
        #expect(detail.state == .open)
        #expect(detail.author?.login == "akim")
        #expect(detail.htmlURL.absoluteString == "https://github.com/platform/web/pull/142")
        #expect(detail.fetchedAt == now.now())

        let items = detail.items
        #expect(items.count == 10)
        guard items.count == 10 else { return }

        guard case .opened(let openedBody) = items[0].payload else {
            Issue.record("first item should be the opening body, got \(items[0].payload)")
            return
        }
        #expect(openedBody.markdown.hasPrefix("Typing in global search"))
        #expect(items[0].createdAt == iso("2026-09-29T12:20:00Z"))

        #expect(items[1].payload == .comment(body: RichBody(
            markdown: "Did you check the `?q=` deep-link flow?",
            html: "<p dir=\"auto\">Did you check the <code class=\"notranslate\">?q=</code> deep-link flow?</p>",
            plain: "Did you check the ?q= deep-link flow?")))
        guard case .comment(let rendered) = items[1].payload else { return }
        #expect(rendered.document.blocks == [.paragraph([
            .text("Did you check the ", []), .text("?q=", .code), .text(" deep-link flow?", []),
        ])])
        #expect(items[2].payload == .commits(count: 2, headlines: ["Handle initial query from URL", "Memoize row renderer"]))
        #expect(items[2].actor.login == "akim")
        #expect(items[2].createdAt == iso("2026-09-30T09:21:00Z"))
        #expect(items[3].payload == .commits(count: 1, headlines: ["Fix lint in ResultList"]))
        #expect(items[3].actor.login == "leom")
        #expect(items[4].payload == .event(.reviewRequested, detail: "schen"))
        #expect(items[5].actor.isBot)

        guard case .review(let state, let body, let comments) = items[6].payload else {
            Issue.record("expected review, got \(items[6].payload)")
            return
        }
        #expect(state == .changesRequested)
        #expect(body == "A couple of things before this lands.", "bodyHTML is optional; markdown-only bodies still decode")
        #expect(comments.map(\.databaseID) == [9001, 9002])
        #expect(comments[0].path == "src/components/SearchBox.tsx")
        #expect(comments[0].diffHunk.hasPrefix("@@ -28,13 +28,18 @@"))
        #expect(comments[0].diffHunk.hasSuffix("+  }, [debounced, onSearch]);"))
        #expect(comments[0].line == 37)
        #expect(comments[1].line == 23, "outdated comments fall back to originalLine")

        guard case .review(.commented, _, let replies) = items[7].payload else {
            Issue.record("expected reply review, got \(items[7].payload)")
            return
        }
        #expect(replies.first?.replyToID == "PRRC_fixture1")
        #expect(items[8].payload == .event(.headRefForcePushed, detail: nil))

        let expectedChecks = CheckSummary(
            status: .failure, commitSHA: "7be0d44000000000000000000000000000000002",
            failedChecks: ["lint", "unit-tests", "ci/legacy"], passedCount: 2, pendingCount: 1
        )
        #expect(detail.checks == expectedChecks)
        #expect(items[9].payload == .checks(expectedChecks))
        #expect(items[9].createdAt == iso("2026-09-30T14:05:00Z"))
        #expect(items[9].actor == Actor(login: "github-actions", name: "GitHub Actions", isBot: true))
    }

    @Test func issueTimelineSkipsOpeningWhenTruncatedAndMapsEvents() async throws {
        let stub = StubServer { _ in .init(status: 200, body: fixture("graphql-issue")) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)

        let detail = try await client.threadDetail(for: thread(kind: .issue, number: 311, repo: "ui-kit"))

        let sent = String(decoding: try #require(stub.requests.first?.httpBody), as: UTF8.self)
        #expect(sent.contains("issue(number: $number)"))
        #expect(detail.state == .closed)
        #expect(detail.checks == nil)
        #expect(detail.items.map(\.id) == ["IC_kwDOfixture10", "AE_fixture1", "IC_kwDOfixture11", "IC_kwDOfixture12", "CE_fixture1"])
        #expect(detail.items[1].payload == .event(.assigned, detail: "akim"))
        #expect(detail.items[2].actor.login == "ghost")
        #expect(detail.items[4].payload == .event(.closed, detail: nil))
    }

    @Test func graphQLErrorsSurface() async throws {
        let stub = StubServer { _ in
            .init(status: 200, body: Data(#"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository with the name 'platform/web'."}]}"#.utf8))
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        await #expect(throws: GitHubError.graphQL(["Could not resolve to a Repository with the name 'platform/web'."])) {
            try await client.threadDetail(for: thread(kind: .pullRequest, number: 142))
        }
    }

    @Test func unsupportedSubjectsAreNotHydrated() async throws {
        let stub = StubServer { _ in .init(status: 200) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        await #expect(throws: GitHubError.http(status: 404, message: "unsupported subject")) {
            try await client.threadDetail(for: thread(kind: .release, number: nil))
        }
        #expect(stub.requests.isEmpty)
    }

    // MARK: Writes

    @Test func markReadAndDoneUseThreadEndpoints() async throws {
        let stub = StubServer { request in .init(status: request.httpMethod == "PATCH" ? 205 : 204) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        try await client.markRead(ThreadID("100142"))
        try await client.markDone(ThreadID("100142"))
        #expect(stub.requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "PATCH /notifications/threads/100142", "DELETE /notifications/threads/100142",
        ])
    }

    @Test func replyResolvesParentNodeID() async throws {
        let stub = StubServer { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/repos/platform/web/pulls/142/comments/9003/replies"):
                return .init(status: 201, body: fixture("rest-review-comment-reply"))
            case ("GET", "/repos/platform/web/pulls/comments/9001"):
                return .init(status: 200, body: Data(#"{"id":9001,"node_id":"PRRC_fixture1"}"#.utf8))
            default:
                return .init(status: 404, body: Data(#"{"message":"Not Found"}"#.utf8))
            }
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)

        let reply = try await client.replyToReviewComment(
            repo: RepoRef(owner: "platform", name: "web"), number: 142, commentDatabaseID: 9003, body: "Moved the callback into a ref — thanks both."
        )

        #expect(reply.id == "PRRC_fixture10")
        #expect(reply.databaseID == 9010)
        #expect(reply.replyToID == "PRRC_fixture1", "replies thread under the root comment's node id")
        #expect(reply.path == "src/components/SearchBox.tsx")
        #expect(reply.line == 37)
        #expect(reply.body.html == "<p dir=\"auto\">Moved the callback into a ref — thanks both.</p>")
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Accept") == "application/vnd.github.full+json",
                "the full media type makes GitHub return body_html/body_text")
        let sent = try JSONSerialization.jsonObject(with: try #require(stub.requests.first?.httpBody)) as? [String: String]
        #expect(sent == ["body": "Moved the callback into a ref — thanks both."])
    }

    @Test func otherHTTPFailuresCarryGitHubMessage() async throws {
        let stub = StubServer { _ in .init(status: 422, body: Data(#"{"message":"Validation Failed"}"#.utf8)) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        await #expect(throws: GitHubError.http(status: 422, message: "Validation Failed")) {
            try await client.postComment(repo: RepoRef(owner: "platform", name: "web"), number: 142, body: "")
        }
    }
}

// MARK: - Helpers

private func fixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

private func iso(_ string: String) -> Date {
    try! Date(string, strategy: .iso8601)
}

private func thread(kind: SubjectKind, number: Int?, repo: String = "web") -> NotificationThread {
    NotificationThread(
        id: ThreadID("t-\(number ?? 0)"), repo: RepoRef(owner: "platform", name: repo), kind: kind, number: number,
        title: "Fixture", reason: .mention, unread: true, updatedAt: iso("2026-09-30T14:00:00Z"), lastReadAt: nil,
        subjectAPIURL: nil, latestCommentAPIURL: nil, repoOwnerAvatarURL: nil
    )
}

/// Hands out `token-<invalidations>` so tests can see which token a request used.
private final class StubTokens: TokenProvider {
    private let state = Mutex(0)
    private let failure: AuthError?

    init(failure: AuthError? = nil) { self.failure = failure }

    var invalidations: Int { state.withLock { $0 } }

    func token() async throws(AuthError) -> String {
        if let failure { throw failure }
        return "token-\(state.withLock { $0 })"
    }

    func invalidate() async { state.withLock { $0 += 1 } }
}

private struct StubReply: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
}

/// Installs a handler on `StubURLProtocol` for the lifetime of a test and records every request.
private final class StubServer: Sendable {
    let session: URLSession

    init(_ handler: @escaping @Sendable (URLRequest) -> StubReply) {
        StubURLProtocol.state.withLock { $0 = (handler, []) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    var requests: [URLRequest] { StubURLProtocol.state.withLock { $0.requests } }
}

private final class StubURLProtocol: URLProtocol {
    static let state = Mutex<(handler: (@Sendable (URLRequest) -> StubReply)?, requests: [URLRequest])>((nil, []))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Data(reading: stream)
        }
        let handler = Self.state.withLock { state in
            state.requests.append(recorded)
            return state.handler
        }
        let reply = handler?(recorded) ?? StubReply(status: 500)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            append(buffer, count: read)
        }
    }
}
