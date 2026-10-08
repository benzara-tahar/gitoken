import Foundation

/// Fixture file previews and reviews: review threads built from the timeline's review comments plus the viewer's pending
/// review, whole files and patches synthesized around each `FixtureSeed.Hunk` so `--fixtures` launches show
/// real-looking previews, and commits that rewrite files on a pull request's head.
extension FixtureGitHubService: FilePreviewService {
    public func reviewThreads(_ ref: PullRequestRef) async throws(GitHubError) -> PullRequestReviewThreads {
        let fetchedAt = now.now()
        let result: PullRequestReviewThreads? = state.withLock { state in
            guard let index = state.pullRequestIndex(ref) else { return nil }
            let fixture = state.threads[index]
            let commits = FixtureSeed.PreviewCommits(ref)
            let pending = state.review.pending.first { $0.ref == ref }
            let comments = Self.reviewComments(in: fixture.items) + (pending?.comments ?? [])
            let threads = comments.filter { $0.replyToID == nil }.map { root in
                let id = Self.reviewThreadID(for: root)
                let outdated = root.id == FixtureSeed.outdatedCommentID
                let origin = state.review.origins[root.id]
                return ReviewThread(
                    id: id, isResolved: state.resolvedReviewThreads.contains(id), isOutdated: outdated, path: root.path,
                    diffSide: origin?.position.side ?? .right, line: outdated ? nil : root.line,
                    startLine: origin?.position.startLine, originalLine: root.line,
                    originalStartLine: origin?.position.startLine,
                    originalCommitOID: origin?.commitOID ?? (outdated ? commits.original : commits.head),
                    comments: [root] + comments.filter { $0.replyToID == root.id }.sorted { $0.createdAt < $1.createdAt },
                    viewerCanResolve: !root.isPending, viewerCanUnresolve: !root.isPending, viewerCanReply: !root.isPending)
            }
            return PullRequestReviewThreads(
                ref: ref, pullRequestID: fixture.nodeID, headOID: state.headOID(ref), baseOID: commits.base,
                headRefName: state.headRefName(index), headRepository: ref.repo.fullName, pendingReviewID: pending?.id,
                viewerIsAuthor: fixture.subject.author == FixtureSeed.viewerLogin, threads: threads, fetchedAt: fetchedAt)
        }
        guard let result else { throw .http(status: 404, message: "pull request not found") }
        return result
    }

    public func fileContents(repo: RepoRef, path: String, commit: String) async throws(GitHubError) -> Data? {
        state.withLock { $0.fileText(repo: repo, path: path, commit: commit) }.map { Data($0.utf8) }
    }

    public func pullRequestFilePatch(_ ref: PullRequestRef, path: String) async throws(GitHubError) -> FilePatch {
        state.withLock { state in
            state.filePatch(repo: ref.repo, base: FixtureSeed.PreviewCommits(ref).base, head: state.headOID(ref), path: path)
        }
    }

    public func filePatch(repo: RepoRef, base: String, head: String, path: String) async throws(GitHubError) -> FilePatch {
        state.withLock { $0.filePatch(repo: repo, base: base, head: head, path: path) }
    }

    public func setThreadResolved(_ threadID: String, resolved: Bool) async throws(GitHubError) {
        let found = state.withLock { state in
            let exists = state.threads.contains { thread in
                Self.reviewComments(in: thread.items).contains { $0.replyToID == nil && Self.reviewThreadID(for: $0) == threadID }
            }
            guard exists else { return false }
            if resolved {
                state.resolvedReviewThreads.insert(threadID)
            } else {
                state.resolvedReviewThreads.remove(threadID)
            }
            return true
        }
        if !found { throw Self.unknownNode(threadID) }
    }

