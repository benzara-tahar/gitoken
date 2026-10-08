import Foundation

/// URLSession REST + GraphQL implementation of `GitHubService` for github.com.
public final class GitHubClient: GitHubService {
    static let apiBase = URL(string: "https://api.github.com")!
    static let graphQLURL = URL(string: "https://api.github.com/graphql")!
    static let minimumPollInterval: TimeInterval = 60

    let tokens: any TokenProvider
    let session: URLSession
    let now: any NowProvider

    public init(tokens: any TokenProvider, session: URLSession = .shared, now: any NowProvider = SystemNow()) {
        self.tokens = tokens
        self.session = session
        self.now = now
    }

    public func viewer() async throws(GitHubError) -> Actor {
        let (data, _) = try await send("GET", Self.apiBase.appending(path: "user"))
        return try GitHubJSON.decode(RESTUser.self, from: data, decoder: GitHubJSON.restDecoder()).actor
    }

    public func pollNotifications(lastModified: String?) async throws(GitHubError) -> NotificationPoll {
        var next: URL? = Self.apiBase.appending(path: "notifications").appending(queryItems: [
            URLQueryItem(name: "all", value: "true"), URLQueryItem(name: "per_page", value: "50"),
        ])
        var visited = Set<URL>()
        var threads: [NotificationThread] = []
        var threadIDs = Set<ThreadID>()
        var responseLastModified: String?
        var interval = Self.minimumPollInterval
        let decoder = GitHubJSON.restDecoder()

        while let url = next, visited.insert(url).inserted {
            let isFirstPage = visited.count == 1
            var headers: [String: String] = [:]
            if isFirstPage, let lastModified { headers["If-Modified-Since"] = lastModified }
            let (data, response) = try await send("GET", url, headers: headers, notificationsScope: true)
            if isFirstPage {
                interval = Self.pollInterval(response)
                if response.statusCode == 304 { return .notModified(pollInterval: interval) }
                responseLastModified = response.value(forHTTPHeaderField: "Last-Modified")
            }
            let page = try GitHubJSON.decode([RESTNotification].self, from: data, decoder: decoder)
            for notification in page where threadIDs.insert(ThreadID(notification.id)).inserted {
                threads.append(notification.thread)
            }
            next = Self.nextPageURL(response)
        }
        return .updated(threads: threads, lastModified: responseLastModified, pollInterval: interval)
    }

    public func threadDetail(for thread: NotificationThread) async throws(GitHubError) -> ThreadDetail {
        guard let number = thread.number, thread.kind == .pullRequest || thread.kind == .issue else {
            throw .http(status: 404, message: "unsupported subject")
        }
        let variables = SubjectVariables(owner: thread.repo.owner, name: thread.repo.name, number: number)
        switch thread.kind {
        case .pullRequest:
            let payload: GQLPullRequestData = try await graphQL(GraphQLQueries.pullRequest, variables: variables)
            guard let pr = payload.repository?.pullRequest else {
                throw .http(status: 404, message: "pull request not found")
            }
            return TimelineMapper.detail(threadID: thread.id, pullRequest: pr, fetchedAt: now.now())
        default:
            let payload: GQLIssueData = try await graphQL(GraphQLQueries.issue, variables: variables)
            guard let issue = payload.repository?.issue else { throw .http(status: 404, message: "issue not found") }
            return TimelineMapper.detail(threadID: thread.id, issue: issue, fetchedAt: now.now())
        }
    }

    public func markRead(_ id: ThreadID) async throws(GitHubError) {
        _ = try await send("PATCH", Self.apiBase.appending(path: "notifications/threads/\(id.rawValue)"))
    }

    public func markDone(_ id: ThreadID) async throws(GitHubError) {
        _ = try await send("DELETE", Self.apiBase.appending(path: "notifications/threads/\(id.rawValue)"))
    }

    public func postComment(repo: RepoRef, number: Int, body: String) async throws(GitHubError) -> TimelineItem {
        let url = Self.apiBase.appending(path: "repos/\(repo.owner)/\(repo.name)/issues/\(number)/comments")
        let (data, _) = try await send("POST", url, body: try Self.jsonBody(["body": body]), headers: Self.fullMediaType)
        return try GitHubJSON.decode(RESTIssueComment.self, from: data, decoder: GitHubJSON.restDecoder()).timelineItem
    }

