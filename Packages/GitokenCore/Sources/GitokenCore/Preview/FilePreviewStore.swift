import Foundation
import Observation

public struct PreviewTarget: Hashable, Sendable {
    /// Inbox group (replies go through `InboxStore.reply`).
    public let threadID: ThreadID
    public let ref: PullRequestRef
    public let path: String
    /// Review comment node id to focus.
    public let commentID: String?

    public init(threadID: ThreadID, ref: PullRequestRef, path: String, commentID: String?) {
        self.threadID = threadID
        self.ref = ref
        self.path = path
        self.commentID = commentID
    }

    /// Newest review comment (by createdAt) in the detail; nil when there are none.
    public static func newest(in detail: ThreadDetail, threadID: ThreadID, ref: PullRequestRef) -> PreviewTarget? {
        let comments = detail.items.flatMap { item -> [ReviewComment] in
            if case .review(_, _, let comments) = item.payload { return comments }
            return []
        }
        guard let newest = comments.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        return PreviewTarget(threadID: threadID, ref: ref, path: newest.path, commentID: newest.id)
    }
}

public enum PreviewFile: Hashable, Sendable {
    case text(String)
    case binary
    /// Absent at the viewed commit (deleted / not yet added).
    case missing
    /// Over the size policy until loaded with `forceLarge`.
    case collapsed(bytes: Int)
}

public struct PreviewContent: Sendable {
    public let target: PreviewTarget
    /// Head, or the focused outdated thread's original commit.
    public let viewing: PreviewCommit
    /// At `viewing`.
    public let file: PreviewFile
    /// `base...viewing`.
    public let patch: FilePatch

    public init(target: PreviewTarget, viewing: PreviewCommit, file: PreviewFile, patch: FilePatch) {
        self.target = target
        self.viewing = viewing
        self.file = file
        self.patch = patch
    }
}

public enum PreviewLoad: Sendable {
    case loading
    case loaded(PreviewContent)
    case failed(String)
}

/// Review threads, file contents, and patches fetched from GitHub for the preview window.
/// Everything is cached; documents are built off the main actor.
@MainActor @Observable
public final class FilePreviewStore {
    /// Threads older than this are refetched by `load`.
    static let threadsMaxAge: TimeInterval = 60
    static let prefetchDelay: Duration = .milliseconds(150)

    /// Review threads per PR, kept current by resolve/reply. Views read threads from here so cards update in place.
    public private(set) var threads: [PullRequestRef: PullRequestReviewThreads] = [:]
    /// Changed files per PR at its current head (seeds the patch cache for head).
    public private(set) var changedFiles: [PullRequestRef: [ChangedFile]] = [:]
    /// Batched suggestions per PR (in memory).
    public private(set) var suggestionBatches: [PullRequestRef: [SuggestionItem]] = [:]

    public static let defaultCommitHeadline = "Apply suggestions from code review"
    static let ownPullRequestMessage = "You can't approve or request changes on your own pull request."
    static let branchMovedMessage = "The branch moved; refresh and try again."

    private let service: any FilePreviewService
    private let now: any NowProvider
    private let postReply: @MainActor (ThreadID, String, ReviewComment?) async throws(GitHubError) -> Void

    @ObservationIgnored private var threadFetches: [PullRequestRef: (id: Int, task: Task<Result<PullRequestReviewThreads, GitHubError>, Never>)] = [:]
    @ObservationIgnored private var nextFetchID = 0
    @ObservationIgnored private var files = BoundedCache<FileKey, FetchedFile>(capacity: 48)
    @ObservationIgnored private var patches = BoundedCache<PatchKey, FilePatch>(capacity: 96)
    @ObservationIgnored private var documents = BoundedCache<DocumentKey, PreviewDocument>(capacity: 16)
    @ObservationIgnored private var resolveMutations: [String: ResolveMutation] = [:]
    private let fileFlights = InFlight<FileKey, FetchedFile, GitHubError>()
    private let patchFlights = InFlight<PatchKey, FilePatch, GitHubError>()
    private let documentFlights = InFlight<DocumentKey, PreviewDocument, Never>()
    private let fileListFlights = InFlight<PullRequestRef, [ChangedFile], GitHubError>()
    /// Head oid `changedFiles` was listed at.
    @ObservationIgnored private var changedFilesHead: [PullRequestRef: String] = [:]
    /// Pending reviews started here, until threads list them.
    @ObservationIgnored private var startedReviews: [PullRequestRef: String] = [:]
    /// Reviews submitted or discarded here, which cached threads may still list as pending.
    @ObservationIgnored private var closedReviews: Set<String> = []
    /// Tail of each PR's pending-review mutations; every add/delete/submit/discard runs after the previous one.
    @ObservationIgnored private var reviewQueues: [PullRequestRef: Task<Void, Never>] = [:]
    /// Heads replaced by a commit pushed from here: a lagging fetch that still reports `old` is read as `new`.
    @ObservationIgnored private var pushedHeads: [PullRequestRef: (old: String, new: String)] = [:]
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTarget: PreviewTarget?