    public func pullRequestFiles(_ ref: PullRequestRef) async throws(GitHubError) -> [ChangedFile] {
        let files: [ChangedFile]? = state.withLock { state in
            guard let index = state.pullRequestIndex(ref) else { return nil }
            let base = FixtureSeed.PreviewCommits(ref).base
            let head = state.headOID(ref)
            return (FixtureSeed.pullRequestFiles[state.threads[index].subject.key] ?? []).compactMap { path in
                let patch = state.filePatch(repo: ref.repo, base: base, head: head, path: path)
                guard patch.status != .unchanged else { return nil }
                let lines = UnifiedDiff.parse(patch.patch ?? "")
                return ChangedFile(
                    path: path, previousPath: patch.previousPath, status: patch.status,
                    additions: lines.count { $0.kind == .added }, deletions: lines.count { $0.kind == .removed },
                    patch: patch)
            }
        }
        guard let files else { throw .http(status: 404, message: "Not Found") }
        return files
    }

    public func startPendingReview(pullRequestID: String, commitOID: String) async throws(GitHubError) -> String {
        let result: Result<String, GitHubError> = state.withLock { state in
            guard let index = state.threads.firstIndex(where: { $0.nodeID == pullRequestID && $0.subject.kind == .pullRequest })
            else { return .failure(Self.unknownNode(pullRequestID)) }
            let ref = PullRequestRef(repo: state.threads[index].repo, number: state.threads[index].subject.number)
            if state.review.pending.contains(where: { $0.ref == ref }) {
                return .failure(.graphQL(["User can only have one pending review per pull request"]))
            }
            let id = "PRR_fx\(state.review.nextReview)"
            state.review.nextReview += 1
            state.review.pending.append(.init(id: id, ref: ref, commitOID: commitOID, comments: []))
            return .success(id)
        }
        return try result.get()
    }

    public func addPendingThread(reviewID: String, position: CommentPosition, body: String) async throws(GitHubError) {
        let at = now.now()
        let failure: GitHubError? = state.withLock { state in
            guard let r = state.review.pending.firstIndex(where: { $0.id == reviewID }),
                  let index = state.pullRequestIndex(state.review.pending[r].ref)
            else { return Self.unknownNode(reviewID) }
            let review = state.review.pending[r]
            let patch = state.filePatch(
                repo: review.ref.repo, base: FixtureSeed.PreviewCommits(review.ref).base, head: state.headOID(review.ref),
                path: position.path)
            let lines = UnifiedDiff.parse(patch.patch ?? "")
            guard let diffHunk = Self.diffHunk(lines, side: position.side, line: position.line),
                  position.startLine.map({ Self.diffHunk(lines, side: position.side, line: $0) != nil }) ?? true
            else { return .graphQL(["Pull request review thread line must be part of the diff"]) }
            let databaseID = state.nextCommentDatabaseID
            state.nextCommentDatabaseID += 1
            let comment = ReviewComment(
                id: "PRRC_fx\(databaseID)", databaseID: databaseID, author: FixtureSeed.person(FixtureSeed.viewerLogin),
                body: RichBody(markdown: body), createdAt: at, path: position.path, diffHunk: diffHunk, line: position.line,
                replyToID: nil, url: state.threads[index].notification.htmlURL.appending(path: "files"), isPending: true)
            state.review.pending[r].comments.append(comment)
            state.review.origins[comment.id] = .init(position: position, commitOID: review.commitOID)
            return nil
        }
        if let failure { throw failure }
    }

    public func deletePendingComment(_ commentID: String) async throws(GitHubError) {
        let found = state.withLock { state in
            for r in state.review.pending.indices {
                guard let c = state.review.pending[r].comments.firstIndex(where: { $0.id == commentID }) else { continue }
                state.review.pending[r].comments.remove(at: c)
                state.review.origins[commentID] = nil
                return true
            }
            return false
        }
        if !found { throw Self.unknownNode(commentID) }
    }