    public func replyToReviewComment(repo: RepoRef, number: Int, commentDatabaseID: Int, body: String)
        async throws(GitHubError) -> ReviewComment
    {
        let repoPath = "repos/\(repo.owner)/\(repo.name)/pulls"
        let url = Self.apiBase.appending(path: "\(repoPath)/\(number)/comments/\(commentDatabaseID)/replies")
        let (data, _) = try await send("POST", url, body: try Self.jsonBody(["body": body]), headers: Self.fullMediaType)
        let decoder = GitHubJSON.restDecoder()
        let reply = try GitHubJSON.decode(RESTReviewComment.self, from: data, decoder: decoder)
        // REST reports the parent as a database id; the domain threads replies by GraphQL node id.
        let parentDatabaseID = reply.inReplyToId ?? commentDatabaseID
        let (parentData, _) = try await send("GET", Self.apiBase.appending(path: "\(repoPath)/comments/\(parentDatabaseID)"))
        let parent = try GitHubJSON.decode(RESTNodeID.self, from: parentData, decoder: decoder)
        return reply.reviewComment(replyToID: parent.nodeId)
    }

    public func addReaction(_ content: ReactionContent, subjectID: String) async throws(GitHubError) {
        let variables = AddReactionVariables(subjectId: subjectID, content: content.rawValue)
        let _: GQLAddReactionData = try await graphQL(GraphQLQueries.addReaction, variables: variables)
    }

    /// Makes comment responses carry `body_html` / `body_text` alongside the markdown `body`.
    private static let fullMediaType = ["Accept": "application/vnd.github.full+json"]

    // MARK: - Transport

    func graphQL<Payload: Decodable, Variables: Encodable>(_ query: String, variables: Variables) async throws(GitHubError)
        -> Payload
    {
        let body: Data
        do {
            body = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        } catch {
            throw .decoding("Could not encode GraphQL request: \(error.localizedDescription)")
        }
        let (data, _) = try await send("POST", Self.graphQLURL, body: body)
        let response = try GitHubJSON.decode(GraphQLResponse<Payload>.self, from: data, decoder: GitHubJSON.graphQLDecoder())
        if let errors = response.errors, !errors.isEmpty { throw .graphQL(errors.map(\.message)) }
        guard let payload = response.data else { throw .graphQL(["Response contained no data"]) }
        return payload
    }

    /// Sends an authenticated request. A 401 drops the cached token and retries once with a fresh one.
    /// 2xx and 304 are returned; every other status becomes a `GitHubError`.
    func send(
        _ method: String, _ url: URL, body: Data? = nil, headers: [String: String] = [:], notificationsScope: Bool = false
    ) async throws(GitHubError) -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            let token: String
            do {
                token = try await tokens.token()
            } catch {
                throw .auth(error)
            }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("Gitoken", forHTTPHeaderField: "User-Agent")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw .transport(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw .transport("Response was not HTTP") }

            switch http.statusCode {
            case 200..<300, 304:
                return (data, http)
            case 401:
                await tokens.invalidate()
                if attempt == 1 { continue }
                throw .auth(.tokenRejected(status: 401, scopes: http.value(forHTTPHeaderField: "X-OAuth-Scopes")))
            default:
                throw failure(http, data: data, notificationsScope: notificationsScope)
            }
        }
    }

    private func failure(_ response: HTTPURLResponse, data: Data, notificationsScope: Bool) -> GitHubError {
        let status = response.statusCode
        if status == 403 || status == 429 {
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                return .rateLimited(resetAt: reset.map(Date.init(timeIntervalSince1970:)))
            }
            if let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
                return .rateLimited(resetAt: now.now().addingTimeInterval(retryAfter))
            }
            if status == 429 { return .rateLimited(resetAt: nil) }
        }
        if notificationsScope, status == 403 || status == 404 {
            return .auth(.tokenRejected(status: status, scopes: response.value(forHTTPHeaderField: "X-OAuth-Scopes")))
        }
        let message = (try? JSONDecoder().decode(RESTErrorBody.self, from: data))?.message
        return .http(status: status, message: message)
    }

    private static func jsonBody(_ object: [String: String]) throws(GitHubError) -> Data {
        do {
            return try JSONEncoder().encode(object)
        } catch {
            throw .decoding("Could not encode request body: \(error.localizedDescription)")
        }
    }

    static func pollInterval(_ response: HTTPURLResponse) -> TimeInterval {
        let advertised = response.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(TimeInterval.init) ?? 0
        return max(advertised, minimumPollInterval)
    }

    /// Parses `Link: <…?page=2>; rel="next", <…?page=5>; rel="last"`.
    static func nextPageURL(_ response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") {
            let segments = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = segments.first, target.hasPrefix("<"), target.hasSuffix(">"),
                segments.dropFirst().contains(where: { $0 == "rel=\"next\"" || $0 == "rel=next" })
            else { continue }
            return URL(string: String(target.dropFirst().dropLast()))
        }
        return nil
    }
}
