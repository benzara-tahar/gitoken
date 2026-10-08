import Foundation

extension FixtureGitHubService: GitHubSearchService {
    public func searchIssues(query: String, page: Int) async throws(GitHubError) -> SearchPage {
        guard (1...10).contains(page) else { throw .http(status: 422, message: "Search page must be between 1 and 10.") }
        let parsed = try GitHubSearchQuery(query)
        var parser = try FixtureSearchParser(parsed.query)
        let expression = try parser.parse()
        if let sort = parsed.sort, !["created", "updated", "comments"].contains(sort) {
            throw .http(status: 422, message: "Fixture search does not support sort:\(sort). Live GitHub search does.")
        }
        var matches = searchSubjects().filter { expression.matches($0) }
        if let sort = parsed.sort {
            matches.sort { left, right in
                let comparison: ComparisonResult
                switch sort {
                case "created": comparison = left.createdAt.compare(right.createdAt)
                case "comments":
                    comparison = left.commentCount == right.commentCount ? .orderedSame
                        : left.commentCount < right.commentCount ? .orderedAscending : .orderedDescending
                default: comparison = left.item.updatedAt.compare(right.item.updatedAt)
                }
                if comparison == .orderedSame { return left.item.id.rawValue < right.item.id.rawValue }
                return comparison == (parsed.order == "asc" ? .orderedAscending : .orderedDescending)
            }
        }
        let start = (page - 1) * 100
        let items = start < matches.count ? Array(matches[start..<min(start + 100, matches.count)].map(\.item)) : []
        return SearchPage(items: items, totalCount: matches.count, incompleteResults: false,
                          nextPage: page < 10 && start + 100 < matches.count ? page + 1 : nil)
    }

    public func searchDetail(for item: SearchItem) async throws(GitHubError) -> SearchSubjectDetail {
        guard let subject = searchSubjects().first(where: {
            $0.item.id == item.id && $0.item.repo == item.repo && $0.item.number == item.number && $0.item.kind == item.kind
        }) else { throw .http(status: 404, message: "Search subject not found.") }
        return SearchSubjectDetail(id: subject.item.id, title: subject.item.title, state: subject.item.state,
                                   author: subject.item.author, htmlURL: subject.item.htmlURL, items: subject.items,
                                   checks: subject.checks, fetchedAt: now.now())
    }

    private func searchSubjects() -> [FixtureSearchSubject] {
        state.withLock { state in
            var subjects = state.threads.map { thread in
                let segment = thread.subject.kind == .pullRequest ? "pull" : "issues"
                let item = SearchItem(id: SearchItemID(thread.nodeID), repo: thread.repo, number: thread.subject.number,
                                      kind: thread.subject.kind, title: thread.subject.title, state: thread.state,
                                      author: FixtureSeed.person(thread.subject.author), updatedAt: thread.updatedAt,
                                      htmlURL: URL(string: "https://github.com/\(thread.repo.fullName)/\(segment)/\(thread.subject.number)")!)
                return FixtureSearchSubject(item: item, items: thread.items)
            }
            let anchor = state.threads.first?.items.first?.createdAt ?? now.now()
            // Scripted subjects are searchable before their first notification arrives.
            for seed in FixtureSeed.notifications.compactMap(\.create) {
                guard !subjects.contains(where: { $0.item.repo.name == seed.subject.repo && $0.item.number == seed.subject.number }) else {
                    continue
                }
                let repoCode = ["web": 1, "api": 2, "ui-kit": 3][seed.subject.repo] ?? 9
                let id = "\(seed.subject.kind == .pullRequest ? "PR" : "I")_fx\(repoCode * 100_000 + seed.subject.number)"
                let body = seed.steps.compactMap { step -> RichBody? in
                    if case .opened(let body) = step.event { return body }
                    return nil
                }.first ?? .empty
                subjects.append(Self.searchOnlySubject(id: id, repo: seed.subject.repo, number: seed.subject.number,
                                                       kind: seed.subject.kind, title: seed.subject.title,
                                                       author: seed.subject.author, body: body, at: anchor))
            }
            // This PR has no notification counterpart, even after scripted arrivals.
            subjects.append(Self.searchOnlySubject(
                id: "PR_fx_search_only_151", repo: "web", number: 151, kind: .pullRequest,
                title: "Improve keyboard navigation in search results", author: "schen",
                body: "Adds arrow-key navigation and accessible focus indicators to search results. Ready for feedback.",
                at: anchor.addingTimeInterval(60), subjectState: .draft))
            return subjects
        }
    }