    public func submitReview(pullRequestID: String, reviewID: String?, event: ReviewEvent, body: String)
        async throws(GitHubError)
    {
        let at = now.now()
        let failure: GitHubError? = state.withLock { state in
            guard let index = state.threads.firstIndex(where: { $0.nodeID == pullRequestID && $0.subject.kind == .pullRequest })
            else { return Self.unknownNode(pullRequestID) }
            if state.threads[index].subject.author == FixtureSeed.viewerLogin, event != .comment {
                return .graphQL([event == .approve
                    ? "Can not approve your own pull request" : "Can not request changes on your own pull request"])
            }
            var comments: [ReviewComment] = []
            if let reviewID {
                guard let r = state.review.pending.firstIndex(where: { $0.id == reviewID }) else { return Self.unknownNode(reviewID) }
                comments = state.review.pending.remove(at: r).comments.map(\.submitted)
            }
            if comments.isEmpty, event != .approve, body.allSatisfy(\.isWhitespace) {
                return .graphQL(["Review body is required"])
            }
            let reviewState: ReviewState = switch event {
            case .comment: .commented
            case .approve: .approved
            case .requestChanges: .changesRequested
            }
            Self.appendReview(
                state: reviewState, body: RichBody(markdown: body), comments: comments, by: FixtureSeed.viewerLogin, at: at,
                onThreadAt: index, in: &state)
            return nil
        }
        if let failure { throw failure }
    }

    public func discardPendingReview(_ reviewID: String) async throws(GitHubError) {
        let found = state.withLock { state in
            guard let r = state.review.pending.firstIndex(where: { $0.id == reviewID }) else { return false }
            for comment in state.review.pending.remove(at: r).comments { state.review.origins[comment.id] = nil }
            return true
        }
        if !found { throw Self.unknownNode(reviewID) }
    }

    /// Pushes a commit with `files` (full contents) on top of the pull request whose head is `repository`/`branch`.
    public func commitFiles(
        repository: String, branch: String, expectedHeadOID: String, headline: String, body: String?,
        files: [(path: String, contents: Data)]
    ) async throws(GitHubError) -> String {
        let at = now.now()
        let result: Result<String, GitHubError> = state.withLock { state in
            guard let index = state.threads.indices.first(where: { i in
                state.threads[i].subject.kind == .pullRequest && state.threads[i].repo.fullName == repository
                    && state.headRefName(i) == branch
            }) else { return .failure(.graphQL(["Could not resolve to a Ref named '\(branch)' in '\(repository)'."])) }
            let ref = PullRequestRef(repo: state.threads[index].repo, number: state.threads[index].subject.number)
            guard state.headOID(ref) == expectedHeadOID else {
                return .failure(.graphQL(["Expected branch to point to \"\(expectedHeadOID)\" but it did not.  Pull and try again."]))
            }
            let pushed = state.review.heads[ref] ?? []
            var contents = pushed.last?.files ?? [:]
            for file in files { contents[file.path] = String(decoding: file.contents, as: UTF8.self) }
            let oid = FixtureSeed.fakeOID("\(ref.repo.fullName)#\(ref.number) commit \(pushed.count + 1)")
            state.review.heads[ref, default: []].append(.init(oid: oid, files: contents))
            Self.record(.push([headline]), by: FixtureSeed.viewerLogin, at: at, onThreadAt: index, in: &state)
            return .success(oid)
        }
        return try result.get()
    }

    private static func reviewComments(in items: [TimelineItem]) -> [ReviewComment] {
        items.flatMap { item -> [ReviewComment] in
            if case .review(_, _, let comments) = item.payload { return comments }
            return []
        }
    }

    /// `PRRT_…` named after the root comment, like GitHub's thread ids sit beside `PRRC_…` comment ids.
    private static func reviewThreadID(for root: ReviewComment) -> String {
        root.id.hasPrefix("PRRC_") ? "PRRT_\(root.id.dropFirst("PRRC_".count))" : "PRRT_\(root.id)"
    }

    private static func unknownNode(_ id: String) -> GitHubError {
        .graphQL(["Could not resolve to a node with the global id of '\(id)'"])
    }

    /// GitHub's `diffHunk` for a comment: the enclosing hunk up to `line` on `side`; nil when the line isn't in the diff.
    private static func diffHunk(_ lines: [DiffLine], side: DiffSide, line: Int) -> String? {
        guard let end = lines.firstIndex(where: { diffLine in
            switch side {
            case .right: diffLine.kind != .removed && diffLine.newLine == line
            case .left: diffLine.kind != .added && diffLine.oldLine == line
            }
        }), let start = lines[...end].lastIndex(where: { $0.kind == .hunkHeader })
        else { return nil }
        return lines[start...end].map { diffLine in
            switch diffLine.kind {
            case .hunkHeader: diffLine.text
            case .context: " " + diffLine.text
            case .added: "+" + diffLine.text
            case .removed: "-" + diffLine.text
            }
        }.joined(separator: "\n")
    }
}

