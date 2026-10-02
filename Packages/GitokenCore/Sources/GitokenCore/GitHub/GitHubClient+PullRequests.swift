import Foundation

extension GitHubClient: PullRequestService {
    static let lookupBatchSize = 20
    static let maxLogTails = 5

    public func myOpenPullRequests() async throws(GitHubError) -> [PullRequestStatus] {
        let payload: GQLShelfSearchData = try await tolerantGraphQL(
            ShelfQueries.mine, variables: SearchVariables(query: ShelfQueries.mineSearch))
        let login = payload.viewer.login
        return payload.search.nodes.compactMap { $0?.pullRequest?.status(viewerLogin: login) }
    }

    public func pullRequests(_ refs: [PullRequestRef]) async throws(GitHubError) -> [PullRequestStatus] {
        var unique: [PullRequestRef] = []
        for ref in refs where !unique.contains(ref) { unique.append(ref) }
        var statuses: [PullRequestStatus] = []
        var start = 0
        while start < unique.count {
            let batch = Array(unique[start..<min(start + Self.lookupBatchSize, unique.count)])
            start += batch.count
            var variables: [String: GraphQLScalar] = [:]
            for (index, ref) in batch.enumerated() {
                variables["o\(index)"] = .string(ref.repo.owner)
                variables["n\(index)"] = .string(ref.repo.name)
                variables["p\(index)"] = .int(ref.number)
            }
            let payload: GQLShelfLookupData = try await tolerantGraphQL(
                ShelfQueries.lookup(count: batch.count), variables: variables)
            for index in batch.indices {
                if let pr = payload.pullRequests[index] { statuses.append(pr.status(viewerLogin: payload.viewerLogin)) }
            }
        }
        return statuses
    }

    public func merge(_ pr: PullRequestStatus, method: MergeMethod) async throws(GitHubError) {
        let url = Self.apiBase.appending(path: "repos/\(pr.ref.repo.owner)/\(pr.ref.repo.name)/pulls/\(pr.ref.number)/merge")
        let body: Data
        do {
            body = try JSONEncoder().encode(["merge_method": method.rawValue, "sha": pr.headRefOID])
        } catch {
            throw .decoding("Could not encode merge request: \(error.localizedDescription)")
        }
        _ = try await send("PUT", url, body: body)
    }

    public func agentContext(for ref: PullRequestRef) async throws(GitHubError) -> String {
        let variables = SubjectVariables(owner: ref.repo.owner, name: ref.repo.name, number: ref.number)
        let payload: GQLAgentContextData = try await graphQL(ShelfQueries.agentContext, variables: variables)
        guard let pr = payload.repository?.pullRequest else { throw .http(status: 404, message: "pull request not found") }

        let threads = pr.reviewThreads.items.map { thread in
            AgentContext.ReviewThread(
                path: thread.path, line: thread.line ?? thread.originalLine, isResolved: thread.isResolved,
                isOutdated: thread.isOutdated, diffHunk: thread.comments.items.first?.diffHunk ?? "",
                comments: thread.comments.items.map { AgentContext.Comment(author: $0.author?.login ?? "ghost", body: $0.body) }
            )
        }
        let failing = pr.commits.items.last?.commit.statusCheckRollup?.contexts.items.filter(\.isFailing) ?? []
        let jobs = failing.compactMap(\.actionsJobID).prefix(Self.maxLogTails)
        let tails = await withTaskGroup(of: (Int, String?).self) { group in
            for job in jobs { group.addTask { (job, await self.jobLogTail(repo: ref.repo, jobID: job)) } }
            var tails: [Int: String] = [:]
            for await (job, tail) in group { if let tail { tails[job] = tail } }
            return tails
        }
        let checks = failing.map { check in
            AgentContext.FailingCheck(
                name: check.name ?? check.context ?? "check",
                detailsURL: (check.detailsUrl ?? check.targetUrl).flatMap(URL.init(string:)),
                summary: check.summary ?? check.description,
                logTail: check.actionsJobID.flatMap { tails[$0] }
            )
        }
        return AgentContext(
            ref: ref, title: pr.title, headRefName: pr.headRefName, baseRefName: pr.baseRefName, body: pr.body,
            threads: threads, failingChecks: checks
        ).markdown
    }

    // MARK: Helpers

    /// GraphQL that tolerates per-node `NOT_FOUND` / `FORBIDDEN` errors (deleted PRs, SSO-protected orgs) as long as
    /// data came back; those nodes decode as null.
    private func tolerantGraphQL<Payload: Decodable, Variables: Encodable>(_ query: String, variables: Variables)
        async throws(GitHubError) -> Payload
    {
        let body: Data
        do {
            body = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        } catch {
            throw .decoding("Could not encode GraphQL request: \(error.localizedDescription)")
        }
        let (data, _) = try await send("POST", Self.graphQLURL, body: body)
        let response = try GitHubJSON.decode(ShelfGraphQLResponse<Payload>.self, from: data, decoder: GitHubJSON.graphQLDecoder())
        let errors = response.errors ?? []
        let tolerated: Set<String> = ["NOT_FOUND", "FORBIDDEN"]
        if let payload = response.data, errors.allSatisfy({ tolerated.contains($0.type ?? "") }) { return payload }
        if !errors.isEmpty { throw .graphQL(errors.map(\.message)) }
        throw .graphQL(["Response contained no data"])
    }

    /// Tail of a GitHub Actions job log. The API answers with a redirect to a pre-signed download URL that must be
    /// fetched without the GitHub token. Nil when the log is unavailable (expired, no access, network).
    private func jobLogTail(repo: RepoRef, jobID: Int) async -> String? {
        guard let token = try? await tokens.token() else { return nil }
        var request = URLRequest(url: Self.apiBase.appending(path: "repos/\(repo.owner)/\(repo.name)/actions/jobs/\(jobID)/logs"))
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Gitoken", forHTTPHeaderField: "User-Agent")
        do {
            var (data, response) = try await session.data(for: request, delegate: NoRedirects.shared)
            guard var http = response as? HTTPURLResponse else { return nil }
            if (300..<400).contains(http.statusCode) {
                guard let location = http.value(forHTTPHeaderField: "Location"), let target = URL(string: location) else {
                    return nil
                }
                (data, response) = try await session.data(from: target)
                guard let redirected = response as? HTTPURLResponse else { return nil }
                http = redirected
            }
            guard (200..<300).contains(http.statusCode) else { return nil }
            let tail = AgentContext.logTail(String(decoding: data, as: UTF8.self))
            return tail.isEmpty ? nil : tail
        } catch {
            return nil
        }
    }
}

/// Stops URLSession from following redirects so the caller can drop the Authorization header first.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
