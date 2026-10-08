import Foundation
import Testing
@testable import GitokenCore

extension GitHubClientTests {
    @Test func searchPreservesBooleanQueriesAndQuotedOrGroupedSortText() async throws {
        let stub = StubServer { _ in .init(status: 200, body: searchResponse([])) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        let query = #"(repo:platform/web OR repo:platform/api) AND is:pr archived:false "sort:created-asc" (sort:comments-desc OR "escaped \"sort:updated-asc\"")"#
        _ = try await client.searchIssues(query: query, page: 1)
        let request = try #require(stub.requests.first)
        let parameters = searchParameters(request)
        #expect(parameters["q"] == query)
        #expect(parameters["sort"] == nil)
        #expect(parameters["order"] == nil)
        #expect(parameters["advanced_search"] == "true")
        #expect(parameters["per_page"] == "100")
        #expect(parameters["page"] == "1")
        #expect(request.url?.path == "/search/issues")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-0")
        #expect(stub.requests.count == 1)
    }

    @Test func searchExtractsDocumentedTopLevelSortsWithoutRewritingGrammar() async throws {
        let stub = StubServer { _ in .init(status: 200, body: searchResponse([])) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        for sort in GitHubSearchQuery.validSorts.sorted() {
            let query = #"(is:pr OR is:issue) AND "sort:updated-desc""#
            _ = try await client.searchIssues(query: "sort:\(sort)-asc \(query)", page: 3)
            let parameters = searchParameters(try #require(stub.requests.last))
            #expect(parameters["q"] == query)
            #expect(parameters["sort"] == sort)
            #expect(parameters["order"] == "asc")
            #expect(parameters["page"] == "3")
        }
        _ = try await client.searchIssues(query: "sort:updated-desc is:pr", page: 1)
        #expect(searchParameters(try #require(stub.requests.last))["order"] == "desc")
        _ = try await client.searchIssues(query: "is:issue sort:created", page: 1)
        #expect(searchParameters(try #require(stub.requests.last))["sort"] == "created")
        #expect(searchParameters(try #require(stub.requests.last))["order"] == "desc")
    }

    @Test func searchDecodesDistinctSubjectIDsKindsStatesAndNullableAuthors() async throws {
        let open = searchJSONItem(id: "PR_open", number: 1, pr: [:], author: ["login": "octocat", "type": "User"])
        let issue = searchJSONItem(id: "I_open", number: 1)
        let draft = searchJSONItem(id: "PR_draft", number: 2, pr: [:], draft: true)
        let nestedDraft = searchJSONItem(id: "PR_nested_draft", number: 3, pr: ["draft": true])
        let closed = searchJSONItem(id: "I_closed", number: 4, state: "closed")
        let closedPR = searchJSONItem(id: "PR_closed", number: 5, state: "closed", pr: [:], draft: true)
        let merged = searchJSONItem(id: "PR_merged", number: 6, state: "closed", pr: ["merged_at": "2026-10-02T09:00:00Z"])
        let response = searchResponse([open, issue, draft, nestedDraft, closed, closedPR, merged, open], total: 1201, incomplete: true)
        let stub = StubServer { _ in
            .init(status: 200, body: response)
        }
        let page = try await GitHubClient(tokens: StubTokens(), session: stub.session).searchIssues(query: "org:platform", page: 1)
        #expect(page.items.map(\.id.rawValue) == ["PR_open", "I_open", "PR_draft", "PR_nested_draft", "I_closed", "PR_closed", "PR_merged"])
        #expect(page.items.map(\.state) == [.open, .open, .draft, .draft, .closed, .closed, .merged])
        #expect(page.items.map(\.kind) == [.pullRequest, .issue, .pullRequest, .pullRequest, .issue, .pullRequest, .pullRequest])
        #expect(page.items[0].id != page.items[1].id)
        #expect(page.items[0].author?.login == "octocat")
        #expect(page.items[1].author == nil)
        #expect(page.items.allSatisfy { $0.repo == RepoRef(owner: "platform", name: "web") })
        #expect(page.items[0].updatedAt == GitHubJSON.parseDate("2026-10-03T09:20:00Z"))
        #expect(page.totalCount == 1201)
        #expect(page.incompleteResults)
        #expect(page.nextPage == 2)
        #expect(stub.requests.count == 1, "Search must never eagerly fetch subsequent pages.")
    }

    @Test func searchPaginationStopsAtThousandAndRetainsIncompleteSignal() async throws {
        let stub = StubServer { _ in
            .init(status: 200, headers: ["Link": "<https://api.github.com/search/issues?page=11>; rel=\"next\""],
                  body: searchResponse([searchJSONItem(id: "I_cap", number: 1000)], total: 4500, incomplete: true))
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        let ninth = try await client.searchIssues(query: "is:issue", page: 9)
        let tenth = try await client.searchIssues(query: "is:issue", page: 10)
        #expect(ninth.nextPage == 10)
        #expect(tenth.nextPage == nil)
        #expect(tenth.totalCount == 4500)
        #expect(tenth.incompleteResults)
        #expect(stub.requests.count == 2)
    }

    @Test func searchLastAndEmptyPagesDoNotInventMoreResults() async throws {
        let stub = StubServer { request in
            if searchParameters(request)["q"] == "empty" { return .init(status: 200, body: searchResponse([])) }
            return .init(status: 200, body: searchResponse([searchJSONItem(id: "I_last", number: 120)], total: 120))
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        #expect(try await client.searchIssues(query: "is:issue", page: 2).nextPage == nil)
        #expect(try await client.searchIssues(query: "empty", page: 1).nextPage == nil)
    }

    @Test func searchRejectsEmptyInvalidAndAmbiguousSortsAndOutOfRangePages() async throws {
        let stub = StubServer { _ in .init(status: 200, body: searchResponse([])) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        for query in ["", "  \n ", "sort:updated", "is:pr sort:", "is:pr sort:nonsense", "is:pr sort:updated-random",
                      "is:pr sort:updated sort:created", #"is:pr sort:"""#, #"is:pr sort:"updated-desc""#] {
            do {
                _ = try await client.searchIssues(query: query, page: 1)
                Issue.record("Expected 422 for \(query)")
            } catch {
                guard case .http(status: 422, message: _) = error else { Issue.record("Unexpected error: \(error)"); continue }
            }
        }
        for page in [0, 11] {
            await #expect(throws: GitHubError.http(status: 422, message: "GitHub search pages must be between 1 and 10 (1,000 results maximum).")) {
                try await client.searchIssues(query: "is:pr", page: page)
            }
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func searchSurfacesServerValidationAndRateLimits() async throws {
        let now = OffsetNow.fixed(Date(timeIntervalSince1970: 1_790_000_000))
        let stub = StubServer { request in
            switch searchParameters(request)["q"] {
            case "invalid": return .init(status: 422, body: Data(#"{"message":"Validation Failed"}"#.utf8))
            case "primary": return .init(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1790000090"])
            default: return .init(status: 429, headers: ["Retry-After": "45"])
            }
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session, now: now)
        await #expect(throws: GitHubError.http(status: 422, message: "Validation Failed")) {
            try await client.searchIssues(query: "invalid", page: 1)
        }
        await #expect(throws: GitHubError.rateLimited(resetAt: now.now().addingTimeInterval(90))) {
            try await client.searchIssues(query: "primary", page: 1)
        }
        await #expect(throws: GitHubError.rateLimited(resetAt: now.now().addingTimeInterval(45))) {
            try await client.searchIssues(query: "secondary", page: 1)
        }
    }

    @Test func searchParsesRepositoryURLPathAndRejectsMalformedURLs() async throws {
        let stub = StubServer { request in
            let repo = searchParameters(request)["q"] == "valid" ? "https://example.test/api/v3/repos/owner-name/repo.name/" : "https://api.github.com/repositories/123"
            return .init(status: 200, body: searchResponse([searchJSONItem(id: "I_repo", number: 1, repositoryURL: repo)]))
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        let page = try await client.searchIssues(query: "valid", page: 1)
        #expect(page.items.first?.repo == RepoRef(owner: "owner-name", name: "repo.name"))
        do {
            _ = try await client.searchIssues(query: "invalid", page: 1)
            Issue.record("Expected malformed repository URL to fail visibly.")
        } catch {
            guard case .decoding = error else { Issue.record("Unexpected error: \(error)"); return }
        }
    }

    @Test func searchDetailUsesSubjectGraphQLWithoutNotificationWritesAndPreservesTimelineMapping() async throws {
        let prData = searchFixture("graphql-pull-request")
        let issueData = searchFixture("graphql-issue")
        let stub = StubServer { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return .init(status: 200, body: body.contains("PullRequestDetail") ? prData : issueData)
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        let pr = searchModel(id: "PR_kwDOfixture142", kind: .pullRequest, repo: "web", number: 142)
        let issue = searchModel(id: "I_kwDOfixture311", kind: .issue, repo: "ui-kit", number: 311)
        let prDetail = try await client.searchDetail(for: pr)
        let issueDetail = try await client.searchDetail(for: issue)
        #expect(prDetail.id == pr.id)
        #expect(prDetail.items.count == 10)
        #expect(prDetail.checks?.status == .failure)
        #expect(prDetail.state == .open)
        #expect(issueDetail.id == issue.id)
        #expect(issueDetail.state == .closed)
        #expect(issueDetail.checks == nil)
        #expect(prDetail.id != issueDetail.id)
        #expect(stub.requests.count == 2)
        for (request, item) in zip(stub.requests, [pr, issue]) {
            #expect(request.url?.path == "/graphql")
            #expect(request.httpMethod == "POST")
            let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
            let variables = body?["variables"] as? [String: Any]
            #expect(variables?["owner"] as? String == item.repo.owner)
            #expect(variables?["name"] as? String == item.repo.name)
            #expect(variables?["number"] as? Int == item.number)
            let mutates = (body?["query"] as? String ?? "").contains("mutation")
            #expect(mutates == false)
        }
    }

    @Test func searchDetailDoesNotAssignAnotherSubjectsIdentity() async throws {
        let stub = StubServer { _ in .init(status: 200, body: searchFixture("graphql-pull-request")) }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        await #expect(throws: GitHubError.decoding("Search subject identity changed.")) {
            try await client.searchDetail(for: searchModel(id: "PR_wrong", kind: .pullRequest, repo: "web", number: 142))
        }
    }

    @Test func searchDetailSurfacesGraphQLErrorsAndMissingSubjects() async throws {
        let stub = StubServer { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("PullRequestDetail") {
                return .init(status: 200, body: Data(#"{"data":null,"errors":[{"message":"Access denied"}]}"#.utf8))
            }
            return .init(status: 200, body: Data(#"{"data":{"repository":{"issue":null}}}"#.utf8))
        }
        let client = GitHubClient(tokens: StubTokens(), session: stub.session)
        await #expect(throws: GitHubError.graphQL(["Access denied"])) {
            try await client.searchDetail(for: searchModel(id: "PR_missing", kind: .pullRequest, repo: "web", number: 1))
        }
        await #expect(throws: GitHubError.http(status: 404, message: "issue not found")) {
            try await client.searchDetail(for: searchModel(id: "I_missing", kind: .issue, repo: "web", number: 1))
        }
        #expect(stub.requests.allSatisfy { $0.url?.path == "/graphql" && $0.httpMethod == "POST" })
    }
}

@Suite struct FixtureSearchTests {
    @Test func allSubjectsIncludeDoneAndSearchOnlyWithoutChangingNotificationBaseline() async throws {
        let service = FixtureGitHubService(now: OffsetNow.fixed(Date(timeIntervalSince1970: 1_790_000_000)))
        guard case .updated(let notifications, let stamp, _) = try await service.pollNotifications(lastModified: nil) else {
            Issue.record("Expected notifications"); return
        }
        let all = try await service.searchIssues(query: "org:platform archived:false", page: 1)
        #expect(notifications.count == 7)
        #expect(all.items.count == 12)
        #expect(Set(all.items.map(\.id)).count == all.items.count)
        let merged = try #require(all.items.first { $0.repo.name == "web" && $0.number == 120 })
        #expect(merged.state == .merged)
        let closed = try #require(all.items.first { $0.repo.name == "api" && $0.number == 80 })
        #expect(closed.state == .closed)
        let searchOnly = try #require(all.items.first { $0.number == 151 })
        #expect(!notifications.contains { $0.number == 151 })
        #expect(searchOnly.state == .draft)
        #expect(try await service.searchDetail(for: searchOnly).items.first?.id == "\(TimelineItem.openedPrefix)\(searchOnly.id.rawValue)")
        #expect(try await service.pollNotifications(lastModified: stamp) == .notModified(pollInterval: 60))
        #expect(service.reactionCalls.isEmpty)
        try await service.markDone(try #require(notifications.first).id)
        #expect(try await service.searchIssues(query: "org:platform", page: 1).items.count == all.items.count)
    }

    @Test func fixtureBooleanGroupsQualifiersAndTextMatchExpectedSubjects() async throws {
        let service = FixtureGitHubService()
        let page = try await service.searchIssues(query: "(repo:platform/web OR repo:platform/api) AND is:pr state:open archived:false sort:updated-desc", page: 1)
        #expect(Set(page.items.map { "\($0.repo.name)#\($0.number)" }) == ["web#142", "web#147", "web#151", "api#87", "api#91"])
        #expect(page.items.map(\.updatedAt) == page.items.map(\.updatedAt).sorted(by: >))
        #expect(try await service.searchIssues(query: "author:schen is:pr draft:true", page: 1).items.map(\.number) == [151])
        #expect(try await service.searchIssues(query: #""keyboard navigation""#, page: 1).items.map(\.number) == [151])
        #expect(try await service.searchIssues(query: "is:issue state:closed", page: 1).items.map(\.number) == [80])
        #expect(try await service.searchIssues(query: "is:pr is:merged", page: 1).items.map(\.number) == [120])
        #expect(try await service.searchIssues(query: "org:platform archived:true", page: 1).items.isEmpty)
        #expect(try await service.searchIssues(query: "repo:platform/web NOT is:pr", page: 1).items.map(\.number) == [128])
        #expect(try await service.searchIssues(query: "is:issue sort:created-asc", page: 1).items.first?.number == 80)
    }

    @Test func fixtureSearchReportsUnsupportedPredicatesAndMalformedExpressions() async throws {
        let service = FixtureGitHubService()
        for query in ["is:pr OR label:bug", "(is:pr", "is:pr OR", "is:pr AND OR is:issue", "archived:maybe", "sort:reactions is:pr", #""unterminated"#] {
            do {
                _ = try await service.searchIssues(query: query, page: 1)
                Issue.record("Expected explicit fixture validation failure for \(query)")
            } catch {
                guard case .http(status: 422, message: _) = error else { Issue.record("Unexpected error: \(error)"); continue }
            }
        }
    }

    @Test func scriptedSearchOnlySubjectKeepsIdentityWhenNotificationArrives() async throws {
        let service = FixtureGitHubService()
        let before = try #require(try await service.searchIssues(query: "repo:platform/web prefetch", page: 1).items.first)
        await service.enqueueNotification()
        let after = try #require(try await service.searchIssues(query: "repo:platform/web prefetch", page: 1).items.first)
        #expect(before.id == after.id)
        #expect(try await service.searchDetail(for: after).items.count == 2)
    }
}

private func searchParameters(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private func searchResponse(_ items: [[String: Any]], total: Int? = nil, incomplete: Bool = false) -> Data {
    try! JSONSerialization.data(withJSONObject: ["total_count": total ?? items.count, "incomplete_results": incomplete, "items": items])
}

private func searchJSONItem(id: String, number: Int, state: String = "open", pr: [String: Any]? = nil,
                            draft: Bool? = nil, author: [String: Any]? = nil,
                            repositoryURL: String = "https://api.github.com/repos/platform/web") -> [String: Any] {
    var item: [String: Any] = ["node_id": id, "repository_url": repositoryURL, "number": number, "title": "Search subject \(number)",
                               "state": state, "user": author.map { $0 as Any } ?? NSNull(), "updated_at": "2026-10-03T09:20:00Z",
                               "html_url": "https://github.com/platform/web/\(pr == nil ? "issues" : "pull")/\(number)"]
    if let pr { item["pull_request"] = pr }
    if let draft { item["draft"] = draft }
    return item
}

private func searchFixture(_ name: String) -> Data {
    try! Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
}

private func searchModel(id: String, kind: SubjectKind, repo: String, number: Int) -> SearchItem {
    SearchItem(id: SearchItemID(id), repo: RepoRef(owner: "platform", name: repo), number: number, kind: kind,
               title: "Search subject", state: .open, author: nil, updatedAt: Date(timeIntervalSince1970: 0),
               htmlURL: URL(string: "https://github.com/platform/\(repo)/\(kind == .pullRequest ? "pull" : "issues")/\(number)")!)
}