/// Pending reviews, the positions of threads they created, and commits pushed by `commitFiles`.
struct FixtureReviewState {
    struct PendingReview {
        let id: String
        let ref: PullRequestRef
        let commitOID: String
        var comments: [ReviewComment]
    }

    struct Origin {
        let position: CommentPosition
        let commitOID: String
    }

    struct PushedCommit {
        let oid: String
        /// Every file rewritten so far on the pull request, by path.
        let files: [String: String]
    }

    var pending: [PendingReview] = []
    var nextReview = 1
    /// Side, range and commit of threads started by `addPendingThread`, by root comment id.
    var origins: [String: Origin] = [:]
    /// Oldest first.
    var heads: [PullRequestRef: [PushedCommit]] = [:]
}

extension FixtureGitHubService.State {
    func pullRequestIndex(_ ref: PullRequestRef) -> Int? {
        index(repo: ref.repo, number: ref.number).flatMap { threads[$0].subject.kind == .pullRequest ? $0 : nil }
    }

    /// The last pushed commit, else the seeded head.
    func headOID(_ ref: PullRequestRef) -> String {
        review.heads[ref]?.last?.oid ?? FixtureSeed.PreviewCommits(ref).head
    }

    /// Stable branch names for seeded PRs, also used by review commit mutations.
    func headRefName(_ index: Int) -> String {
        let thread = threads[index]
        switch (thread.repo.name, thread.subject.number) {
        case ("web", 142): return "akim/debounce-search"
        case ("api", 87): return "dpatel/idempotency-keys"
        case ("api", 91): return "jberg/sliding-window"
        case ("ui-kit", 305): return "akim/button-loading"
        case ("ui-kit", 298): return "pnair/spacing-tshirt"
        case ("web", 120): return "leom/react-19"
        default: return "\(thread.subject.author)/pr-\(thread.subject.number)"
        }
    }

    /// Nil when the file doesn't exist at `commit`.
    func fileText(repo: RepoRef, path: String, commit: String) -> String? {
        if let pushed = pushedCommit(commit, in: repo) {
            return pushed.files[path] ?? FixtureSeed.previewFiles[path]?.text(at: .head)
        }
        guard let version = version(of: commit, in: repo) else { return nil }
        return FixtureSeed.previewFiles[path]?.text(at: version)
    }

    func filePatch(repo: RepoRef, base: String, head: String, path: String) -> FilePatch {
        guard let file = FixtureSeed.previewFiles[path], version(of: base, in: repo) == .base else { return .unchanged }
        if let pushed = pushedCommit(head, in: repo), let text = pushed.files[path] {
            let old = file.text(at: .base)
            guard let patch = FixtureSeed.unifiedDiff(from: old ?? "", to: text) else { return .unchanged }
            return FilePatch(status: old == nil ? .added : .modified, previousPath: nil, patch: patch)
        }
        let headVersion: FixtureSeed.FileVersion? = pushedCommit(head, in: repo) != nil ? .head : version(of: head, in: repo)
        guard let headVersion, headVersion != .base else { return .unchanged }
        return FilePatch(status: file.isAdded ? .added : .modified, previousPath: nil, patch: file.hunk(at: headVersion).patch)
    }

    private func pushedCommit(_ oid: String, in repo: RepoRef) -> FixtureReviewState.PushedCommit? {
        for (ref, commits) in review.heads where ref.repo == repo {
            if let commit = commits.first(where: { $0.oid == oid }) { return commit }
        }
        return nil
    }

