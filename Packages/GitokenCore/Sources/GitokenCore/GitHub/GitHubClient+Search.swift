import Foundation

extension GitHubClient: GitHubSearchService {
    public func searchIssues(query: String, page: Int) async throws(GitHubError) -> SearchPage {
        guard (1...10).contains(page) else {
            throw .http(status: 422, message: "GitHub search pages must be between 1 and 10 (1,000 results maximum).")
        }
        let parsed = try GitHubSearchQuery(query)
        var components = URLComponents(url: Self.apiBase.appending(path: "search/issues"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: parsed.query),
            URLQueryItem(name: "advanced_search", value: "true"),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: String(page))
        ]
        if let sort = parsed.sort {
            components.queryItems?.append(URLQueryItem(name: "sort", value: sort))
            components.queryItems?.append(URLQueryItem(name: "order", value: parsed.order))
        }
        let (data, response) = try await send("GET", components.url!)
        let result = try GitHubJSON.decode(RESTSearchPage.self, from: data, decoder: GitHubJSON.restDecoder())
        var seen: Set<SearchItemID> = []
        var items: [SearchItem] = []
        for item in result.items {
            let mapped = try item.searchItem()
            if seen.insert(mapped.id).inserted { items.append(mapped) }
        }
        let hasNext = Self.nextPageURL(response) != nil || result.totalCount > page * 100
        return SearchPage(items: items, totalCount: result.totalCount, incompleteResults: result.incompleteResults,
                          nextPage: page < 10 && hasNext && !result.items.isEmpty ? page + 1 : nil)
    }

    public func searchDetail(for item: SearchItem) async throws(GitHubError) -> SearchSubjectDetail {
        let variables = SubjectVariables(owner: item.repo.owner, name: item.repo.name, number: item.number)
        switch item.kind {
        case .pullRequest:
            let payload: GQLPullRequestData = try await graphQL(GraphQLQueries.pullRequest, variables: variables)
            guard let pr = payload.repository?.pullRequest else {
                throw .http(status: 404, message: "pull request not found")
            }
            guard pr.id == item.id.rawValue else { throw .decoding("Search subject identity changed.") }
            return TimelineMapper.subject(pullRequest: pr).search(id: item.id, fetchedAt: now.now())
        case .issue:
            let payload: GQLIssueData = try await graphQL(GraphQLQueries.issue, variables: variables)
            guard let issue = payload.repository?.issue else { throw .http(status: 404, message: "issue not found") }
            guard issue.id == item.id.rawValue else { throw .decoding("Search subject identity changed.") }
            return TimelineMapper.subject(issue: issue).search(id: item.id, fetchedAt: now.now())
        default:
            throw .http(status: 404, message: "unsupported search subject")
        }
    }
}

/// Only standalone, unquoted, top-level sort qualifiers belong in REST parameters.
/// All other query text, including Boolean groups and quoted literals, stays server-owned.
struct GitHubSearchQuery {
    let query: String
    let sort: String?
    let order: String

    static let validSorts: Set<String> = [
        "created", "updated", "comments", "reactions", "reactions-+1", "reactions--1",
        "reactions-smile", "reactions-thinking_face", "reactions-heart", "reactions-tada", "interactions"
    ]

    init(_ source: String) throws(GitHubError) {
        var depth = 0
        var quoted = false
        var escaped = false
        var tokenStart: String.Index?
        var tokenDepth = 0
        var ranges: [Range<String.Index>] = []
        var chosenSort: String?
        var chosenOrder = "desc"

        func finish(at end: String.Index) throws(GitHubError) {
            guard let start = tokenStart else { return }
            defer { tokenStart = nil }
            let token = source[start..<end]
            guard tokenDepth == 0, token.hasPrefix("sort:") else { return }
            guard chosenSort == nil else {
                throw .http(status: 422, message: "Use only one top-level sort qualifier.")
            }
            var value = String(token.dropFirst(5))
            if value.hasSuffix("-asc") { value.removeLast(4); chosenOrder = "asc" }
            else if value.hasSuffix("-desc") { value.removeLast(5) }
            guard Self.validSorts.contains(value) else {
                throw .http(status: 422, message: "Unsupported GitHub search sort: \(token)")
            }
            chosenSort = value
            var removalEnd = end
            while removalEnd < source.endIndex, source[removalEnd].isWhitespace {
                removalEnd = source.index(after: removalEnd)
            }
            ranges.append(start..<removalEnd)
        }

        for index in source.indices {
            let character = source[index]
            if !quoted, character.isWhitespace || character == "(" || character == ")" {
                try finish(at: index)
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                continue
            }
            if tokenStart == nil { tokenStart = index; tokenDepth = depth }
            if escaped { escaped = false; continue }
            if quoted, character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle() }
        }
        try finish(at: source.endIndex)
        var remaining = source
        for range in ranges.reversed() { remaining.removeSubrange(range) }
        guard !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .http(status: 422, message: "Enter a GitHub issue or pull request search query.")
        }
        query = remaining
        sort = chosenSort
        order = chosenOrder
    }
}

private struct RESTSearchPage: Decodable {
    let totalCount: Int
    let incompleteResults: Bool
    let items: [RESTSearchItem]
}

private struct RESTSearchItem: Decodable {
    struct PullRequest: Decodable {
        let mergedAt: Date?
        let draft: Bool?
    }

    let nodeId: String
    let repositoryUrl: URL
    let number: Int
    let title: String
    let state: String
    let user: RESTUser?
    let updatedAt: Date
    let htmlUrl: URL
    let draft: Bool?
    let pullRequest: PullRequest?

    func searchItem() throws(GitHubError) -> SearchItem {
        let parts = repositoryUrl.pathComponents.filter { $0 != "/" }
        guard let reposIndex = parts.lastIndex(of: "repos"), parts.count == reposIndex + 3,
              !parts[reposIndex + 1].isEmpty, !parts[reposIndex + 2].isEmpty, !nodeId.isEmpty else {
            throw .decoding("Search result has an invalid repository URL or subject node ID.")
        }
        let subjectState: SubjectState
        if pullRequest?.mergedAt != nil { subjectState = .merged }
        else if state == "closed" { subjectState = .closed }
        else if pullRequest != nil, draft == true || pullRequest?.draft == true { subjectState = .draft }
        else { subjectState = .open }
        return SearchItem(id: SearchItemID(nodeId), repo: RepoRef(owner: parts[reposIndex + 1], name: parts[reposIndex + 2]),
                          number: number, kind: pullRequest == nil ? .issue : .pullRequest, title: title,
                          state: subjectState, author: user?.actor, updatedAt: updatedAt, htmlURL: htmlUrl)
    }
}