    /// `postReply` posts a reply in the inbox thread, under the given review comment.
    init(
        service: any FilePreviewService, now: any NowProvider,
        postReply: @escaping @MainActor (ThreadID, String, ReviewComment?) async throws(GitHubError) -> Void
    ) {
        self.service = service
        self.now = now
        self.postReply = postReply
    }

    // MARK: Loading

    /// Loads (or returns cached) content. `commit` nil = automatic (original commit when the focused thread is outdated,
    /// else head). `forceLarge` bypasses `.collapsed`.
    public func load(_ target: PreviewTarget, commit: PreviewCommit?, forceLarge: Bool) async -> PreviewLoad {
        do throws(GitHubError) {
            return .loaded(try await content(target, commit: commit, forceLarge: forceLarge))
        } catch {
            return .failed(Self.describe(error))
        }
    }

    /// Debounced (150 ms), deduplicated warm-up of threads + file + patch for `target`. Cancels the previous prefetch.
    public func prefetch(_ target: PreviewTarget) {
        if prefetchTarget == target, prefetchTask != nil { return }
        prefetchTask?.cancel()
        prefetchTarget = target
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.prefetchDelay)
            guard !Task.isCancelled, let self else { return }
            _ = await self.load(target, commit: nil, forceLarge: false)
            if self.prefetchTarget == target {
                self.prefetchTask = nil
                self.prefetchTarget = nil
            }
        }
    }

    /// Built off the main actor and cached per (content, mode).
    public func document(for content: PreviewContent, mode: PreviewMode) async -> PreviewDocument {
        let path = content.target.path
        let onPath = threads[content.target.ref]?.threads(on: path) ?? []
        let key = DocumentKey(
            repo: content.target.ref.repo, path: path, viewing: content.viewing, file: content.file, patch: content.patch,
            mode: mode, anchors: onPath.map(AnchorSignature.init))
        if let cached = documents[key] { return cached }
        let fileText: String? = if case .text(let text) = content.file { text } else { nil }
        let patch = content.patch.patch
        let viewing = content.viewing
        let document = await documentFlights.run(key) {
            await Task.detached(priority: .userInitiated) {
                PreviewDocument.build(
                    mode: mode, path: path, fileText: fileText, patch: patch, threads: onPath, viewing: viewing)
            }.value
        }
        documents.insert(document, for: key)
        return document
    }

    // MARK: Thread actions

    /// Optimistic; rolls back and rethrows on failure. Overlapping calls for one thread are ordered: only the newest may
    /// roll back, and it restores the last state GitHub confirmed.
    public func setResolved(_ threadID: String, in ref: PullRequestRef, resolved: Bool) async throws(GitHubError) {
        let current = threads[ref]?.threads.first { $0.id == threadID }?.isResolved
        var mutation = resolveMutations[threadID] ?? ResolveMutation(generation: 0, confirmed: current, confirmedGeneration: 0)
        mutation.generation += 1
        let generation = mutation.generation
        resolveMutations[threadID] = mutation
        updateThread(threadID, in: ref) { $0.isResolved = resolved }
        defer {
            if resolveMutations[threadID]?.generation == generation { resolveMutations[threadID] = nil }
        }
        do throws(GitHubError) {
            try await service.setThreadResolved(threadID, resolved: resolved)
            if var latest = resolveMutations[threadID], generation > latest.confirmedGeneration {
                latest.confirmed = resolved
                latest.confirmedGeneration = generation
                resolveMutations[threadID] = latest
            }
        } catch {
            if let latest = resolveMutations[threadID], latest.generation == generation, let confirmed = latest.confirmed {
                updateThread(threadID, in: ref) { $0.isResolved = confirmed }
            }
            throw error
        }
    }

    /// Posts via `InboxStore.reply(to:body:inReplyTo:)` (so the open conversation updates too), then refreshes threads.
    public func reply(_ body: String, to thread: ReviewThread, target: PreviewTarget) async throws(GitHubError) {
        try await postReply(target.threadID, body, thread.root)
        _ = try? await reviewThreads(target.ref, maxAge: nil)
    }

    // MARK: Review

    /// Changed files at head, cached until the head moves. Seeds the patch cache so selecting a file needs no request.
    public func loadFiles(_ ref: PullRequestRef) async throws(GitHubError) -> [ChangedFile] {
        let prThreads = try await reviewThreads(ref, maxAge: Self.threadsMaxAge)
        let head = prThreads.headOID
        if let cached = changedFiles[ref], changedFilesHead[ref] == head { return cached }
        let service = service
        let files = try await fileListFlights.run(ref) { () async throws(GitHubError) -> [ChangedFile] in
            try await service.pullRequestFiles(ref)
        }
        for file in files {
            patches.insert(file.patch, for: PatchKey(repo: ref.repo, base: prThreads.baseOID, head: head, path: file.path))
        }
        changedFiles[ref] = files
        changedFilesHead[ref] = head
        return files
    }

    /// Adds a comment to the viewer's pending review (starting one at head when needed), then refreshes threads.
    public func addReviewComment(_ body: String, at position: CommentPosition, in ref: PullRequestRef) async throws(GitHubError) {
        try await serialReview(ref) { () async throws(GitHubError) in
            let prThreads = try await self.reviewThreads(ref, maxAge: Self.threadsMaxAge)
            let reviewID: String
            if let open = self.openReviewID(prThreads) {
                reviewID = open
            } else {
                reviewID = try await self.service.startPendingReview(
                    pullRequestID: prThreads.pullRequestID, commitOID: prThreads.headOID)
                self.startedReviews[ref] = reviewID
            }
            try await self.service.addPendingThread(reviewID: reviewID, position: position, body: body)
            _ = try? await self.reviewThreads(ref, maxAge: nil)
        }
    }

    public func deletePendingComment(_ commentID: String, in ref: PullRequestRef) async throws(GitHubError) {
        try await serialReview(ref) { () async throws(GitHubError) in
            try await self.service.deletePendingComment(commentID)
            _ = try? await self.reviewThreads(ref, maxAge: nil)
        }
    }

    /// Submits the pending review (or a body-only review), refreshes threads. Approve / request changes on the viewer's
    /// own pull request fails with `ownPullRequestMessage` without calling GitHub.
    public func submitReview(_ event: ReviewEvent, body: String, in ref: PullRequestRef) async throws(GitHubError) {
        try await serialReview(ref) { () async throws(GitHubError) in
            let prThreads = try await self.reviewThreads(ref, maxAge: Self.threadsMaxAge)
            if event != .comment, prThreads.viewerIsAuthor { throw .http(status: 422, message: Self.ownPullRequestMessage) }
            let reviewID = self.openReviewID(prThreads)
            try await self.service.submitReview(
                pullRequestID: prThreads.pullRequestID, reviewID: reviewID, event: event, body: body)
            self.closeReview(reviewID, in: ref)
            _ = try? await self.reviewThreads(ref, maxAge: nil)
        }
    }

    /// Deletes the viewer's pending review and its comments; nothing to do without one.
    public func discardPendingReview(in ref: PullRequestRef) async throws(GitHubError) {
        try await serialReview(ref) { () async throws(GitHubError) in
            let prThreads = try await self.reviewThreads(ref, maxAge: Self.threadsMaxAge)
            guard let reviewID = self.openReviewID(prThreads) else { return }
            try await self.service.discardPendingReview(reviewID)
            self.closeReview(reviewID, in: ref)
            _ = try? await self.reviewThreads(ref, maxAge: nil)
        }
    }

    /// Runs `work` after every earlier pending-review mutation on `ref` finished, so a submit or discard never
    /// interleaves with an add that is still starting the review or posting its comment.
    private func serialReview(
        _ ref: PullRequestRef, _ work: @escaping @MainActor () async throws(GitHubError) -> Void
    ) async throws(GitHubError) {
        let previous = reviewQueues[ref]
        let task = Task { @MainActor () async -> GitHubError? in
            await previous?.value
            do throws(GitHubError) {
                try await work()
                return nil
            } catch {
                return error
            }
        }
        let tail = Task { _ = await task.value }
        reviewQueues[ref] = tail
        let failure = await task.value
        if reviewQueues[ref] == tail { reviewQueues[ref] = nil }
        if let failure { throw failure }
    }

    /// The viewer's pending review per GitHub or started here, unless it was submitted or discarded since.
    private func openReviewID(_ prThreads: PullRequestReviewThreads) -> String? {
        [prThreads.pendingReviewID, startedReviews[prThreads.ref]].compactMap { $0 }.first { !closedReviews.contains($0) }
    }

    private func closeReview(_ reviewID: String?, in ref: PullRequestRef) {
        if let reviewID { closedReviews.insert(reviewID) }
        startedReviews[ref] = nil
    }

    // MARK: Suggestions

    /// Throws `.http(status: 422, …)` when the item overlaps one already batched for the same path.
    public func addToBatch(_ item: SuggestionItem, in ref: PullRequestRef) throws(GitHubError) {
        var batch = suggestionBatches[ref] ?? []
        if batch.contains(where: { $0.commentID == item.commentID }) { return }
        if batch.contains(where: { $0.path == item.path && $0.startLine <= item.endLine && item.startLine <= $0.endLine }) {
            throw .http(status: 422, message: "This suggestion overlaps one already in the batch.")
        }
        batch.append(item)
        suggestionBatches[ref] = batch
    }

    public func removeFromBatch(_ commentID: String, in ref: PullRequestRef) {
        guard var batch = suggestionBatches[ref] else { return }
        batch.removeAll { $0.commentID == commentID }
        suggestionBatches[ref] = batch.isEmpty ? nil : batch
    }

    /// Applies the batch as one commit on the head branch, expecting the head the items were read at. Items are
    /// re-derived from fresh threads (GitHub moves thread lines with new commits); each touched file is read at that
    /// exact head from GitHub, and `commitFiles` refuses if the branch moved meanwhile. Then records the new
    /// head, resolves the batched threads (best effort), removes the committed items from the batch (items batched
    /// meanwhile stay), drops caches keyed on the old head and refreshes threads.
    public func commitBatch(in ref: PullRequestRef, headline: String = FilePreviewStore.defaultCommitHeadline)
        async throws(GitHubError)
    {
        guard let batch = suggestionBatches[ref], !batch.isEmpty else { return }
        let prThreads = try await reviewThreads(ref, maxAge: nil)
        guard let repository = prThreads.headRepository else {
            throw .http(status: 422, message: "The pull request's head repository was deleted.")
        }
        var items: [SuggestionItem] = []
        for batched in batch {
            guard let thread = prThreads.thread(containing: batched.commentID),
                  let comment = thread.comments.first(where: { $0.id == batched.commentID }),
                  let item = Suggestions.item(for: comment, in: thread)
            else { throw .http(status: 409, message: "A batched suggestion no longer applies; remove it and try again.") }
            items.append(item)
        }

        let head = prThreads.headOID
        var changes: [(path: String, contents: Data)] = []
        for (path, onPath) in Dictionary(grouping: items, by: \.path).sorted(by: { $0.key < $1.key }) {
            let fetched = try await file(repo: ref.repo, commit: head, path: path)
            guard let data = fetched.data, let text = String(data: data, encoding: .utf8) else {
                throw .http(status: 422, message: "\(path) can't be read at the pull request's head.")
            }
            guard let applied = Suggestions.apply(onPath, to: text) else {
                throw .http(status: 422, message: "The suggestions on \(path) overlap or fall outside the file.")
            }
            changes.append((path, Data(applied.utf8)))
        }

        let title = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let newHead: String
        do throws(GitHubError) {
            newHead = try await service.commitFiles(
                repository: repository, branch: prThreads.headRefName, expectedHeadOID: head,
                headline: title.isEmpty ? Self.defaultCommitHeadline : title, body: nil, files: changes)
        } catch {
            throw Self.isStaleHead(error) ? .http(status: 409, message: Self.branchMovedMessage) : error
        }
        pushedHeads[ref] = (head, newHead)
        if let current = threads[ref], current.headOID == head { threads[ref] = current.with(headOID: newHead) }
        let committed = Set(batch.map(\.commentID))
        let remaining = (suggestionBatches[ref] ?? []).filter { !committed.contains($0.commentID) }
        suggestionBatches[ref] = remaining.isEmpty ? nil : remaining
        dropCaches(for: ref, head: head)
        for threadID in Set(items.map(\.threadID)) {
            try? await service.setThreadResolved(threadID, resolved: true)
        }
        _ = try? await reviewThreads(ref, maxAge: nil)
    }

    /// GitHub's createCommitOnBranch answer when `expectedHeadOid` isn't the branch head.
    static func isStaleHead(_ error: GitHubError) -> Bool {
        guard case .graphQL(let messages) = error else { return false }
        return messages.contains { $0.contains("Expected branch to point to") || $0.localizedCaseInsensitiveContains("expectedHeadOid") }
    }

    private func dropCaches(for ref: PullRequestRef, head: String) {
        files.removeAll { $0.repo == ref.repo && $0.commit == head }
        patches.removeAll { $0.repo == ref.repo && $0.head == head }
        documents.removeAll { $0.repo == ref.repo && $0.viewing.oid == head }
        changedFiles[ref] = nil
        changedFilesHead[ref] = nil
    }

    // MARK: Internals

    private func content(_ target: PreviewTarget, commit: PreviewCommit?, forceLarge: Bool) async throws(GitHubError)
        -> PreviewContent
    {
        let prThreads = try await reviewThreads(target.ref, maxAge: Self.threadsMaxAge)
        let viewing = commit ?? Self.automaticCommit(for: target, in: prThreads)
        let repo = target.ref.repo
        let path = target.path

        let fetched = try await file(repo: repo, commit: viewing.oid, path: path)
        let patch = try await patch(
            ref: target.ref, base: prThreads.baseOID, viewing: viewing, isPullRequestHead: viewing == .head(prThreads.headOID),
            path: path)
        return PreviewContent(
            target: target, viewing: viewing, file: Self.previewFile(fetched.data, path: path, forceLarge: forceLarge),
            patch: patch)
    }

    /// The focused thread's original commit when it is outdated, else head.
    static func automaticCommit(for target: PreviewTarget, in prThreads: PullRequestReviewThreads) -> PreviewCommit {
        if let commentID = target.commentID, let focused = prThreads.thread(containing: commentID), focused.isOutdated,
           let original = focused.originalCommitOID, original != prThreads.headOID
        {
            return .original(original)
        }
        return .head(prThreads.headOID)
    }

    static func previewFile(_ data: Data?, path: String, forceLarge: Bool) -> PreviewFile {
        guard let data else { return .missing }
        if PreviewSizePolicy.isBinary(data) { return .binary }
        if !forceLarge, PreviewSizePolicy.shouldCollapse(path: path, byteCount: data.count) {
            return .collapsed(bytes: data.count)
        }
        return .text(String(decoding: data, as: UTF8.self))
    }

    /// Cached threads younger than `maxAge`, else a fetch (joined when one is running). `maxAge` nil always starts a new
    /// fetch, and only the newest fetch's result is stored.
    private func reviewThreads(_ ref: PullRequestRef, maxAge: TimeInterval?) async throws(GitHubError)
        -> PullRequestReviewThreads
    {
        if let maxAge, let cached = threads[ref], now.now().timeIntervalSince(cached.fetchedAt) < maxAge { return cached }
        let fetch: (id: Int, task: Task<Result<PullRequestReviewThreads, GitHubError>, Never>)
        if maxAge != nil, let running = threadFetches[ref] {
            fetch = running
        } else {
            nextFetchID += 1
            let service = service
            fetch = (nextFetchID, Task {
                do throws(GitHubError) {
                    return .success(try await service.reviewThreads(ref))
                } catch {
                    return .failure(error)
                }
            })
            threadFetches[ref] = fetch
        }
        let result = await fetch.task.value
        let isNewest = threadFetches[ref]?.id == fetch.id
        if isNewest { threadFetches[ref] = nil }
        var fresh = try result.get()
        if let pushed = pushedHeads[ref] {
            if fresh.headOID == pushed.old {
                fresh = fresh.with(headOID: pushed.new)
            } else {
                pushedHeads[ref] = nil
            }
        }
        if isNewest { threads[ref] = fresh }
        return threads[ref] ?? fresh
    }

    private func file(repo: RepoRef, commit: String, path: String) async throws(GitHubError)
        -> FetchedFile
    {
        let key = FileKey(repo: repo, commit: commit, path: path)
        if let cached = files[key] { return cached }
        let service = service
        let fetched = try await fileFlights.run(key) { () async throws(GitHubError) -> FetchedFile in
            FetchedFile(data: try await service.fileContents(repo: repo, path: path, commit: commit))
        }
        files.insert(fetched, for: key)
        return fetched
    }

    /// `base...viewing`: the PR's file list at its head, else a GitHub compare.
    private func patch(
        ref: PullRequestRef, base: String, viewing: PreviewCommit, isPullRequestHead: Bool, path: String
    ) async throws(GitHubError) -> FilePatch {
        let head = viewing.oid
        let key = PatchKey(repo: ref.repo, base: base, head: head, path: path)
        if let cached = patches[key] { return cached }
        let service = service
        let patch = try await patchFlights.run(key) { () async throws(GitHubError) -> FilePatch in
            if isPullRequestHead { return try await service.pullRequestFilePatch(ref, path: path) }
            return try await service.filePatch(repo: ref.repo, base: base, head: head, path: path)
        }
        patches.insert(patch, for: key)
        return patch
    }

    private func updateThread(_ id: String, in ref: PullRequestRef, _ change: (inout ReviewThread) -> Void) {
        guard let index = threads[ref]?.threads.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[ref]!.threads[index])
    }

    static func describe(_ error: GitHubError) -> String {
        switch error {
        case .auth(let auth): auth.instructions
        case .rateLimited: "Rate limited by GitHub."
        case .http(let status, let message): message ?? "GitHub answered HTTP \(status)."
        case .graphQL(let messages): messages.first ?? "GitHub refused the request."
        case .decoding: "Unexpected response from GitHub."
        case .transport: "Couldn't reach GitHub."
        }
    }
}