    /// Which seeded commit of one of `repo`'s pull requests `oid` is.
    private func version(of oid: String, in repo: RepoRef) -> FixtureSeed.FileVersion? {
        for thread in threads where thread.repo == repo && thread.subject.kind == .pullRequest {
            let commits = FixtureSeed.PreviewCommits(PullRequestRef(repo: thread.repo, number: thread.subject.number))
            switch oid {
            case commits.base: return .base
            case commits.head: return .head
            case commits.original: return .original
            default: continue
            }
        }
        return nil
    }
}

extension ReviewComment {
    /// The same comment once its review is submitted.
    fileprivate var submitted: ReviewComment {
        ReviewComment(
            id: id, databaseID: databaseID, author: author, body: body, createdAt: createdAt, path: path, diffHunk: diffHunk,
            line: line, replyToID: replyToID, url: url, reactions: reactions, isPending: false)
    }
}

extension FixtureSeed {
    /// Node id of the review comment whose thread is outdated at head (written against `originalSearchHunk`).
    static let outdatedCommentID = "PRRC_fxw142-rc0"

    enum FileVersion: Sendable {
        case base, head
        /// The commit outdated threads were written against.
        case original
    }

    /// Deterministic fake commit ids per pull request.
    struct PreviewCommits {
        let base: String
        let head: String
        let original: String

        init(_ ref: PullRequestRef) {
            let key = "\(ref.repo.fullName)#\(ref.number)"
            base = FixtureSeed.fakeOID("\(key) base")
            head = FixtureSeed.fakeOID("\(key) head")
            original = FixtureSeed.fakeOID("\(key) original")
        }
    }

