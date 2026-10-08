import Foundation

extension GitHubClient: FilePreviewService {
    public func reviewThreads(_ ref: PullRequestRef) async throws(GitHubError) -> PullRequestReviewThreads {
        let variables = SubjectVariables(owner: ref.repo.owner, name: ref.repo.name, number: ref.number)
        let payload: GQLFilePreviewData = try await graphQL(FilePreviewQueries.reviewThreads, variables: variables)
        guard let pr = payload.repository?.pullRequest else { throw .http(status: 404, message: "pull request not found") }
        return pr.threads(ref: ref, fetchedAt: now.now())
    }

    public func fileContents(repo: RepoRef, path: String, commit: String) async throws(GitHubError) -> Data? {
        let url = Self.apiBase.appending(path: "repos/\(repo.owner)/\(repo.name)/contents/\(path)")
            .appending(queryItems: [URLQueryItem(name: "ref", value: commit)])
        do throws(GitHubError) {
            return try await send("GET", url, headers: ["Accept": "application/vnd.github.raw+json"]).0
        } catch .http(404, _) {
            return nil
        }
    }

    public func pullRequestFilePatch(_ ref: PullRequestRef, path: String) async throws(GitHubError) -> FilePatch {
        var renamed: RESTChangedFile?
        var found: RESTChangedFile?
        try await forEachPullRequestFilesPage(ref) { files in
            found = files.first { $0.filename == path }
            renamed = renamed ?? files.first { $0.previousFilename == path }
            return found == nil
        }
        return (found ?? renamed)?.filePatch ?? .unchanged
    }

    public func pullRequestFiles(_ ref: PullRequestRef) async throws(GitHubError) -> [ChangedFile] {
        var all: [ChangedFile] = []
        try await forEachPullRequestFilesPage(ref) { files in
            all += files.map(\.changedFile)
            return true
        }
        return all
    }

    /// Walks `pulls/{n}/files` pages until `page` returns false or the pages run out.
    private func forEachPullRequestFilesPage(
        _ ref: PullRequestRef, _ page: ([RESTChangedFile]) -> Bool
    ) async throws(GitHubError) {
        var next: URL? = Self.apiBase.appending(path: "repos/\(ref.repo.owner)/\(ref.repo.name)/pulls/\(ref.number)/files")
            .appending(queryItems: [URLQueryItem(name: "per_page", value: "100")])
        var visited = Set<URL>()
        let decoder = GitHubJSON.restDecoder()
        while let url = next, visited.insert(url).inserted {
            let (data, response) = try await send("GET", url)
            guard page(try GitHubJSON.decode([RESTChangedFile].self, from: data, decoder: decoder)) else { return }
            next = Self.nextPageURL(response)
        }
    }

    /// Compare paginates commits, not files: the first page carries every file (up to 300), so one request suffices and
    /// `per_page=1` keeps the commit list small.
    public func filePatch(repo: RepoRef, base: String, head: String, path: String) async throws(GitHubError) -> FilePatch {
        let url = Self.apiBase.appending(path: "repos/\(repo.owner)/\(repo.name)/compare/\(base)...\(head)")
            .appending(queryItems: [URLQueryItem(name: "per_page", value: "1")])
        let (data, _) = try await send("GET", url)
        let files = try GitHubJSON.decode(RESTCompare.self, from: data, decoder: GitHubJSON.restDecoder()).files ?? []
        let file = files.first { $0.filename == path } ?? files.first { $0.previousFilename == path }
        return file?.filePatch ?? .unchanged
    }

    public func setThreadResolved(_ threadID: String, resolved: Bool) async throws(GitHubError) {
        let query = resolved ? FilePreviewQueries.resolveThread : FilePreviewQueries.unresolveThread
        let _: GQLResolveThreadData = try await graphQL(query, variables: ReviewThreadIDVariables(threadId: threadID))
    }

    public func startPendingReview(pullRequestID: String, commitOID: String) async throws(GitHubError) -> String {
        let variables = StartReviewVariables(pullRequestId: pullRequestID, commitOID: commitOID)
        let payload: GQLReviewPayloadData = try await graphQL(FilePreviewQueries.startReview, variables: variables)
        guard let id = payload.addPullRequestReview?.pullRequestReview?.id else {
            throw .graphQL(["GitHub didn't start a review."])
        }
        return id
    }

    public func addPendingThread(reviewID: String, position: CommentPosition, body: String) async throws(GitHubError) {
        let variables = AddThreadVariables(reviewID: reviewID, position: position, body: body)
        let payload: GQLAddThreadData = try await graphQL(FilePreviewQueries.addThread, variables: variables)
        // GitHub answers a null thread (no error) when the line isn't part of the diff.
        if payload.addPullRequestReviewThread?.thread == nil {
            throw .graphQL(["GitHub couldn't place a comment on that line."])
        }
    }

    public func deletePendingComment(_ commentID: String) async throws(GitHubError) {
        let _: GQLReviewPayloadData = try await graphQL(FilePreviewQueries.deleteComment, variables: NodeIDVariables(id: commentID))
    }

    public func submitReview(pullRequestID: String, reviewID: String?, event: ReviewEvent, body: String)
        async throws(GitHubError)
    {
        if let reviewID {
            let variables = SubmitReviewVariables(pullRequestReviewId: reviewID, event: event.rawValue, body: body)
            let _: GQLReviewPayloadData = try await graphQL(FilePreviewQueries.submitReview, variables: variables)
        } else {
            let variables = AddReviewVariables(pullRequestId: pullRequestID, event: event.rawValue, body: body)
            let _: GQLReviewPayloadData = try await graphQL(FilePreviewQueries.addReview, variables: variables)
        }
    }

    public func discardPendingReview(_ reviewID: String) async throws(GitHubError) {
        let variables = ReviewIDVariables(pullRequestReviewId: reviewID)
        let _: GQLReviewPayloadData = try await graphQL(FilePreviewQueries.deleteReview, variables: variables)
    }

    public func commitFiles(
        repository: String, branch: String, expectedHeadOID: String, headline: String, body: String?,
        files: [(path: String, contents: Data)]
    ) async throws(GitHubError) -> String {
        typealias Input = CreateCommitVariables.Input
        let input = Input(
            branch: .init(repositoryNameWithOwner: repository, branchName: branch),
            message: .init(headline: headline, body: body), expectedHeadOid: expectedHeadOID,
            fileChanges: .init(additions: files.map { .init(path: $0.path, contents: $0.contents.base64EncodedString()) }))
        let payload: GQLCreateCommitData = try await graphQL(FilePreviewQueries.createCommit, variables: CreateCommitVariables(input: input))
        guard let oid = payload.createCommitOnBranch?.commit?.oid else { throw .graphQL(["GitHub didn't create the commit."]) }
        return oid
    }
}