// MARK: - Cache plumbing

private struct FileKey: Hashable, Sendable {
    let repo: RepoRef
    let commit: String
    let path: String
}

private struct PatchKey: Hashable, Sendable {
    let repo: RepoRef
    let base: String
    let head: String
    let path: String
}

/// The thread fields that decide anchoring; comment edits don't invalidate a document.
private struct AnchorSignature: Hashable, Sendable {
    let id: String
    let isOutdated: Bool
    let diffSide: DiffSide
    let line: Int?
    let startLine: Int?
    let originalLine: Int?
    let originalStartLine: Int?
    let originalCommitOID: String?

    init(_ thread: ReviewThread) {
        id = thread.id
        isOutdated = thread.isOutdated
        diffSide = thread.diffSide
        line = thread.line
        startLine = thread.startLine
        originalLine = thread.originalLine
        originalStartLine = thread.originalStartLine
        originalCommitOID = thread.originalCommitOID
    }
}

private struct DocumentKey: Hashable, Sendable {
    let repo: RepoRef
    let path: String
    let viewing: PreviewCommit
    let file: PreviewFile
    let patch: FilePatch
    let mode: PreviewMode
    let anchors: [AnchorSignature]
}

/// In-flight resolve/unresolve calls for one thread.
private struct ResolveMutation {
    /// Bumped per call; only the call holding the newest generation may roll back.
    var generation: Int
    /// Last state GitHub accepted (or the state before the first call); nil when the thread wasn't loaded.
    var confirmed: Bool?
    var confirmedGeneration: Int
}