    /// 40 hex digits from FNV-1a over `seed`, salted per 16-digit block.
    static func fakeOID(_ seed: String) -> String {
        var digits = ""
        var salt: UInt64 = 0
        while digits.count < 40 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ salt
            for byte in seed.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0100_0000_01b3
            }
            let block = String(hash, radix: 16)
            digits += String(repeating: "0", count: 16 - block.count) + block
            salt += 1
        }
        return String(digits.prefix(40))
    }

    /// A whole file around one hunk: `prefix` is new-file lines `1..<newStart` (old and new start on the same line),
    /// `suffix` follows the hunk's last line. A hunk starting `@@ -0,0` is a file the pull request adds.
    struct PreviewFileSeed: Sendable {
        let prefix: [String]
        let head: Hunk
        /// The hunk at `FileVersion.original`; files without one look the same as at head.
        let original: Hunk?
        let suffix: [String]

        var isAdded: Bool { head.header.hasPrefix("@@ -0,0 ") }

        func hunk(at version: FileVersion) -> Hunk {
            version == .original ? original ?? head : head
        }

        /// Nil at `.base` for added files.
        func text(at version: FileVersion) -> String? {
            if version == .base, isAdded { return nil }
            let body = version == .base ? head.oldLines : hunk(at: version).newLines
            return (prefix + body + suffix).joined(separator: "\n") + "\n"
        }
    }

    static let previewFiles: [String: PreviewFileSeed] = [
        searchHunk.file: PreviewFileSeed(prefix: searchBoxPrefix, head: searchHunk, original: originalSearchHunk, suffix: searchBoxSuffix),
        resultsHunk.file: PreviewFileSeed(prefix: resultListPrefix, head: resultsHunk, original: nil, suffix: resultListSuffix),
        idempotencyHunk.file: PreviewFileSeed(
            prefix: idempotencyPrefix, head: idempotencyHunk, original: nil, suffix: idempotencySuffix),
        spacingCodemodHunk.file: PreviewFileSeed(prefix: [], head: spacingCodemodHunk, original: nil, suffix: []),
        spacingSCSSHunk.file: PreviewFileSeed(prefix: spacingSCSSPrefix, head: spacingSCSSHunk, original: nil, suffix: spacingSCSSSuffix),
        spacingJSONHunk.file: PreviewFileSeed(prefix: [], head: spacingJSONHunk, original: nil, suffix: spacingJSONSuffix),
    ]

    /// Changed files per pull request (subject key), sorted like GitHub lists them.
    static let pullRequestFiles: [String: [String]] = [
        web142.key: [resultsHunk.file, searchHunk.file],
        "platform/api#87": [idempotencyHunk.file],
        "platform/ui-kit#298": [spacingCodemodHunk.file, spacingSCSSHunk.file, spacingJSONHunk.file],
    ]

    /// Unified diff body (3 lines of context) from `old` to `new`, nil when they're equal. Line-based LCS, sized for
    /// fixture files.
    static func unifiedDiff(from old: String, to new: String) -> String? {
        func lines(_ text: String) -> [String] {
            var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if rows.last == "" { rows.removeLast() }
            return rows
        }
        let a = lines(old)
        let b = lines(new)
        guard a != b else { return nil }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [(marker: String, text: String)] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                ops.append((" ", a[i]))
                i += 1
                j += 1
            } else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] {
                ops.append(("-", a[i]))
                i += 1
            } else {
                ops.append(("+", b[j]))
                j += 1
            }
        }
        var oldBefore = [0]
        var newBefore = [0]
        for op in ops {
            oldBefore.append(oldBefore.last! + (op.marker == "+" ? 0 : 1))
            newBefore.append(newBefore.last! + (op.marker == "-" ? 0 : 1))
        }
        var ranges: [Range<Int>] = []
        for k in ops.indices where ops[k].marker != " " {
            let range = max(0, k - 3)..<min(ops.count, k + 4)
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        var out: [String] = []
        for range in ranges {
            let oldCount = oldBefore[range.upperBound] - oldBefore[range.lowerBound]
            let newCount = newBefore[range.upperBound] - newBefore[range.lowerBound]
            let oldStart = oldBefore[range.lowerBound] + (oldCount == 0 ? 0 : 1)
            let newStart = newBefore[range.lowerBound] + (newCount == 0 ? 0 : 1)
            out.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            out += ops[range].map { $0.marker + $0.text }
        }
        return out.joined(separator: "\n")
    }

    static let spacingCodemodHunk = Hunk(
        file: "scripts/codemods/spacing.ts",
        header: "@@ -0,0 +1,26 @@",
        newStart: 1,
        lines: [
            "+import type { API, FileInfo } from \"jscodeshift\";",
            "+",
            "+const renames: Record<string, string> = {",
            "+  \"space-1\": \"space-3xs\",",
            "+  \"space-2\": \"space-2xs\",",
            "+  \"space-3\": \"space-xs\",",
            "+  \"space-4\": \"space-sm\",",
            "+  \"space-5\": \"space-md\",",
            "+  \"space-6\": \"space-lg\",",
            "+  \"space-7\": \"space-xl\",",
            "+  \"space-8\": \"space-2xl\",",
            "+  \"space-9\": \"space-3xl\",",
            "+};",
            "+",
            "+export default function transform(file: FileInfo, api: API) {",
            "+  const j = api.jscodeshift;",
            "+  return j(file.source)",
            "+    .find(j.Literal)",
            "+    .forEach((path) => {",
            "+      const value = path.node.value;",
            "+      if (typeof value === \"string\" && value in renames) {",
            "+        path.node.value = renames[value];",
            "+      }",
            "+    })",
            "+    .toSource();",
            "+}",
        ]
    )

    static let spacingSCSSHunk = Hunk(
        file: "src/tokens/_spacing.scss",
        header: "@@ -3,14 +3,14 @@ @use \"sass:map\";",
        newStart: 3,
        lines: [
            " ",
            "-$space-1: 2px;",
            "-$space-2: 4px;",
            "-$space-3: 8px;",
            "-$space-4: 12px;",
            "-$space-5: 16px;",
            "-$space-6: 24px;",
            "-$space-7: 32px;",
            "-$space-8: 48px;",
            "-$space-9: 64px;",
            "+$space-3xs: 2px;",
            "+$space-2xs: 4px;",
            "+$space-xs: 8px;",
            "+$space-sm: 12px;",
            "+$space-md: 16px;",
            "+$space-lg: 24px;",
            "+$space-xl: 32px;",
            "+$space-2xl: 48px;",
            "+$space-3xl: 64px;",
            " ",
            " @function space($step) {",
            "-  @return map.get((1: $space-1, 2: $space-2, 3: $space-3), $step);",
            "+  @return map.get((3xs: $space-3xs, 2xs: $space-2xs, xs: $space-xs), $step);",
            " }",
        ]
    )

    private static let spacingSCSSPrefix = [
        "// Generated from spacing.json — do not edit by hand.",
        "@use \"sass:map\";",
    ]

    private static let spacingSCSSSuffix = [
        "",
        "@mixin gap($step) {",
        "  gap: space($step);",
        "}",
    ]

    static let spacingJSONHunk = Hunk(
        file: "src/tokens/spacing.json",
        header: "@@ -1,15 +1,15 @@",
        newStart: 1,
        lines: [
            " {",
            "   \"$schema\": \"../../schemas/tokens.schema.json\",",
            "   \"spacing\": {",
            "-    \"space-1\": { \"value\": \"2px\" },",
            "-    \"space-2\": { \"value\": \"4px\" },",
            "-    \"space-3\": { \"value\": \"8px\" },",
            "-    \"space-4\": { \"value\": \"12px\" },",
            "-    \"space-5\": { \"value\": \"16px\" },",
            "-    \"space-6\": { \"value\": \"24px\" },",
            "-    \"space-7\": { \"value\": \"32px\" },",
            "-    \"space-8\": { \"value\": \"48px\" },",
            "-    \"space-9\": { \"value\": \"64px\" }",
            "+    \"3xs\": { \"value\": \"2px\" },",
            "+    \"2xs\": { \"value\": \"4px\" },",
            "+    \"xs\": { \"value\": \"8px\" },",
            "+    \"sm\": { \"value\": \"12px\" },",
            "+    \"md\": { \"value\": \"16px\" },",
            "+    \"lg\": { \"value\": \"24px\" },",
            "+    \"xl\": { \"value\": \"32px\" },",
            "+    \"2xl\": { \"value\": \"48px\" },",
            "+    \"3xl\": { \"value\": \"64px\" }",
            "   },",
            "   \"radius\": {",
            "     \"sm\": { \"value\": \"4px\" },",
        ]
    )

    private static let spacingJSONSuffix = [
        "    \"md\": { \"value\": \"8px\" }",
        "  }",
        "}",
    ]

    private static let searchBoxPrefix = [
        "import { useEffect, useRef, useState } from \"react\";",
        "import { ClearIcon, SearchIcon } from \"../icons\";",
        "import { useDebouncedValue } from \"../hooks/useDebouncedValue\";",
        "import styles from \"./SearchBox.module.css\";",
        "",
        "export type SearchOptions = {",
        "  /** Aborted when a newer query supersedes this one. */",
        "  signal?: AbortSignal;",
        "};",
        "",
        "type Props = {",
        "  /** Called with the query once typing settles. */",
        "  onSearch: (query: string, options?: SearchOptions) => void;",
        "  /** Prefills the input, e.g. from the `?q=` deep link. */",
        "  initialQuery?: string;",
        "};",
        "",
        "/**",
        " * Global search field.",
        " *",
        " * Typing is debounced so a burst of keystrokes sends one request, and the",
        " * request for a superseded query is aborted.",
        " */",
        "// The \"/\" shortcut is registered by `useGlobalShortcuts` in `AppShell`;",
        "// it focuses the input through `inputRef`.",
        "// eslint-disable-next-line max-lines-per-function",
        "export function SearchBox({ onSearch, initialQuery }: Props) {",
    ]

    private static let searchBoxSuffix = [
        "        placeholder=\"Search issues, pull requests, and people\"",
        "        aria-label=\"Search\"",
        "        spellCheck={false}",
        "      />",
        "      {value && (",
        "        <button",
        "          type=\"button\"",
        "          className={styles.clear}",
        "          aria-label=\"Clear search\"",
        "          onClick={() => {",
        "            setValue(\"\");",
        "            inputRef.current?.focus();",
        "          }}",
        "        >",
        "          <ClearIcon aria-hidden />",
        "        </button>",
        "      )}",
        "    </div>",
        "  );",
        "}",
    ]

    private static let resultListPrefix = [
        "import { memo, useCallback } from \"react\";",
        "import type { SearchResult } from \"../api/search\";",
        "import { highlight } from \"../lib/highlight\";",
        "import styles from \"./ResultList.module.css\";",
        "",
        "const ResultRow = memo(function ResultRow({ result, query }: { result: SearchResult; query: string }) {",
        "  return <a href={result.url} className={styles.row}>{highlight(result.title, query)}</a>;",
        "});",
        "",
        "type Props = { results: SearchResult[]; query: string };",
        "",
        "/** Search results as a listbox; rows re-render only when their result or the query changes. */",
        "// Keyboard navigation lives in `useListboxNavigation` (see `SearchPage`).",
    ]

    private static let resultListSuffix = [
        "",
        "export function EmptyResults({ query }: { query: string }) {",
        "  return (",
        "    <p className={styles.empty}>",
        "      No results for <strong>{query}</strong>",
        "    </p>",
        "  );",
        "}",
    ]

    private static let idempotencyPrefix = [
        "package payments",
        "",
        "import (",
        "\t\"bytes\"",
        "\t\"context\"",
        "\t\"net/http\"",
        "\t\"time\"",
        ")",
        "",
        "// ResponseStore keeps serialized responses keyed by idempotency key.",
        "type ResponseStore interface {",
        "\tGet(ctx context.Context, key string) (*CachedResponse, bool)",
        "\tPut(ctx context.Context, key string, res *CachedResponse, ttl time.Duration)",
        "}",
        "",
        "// CachedResponse is a recorded response that can be replayed verbatim.",
        "type CachedResponse struct {",
        "\tStatus int",
        "\tHeader http.Header",
        "\tBody   []byte",
        "}",
        "",
        "// WriteTo replays the response.",
        "func (c *CachedResponse) WriteTo(w http.ResponseWriter) {",
        "\tfor k, v := range c.Header {",
        "\t\tw.Header()[k] = v",
        "\t}",
        "\tw.WriteHeader(c.Status)",
        "\t_, _ = bytes.NewReader(c.Body).WriteTo(w)",
        "}",
        "",
        "// Idempotency replays the first response for a repeated Idempotency-Key.",
        "type Idempotency struct {",
        "\tstore ResponseStore",
        "}",
        "",
        "func NewIdempotency(store ResponseStore) *Idempotency { return &Idempotency{store: store} }",
        "",
        "// Wrap returns next guarded by the idempotency store.",
        "func (m *Idempotency) Wrap(next http.Handler) http.Handler {",
    ]

    private static let idempotencySuffix = [
        "",
        "// recorder captures a handler's response while passing it through.",
        "type recorder struct {",
        "\thttp.ResponseWriter",
        "\tstatus int",
        "\tbody   bytes.Buffer",
        "}",
        "",
        "func newRecorder(w http.ResponseWriter) *recorder {",
        "\treturn &recorder{ResponseWriter: w, status: http.StatusOK}",
        "}",
        "",
        "func (r *recorder) WriteHeader(status int) {",
        "\tr.status = status",
        "\tr.ResponseWriter.WriteHeader(status)",
        "}",
        "",
        "func (r *recorder) Write(p []byte) (int, error) {",
        "\tr.body.Write(p)",
        "\treturn r.ResponseWriter.Write(p)",
        "}",
        "",
        "// Result returns the recorded response.",
        "func (r *recorder) Result() *CachedResponse {",
        "\treturn &CachedResponse{Status: r.status, Header: r.Header().Clone(), Body: r.body.Bytes()}",
        "}",
    ]
}

extension FixtureSeed.Hunk {
    /// Lines on the new side (context + added), markers stripped.
    var newLines: [String] { lines.filter { !$0.hasPrefix("-") }.map { String($0.dropFirst()) } }
    /// Lines on the old side (context + removed), markers stripped.
    var oldLines: [String] { lines.filter { !$0.hasPrefix("+") }.map { String($0.dropFirst()) } }
    /// Unified diff body: header plus lines.
    var patch: String { ([header] + lines).joined(separator: "\n") }
}