    private static func searchOnlySubject(id: String, repo: String, number: Int, kind: SubjectKind, title: String,
                                          author: String, body: RichBody, at: Date, subjectState: SubjectState = .open)
        -> FixtureSearchSubject
    {
        let actor = FixtureSeed.person(author)
        let url = URL(string: "https://github.com/platform/\(repo)/\(kind == .pullRequest ? "pull" : "issues")/\(number)")!
        let item = SearchItem(id: SearchItemID(id), repo: RepoRef(owner: "platform", name: repo), number: number,
                              kind: kind, title: title, state: subjectState, author: actor, updatedAt: at, htmlURL: url)
        return FixtureSearchSubject(item: item, items: [
            TimelineItem(id: "\(TimelineItem.openedPrefix)\(id)", actor: actor, createdAt: at, payload: .opened(body: body), url: url)
        ])
    }
}

private struct FixtureSearchSubject {
    let item: SearchItem
    let items: [TimelineItem]
    var createdAt: Date { items.first?.createdAt ?? item.updatedAt }
    var commentCount: Int {
        items.reduce(0) { count, item in
            switch item.payload {
            case .comment: return count + 1
            case .review(_, let body, let comments): return count + comments.count + (body.markdown.isEmpty ? 0 : 1)
            default: return count
            }
        }
    }
    var checks: CheckSummary? {
        items.reversed().lazy.compactMap { item -> CheckSummary? in
            if case .checks(let summary) = item.payload { return summary }
            return nil
        }.first
    }
    var searchableText: String {
        ([item.title] + items.compactMap { item -> String? in
            switch item.payload {
            case .opened(let body), .comment(let body): return body.markdown
            case .review(_, let body, let comments): return ([body.markdown] + comments.map { $0.body.markdown }).joined(separator: " ")
            default: return nil
            }
        }).joined(separator: " ")
    }
}

private indirect enum FixtureSearchExpression {
    case and(Self, Self), or(Self, Self), not(Self)
    case text(String), repo(String), org(String), author(String), kind(SubjectKind), state(String), archived(Bool), draft(Bool)

    func matches(_ subject: FixtureSearchSubject) -> Bool {
        let item = subject.item
        switch self {
        case .and(let lhs, let rhs): return lhs.matches(subject) && rhs.matches(subject)
        case .or(let lhs, let rhs): return lhs.matches(subject) || rhs.matches(subject)
        case .not(let expression): return !expression.matches(subject)
        case .text(let text): return subject.searchableText.localizedCaseInsensitiveContains(text)
        case .repo(let name): return item.repo.fullName.lowercased() == name
        case .org(let name): return item.repo.owner.lowercased() == name
        case .author(let login): return item.author?.login.lowercased() == login
        case .kind(let kind): return item.kind == kind
        case .state(let state):
            switch state {
            case "open": return item.state == .open || item.state == .draft
            case "closed": return item.state == .closed || item.state == .merged
            case "merged": return item.state == .merged
            default: return item.state != .merged
            }
        case .archived(let value): return !value
        case .draft(let value): return (item.state == .draft) == value
        }
    }
}

private struct FixtureSearchParser {
    enum Token: Equatable { case term(String, literal: Bool), left, right, and, or, not }
    let tokens: [Token]
    var index = 0