private struct FetchedFile: Sendable {
    /// Nil when the file doesn't exist at the commit.
    let data: Data?
}

/// Insertion-ordered cache that drops its oldest entries past `capacity`.
private struct BoundedCache<Key: Hashable, Value> {
    let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) { self.capacity = capacity }

    subscript(key: Key) -> Value? { values[key] }

    mutating func insert(_ value: Value, for key: Key) {
        if values.updateValue(value, forKey: key) == nil { order.append(key) }
        while order.count > capacity { values[order.removeFirst()] = nil }
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in order where shouldRemove(key) { values[key] = nil }
        order.removeAll(where: shouldRemove)
    }
}

/// Joins concurrent requests for the same key onto one task.
@MainActor
private final class InFlight<Key: Hashable & Sendable, Value: Sendable, Failure: Error> {
    private var tasks: [Key: Task<Result<Value, Failure>, Never>] = [:]

    func run(_ key: Key, _ work: @escaping @Sendable () async throws(Failure) -> Value) async throws(Failure) -> Value {
        if let running = tasks[key] { return try await running.value.get() }
        let task = Task { () async -> Result<Value, Failure> in
            do throws(Failure) {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        tasks[key] = task
        let result = await task.value
        if tasks[key] == task { tasks[key] = nil }
        return try result.get()
    }
}