    init(_ query: String) throws(GitHubError) {
        var tokens: [Token] = []
        var value = ""
        var quoted = false
        var escaped = false
        var literal = false
        var started = false
        func finish() {
            guard started else { return }
            if !literal, value == "AND" { tokens.append(.and) }
            else if !literal, value == "OR" { tokens.append(.or) }
            else if !literal, value == "NOT" { tokens.append(.not) }
            else { tokens.append(.term(value, literal: literal)) }
            value = ""; literal = false; started = false
        }
        for character in query {
            if escaped { value.append(character); escaped = false; continue }
            if quoted, character == "\\" { escaped = true; continue }
            if character == "\"" {
                if !started { literal = true }
                started = true; quoted.toggle(); continue
            }
            if !quoted, character.isWhitespace || character == "(" || character == ")" {
                finish()
                if character == "(" { tokens.append(.left) }
                if character == ")" { tokens.append(.right) }
            } else { value.append(character); started = true }
        }
        guard !quoted, !escaped else { throw Self.invalid("Unclosed quoted text.") }
        finish()
        self.tokens = tokens
    }

    mutating func parse() throws(GitHubError) -> FixtureSearchExpression {
        guard !tokens.isEmpty else { throw Self.invalid("Empty search expression.") }
        let expression = try parseOr()
        guard index == tokens.count else { throw Self.invalid("Unexpected search token or closing parenthesis.") }
        return expression
    }

    private mutating func parseOr() throws(GitHubError) -> FixtureSearchExpression {
        var expression = try parseAnd()
        while index < tokens.count, tokens[index] == .or {
            index += 1
            expression = .or(expression, try parseAnd())
        }
        return expression
    }

    private mutating func parseAnd() throws(GitHubError) -> FixtureSearchExpression {
        var expression = try parsePrimary()
        while index < tokens.count, tokens[index] != .right, tokens[index] != .or {
            if tokens[index] == .and { index += 1 }
            expression = .and(expression, try parsePrimary())
        }
        return expression
    }

    private mutating func parsePrimary() throws(GitHubError) -> FixtureSearchExpression {
        guard index < tokens.count else { throw Self.invalid("Missing search operand.") }
        let token = tokens[index]
        index += 1
        switch token {
        case .not: return .not(try parsePrimary())
        case .left:
            let expression = try parseOr()
            guard index < tokens.count, tokens[index] == .right else { throw Self.invalid("Unclosed search group.") }
            index += 1
            return expression
        case .term(let value, let literal):
            guard !value.isEmpty else { throw Self.invalid("Empty search term.") }
            if literal { return .text(value) }
            if value.hasPrefix("-"), value.count > 1 { return .not(try Self.predicate(String(value.dropFirst()))) }
            return try Self.predicate(value)
        default: throw Self.invalid("Missing search operand.")
        }
    }

    private static func predicate(_ value: String) throws(GitHubError) -> FixtureSearchExpression {
        guard let colon = value.firstIndex(of: ":") else { return .text(value) }
        let key = String(value[..<colon]).lowercased()
        let argument = String(value[value.index(after: colon)...]).lowercased()
        guard !argument.isEmpty else { throw invalid("Empty qualifier: \(key).") }
        switch key {
        case "repo": return .repo(argument)
        case "org", "user": return .org(argument)
        case "author": return .author(argument == "@me" ? FixtureSeed.viewerLogin : argument)
        case "is", "type":
            switch argument {
            case "pr": return .kind(.pullRequest)
            case "issue": return .kind(.issue)
            case "open", "closed", "merged", "unmerged": return .state(argument)
            case "draft": return .draft(true)
            default: throw invalid("Fixture search does not support \(value).")
            }
        case "state":
            guard ["open", "closed"].contains(argument) else { throw invalid("Unsupported state: \(argument).") }
            return .state(argument)
        case "archived", "draft":
            guard let boolean = Bool(argument) else { throw invalid("Expected true or false for \(key).") }
            return key == "archived" ? .archived(boolean) : .draft(boolean)
        default: throw invalid("Fixture search does not support \(value). Live GitHub search may support it.")
        }
    }

    private static func invalid(_ message: String) -> GitHubError { .http(status: 422, message: message) }
}
