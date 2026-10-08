import AppKit
import GitokenCore
import Observation

/// The pull request a window's file list belongs to (the target's, or the one whose files load before there is one).
struct PreviewPullRequest: Hashable {
    let threadID: ThreadID
    let ref: PullRequestRef
}

/// The open new-comment composer: where the comment attaches and which lines it covers.
struct NewCommentAnchor: Equatable {
    let position: CommentPosition
    let startLineIndex: Int
    /// The composer card goes under this line.
    let lineIndex: Int
}

/// In-window popovers under the toolbar.
enum PreviewPopover {
    case review, commit
}

/// UI state of one preview window: what it shows (target, mode, commit), which thread has focus, and the loaded
/// content/document, plus the review tools (file list, new comments, review submit, suggestion batch). The reusable
/// window retargets it as the inbox selection moves; pinned copies never do.
@MainActor
@Observable
final class PreviewModel {
    static let sidebarWidth: CGFloat = 230

    let notch: NotchModel
    let isPinned: Bool

    private(set) var target: PreviewTarget?
    /// Shown instead of content when there is no target ("No review comments…").
    private(set) var emptyMessage: String?
    private(set) var mode: PreviewMode = .diff
    private(set) var load: PreviewLoad = .loading
    /// Built for `mode`; nil while building or when the mode has nothing to show (binary, missing, no patch).
    private(set) var document: PreviewDocument?
    /// Bumped on every `document` assignment so the code view knows when to re-render.
    private(set) var documentVersion = 0
    private(set) var focusedThreadID: String?
    /// One-off notice above the content ("File not present at …", review results).
    private(set) var notice: String?
    /// Bumped whenever the focused thread should scroll into view.
    private(set) var scrollRequest = 0
    private(set) var replyingThreadID: String?
    /// Bumped to move keyboard focus into the open reply composer.
    private(set) var replyFocusToken = 0
    var drafts: [String: String] = [:]
    /// Per-thread action errors shown inside the card (reply / resolve / delete / batch failures).
    var cardErrors: [String: String] = [:]

    // File list
    private(set) var pullRequest: PreviewPullRequest?
    private(set) var showsSidebar = false
    private(set) var isLoadingFiles = false
    private(set) var filesError: String?

    // New comment
    private(set) var newComment: NewCommentAnchor?
    var newCommentText = ""
    private(set) var newCommentError: String?
    private(set) var isPostingComment = false
    /// Bumped to move keyboard focus into the new-comment composer.
    private(set) var newCommentFocusToken = 0
    /// The new-comment composer has keyboard focus (Esc cancels it, ⌘Return comments now).
    @ObservationIgnored var newCommentFocused = false

    // Review submit and suggestion commit
    var popover: PreviewPopover?
    var reviewSummary = ""
    var reviewEvent: ReviewEvent = .comment
    private(set) var isSubmittingReview = false
    private(set) var isDiscardingReview = false
    private(set) var reviewError: String?
    var commitHeadline = FilePreviewStore.defaultCommitHeadline
    private(set) var isCommitting = false
    private(set) var commitError: String?

    /// Explicit commit (outdated thread's original, or "Jump to head"); nil = automatic.
    private var requestedCommit: PreviewCommit?
    /// Mode the user picked with `d` / `f` or the toggle; sticks across retargets while available.
    private var preferredMode: PreviewMode?
    private var forceLarge = false
    /// Opens the first changed file once the file list arrives (Files button on a PR without review comments).
    private var opensFirstFile = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var documentTask: Task<Void, Never>?
    @ObservationIgnored private var filesTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Bumped when the window moves to another pull request; requests that finish later skip their UI updates.
    @ObservationIgnored private var pullRequestSession = 0
    /// Bumped whenever the new-comment composer opens or closes; identifies the composer a post belongs to.
    @ObservationIgnored private var composerSession = 0
    /// Thread placement the current document was built from; a change rebuilds it (new or deleted threads).
    @ObservationIgnored private var builtAnchors: [String]?

    @ObservationIgnored var onPin: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    /// The window's code view, for find-bar keys.
    @ObservationIgnored weak var codeTextView: CodeTextView?

    init(notch: NotchModel, pinned: Bool) {
        self.notch = notch
        isPinned = pinned
        observeThreads()
    }

    var previews: FilePreviewStore { notch.previews }

    // MARK: Derived

    var content: PreviewContent? {
        if case .loaded(let content) = load { return content }
        return nil
    }

    var reviewThreads: PullRequestReviewThreads? { (target?.ref ?? pullRequest?.ref).flatMap { previews.threads[$0] } }

    func thread(_ id: String) -> ReviewThread? { reviewThreads?.threads.first { $0.id == id } }

    var hasPatch: Bool { content?.patch.patch != nil }

    /// Anchored threads in document order (several threads may share a line).
    var anchoredThreadIDs: [String] {
        guard let document else { return [] }
        var seen: Set<String> = []
        return document.anchors.compactMap { seen.insert($0.threadID).inserted ? $0.threadID : nil }
    }

    var focusIndex: Int? { focusedThreadID.flatMap { anchoredThreadIDs.firstIndex(of: $0) } }

    var focusedAnchor: ThreadAnchor? {
        guard let focusedThreadID else { return nil }
        return document?.anchors.first { $0.threadID == focusedThreadID }
    }

    var unanchoredThreads: [ReviewThread] { (document?.unanchored ?? []).compactMap(thread) }

    /// Outdated threads that can be shown at their original commit.
    var outdatedUnanchored: [ReviewThread] {
        unanchoredThreads.filter { $0.isOutdated && $0.originalCommitOID != nil }
    }

    /// Current threads on the old side, which only the diff can place.
    var removedLineUnanchored: [ReviewThread] {
        guard mode == .file else { return [] }
        return unanchoredThreads.filter { !$0.isOutdated && $0.diffSide == .left }
    }

    /// Threads neither strip above covers (their line is not in this diff).
    var otherUnanchored: [ReviewThread] {
        let covered = Set(outdatedUnanchored.map(\.id) + removedLineUnanchored.map(\.id))
        return unanchoredThreads.filter { !covered.contains($0.id) }
    }

    /// Line number of the focused thread in the shown text (new side in diff mode when it has one).
    var focusedLineNumber: Int? {
        guard let anchor = focusedAnchor, let lines = document?.lines, lines.indices.contains(anchor.lineIndex) else {
            return nil
        }
        return lines[anchor.lineIndex].newNumber ?? lines[anchor.lineIndex].oldNumber
    }

    var isSidebarVisible: Bool { showsSidebar && !isPinned && pullRequest != nil }

    var changedFiles: [ChangedFile]? { pullRequest.flatMap { previews.changedFiles[$0.ref] } }

    var pendingCommentCount: Int { reviewThreads?.pendingCommentCount ?? 0 }

    var hasPendingReview: Bool { reviewThreads?.pendingReviewID != nil }

    var batchedSuggestions: [SuggestionItem] { (target?.ref).flatMap { previews.suggestionBatches[$0] } ?? [] }

    /// Unresolved (submitted) threads and pending comments on `path`, for the file list.
    func threadCounts(on path: String) -> (unresolved: Int, pending: Int) {
        guard let threads = reviewThreads?.threads(on: path) else { return (0, 0) }
        let unresolved = threads.filter { !$0.isResolved && !$0.isPending }.count
        let pending = threads.reduce(0) { $0 + $1.comments.filter(\.isPending).count }
        return (unresolved, pending)
    }

    /// New comments attach to the pull request's head, so only the head can be commented on.
    var canComment: Bool {
        guard let content, let head = reviewThreads?.headOID else { return false }
        return content.viewing == .head(head)
    }

    // MARK: Targeting

    func show(_ target: PreviewTarget?, emptyMessage: String? = nil) {
        // An explicit commit (Jump to head, an outdated thread's original) is dropped so reopening restores the default.
        if let target, target == self.target, requestedCommit == nil {
            if case .failed = load { reload() } else { focusTargetComment() }
            return
        }
        self.target = target
        self.emptyMessage = target == nil ? emptyMessage : nil
        opensFirstFile = false
        setPullRequest(target.map { PreviewPullRequest(threadID: $0.threadID, ref: $0.ref) }, sidebar: nil)
        requestedCommit = nil
        forceLarge = false
        focusedThreadID = nil
        replyingThreadID = nil
        cardErrors = [:]
        notice = nil
        reload()
    }

    /// The Files button: the file list on, at `preferred` (the newest review comment) or the first changed file. A
    /// window already showing this pull request keeps its file.
    func showFiles(threadID: ThreadID, ref: PullRequestRef, preferred: PreviewTarget?) {
        let pr = PreviewPullRequest(threadID: threadID, ref: ref)
        if let target, target.ref == ref, target.threadID == threadID {
            setPullRequest(pr, sidebar: true)
        } else if let preferred {
            show(preferred)
            setPullRequest(pr, sidebar: true)
        } else {
            show(nil)
            setPullRequest(pr, sidebar: true)
            opensFirstFile = true
            if let files = changedFiles { openFirstFile(of: files) }
        }
    }

    private func focusTargetComment() {
        guard let commentID = target?.commentID, let id = reviewThreads?.thread(containing: commentID)?.id else { return }
        focus(id)
    }

    /// Copies another window's view (the Pin button) and freezes its commit.
    func adopt(_ other: PreviewModel) {
        target = other.target
        emptyMessage = other.emptyMessage
        pullRequest = other.pullRequest
        requestedCommit = other.content?.viewing ?? other.requestedCommit
        preferredMode = other.mode
        mode = other.mode
        forceLarge = other.forceLarge
        focusedThreadID = other.focusedThreadID
        drafts = other.drafts
        reload()
    }

    func retry() { reload() }

    func loadAnyway() {
        forceLarge = true
        reload()
    }

    func jumpToHead() {
        guard let head = reviewThreads?.headOID else { return }
        requestedCommit = .head(head)
        notice = nil
        reload()
    }

    func viewOriginal(of thread: ReviewThread) {
        guard let oid = thread.originalCommitOID else { return }
        requestedCommit = .original(oid)
        focusedThreadID = thread.id
        notice = nil
        reload()
    }

    func setMode(_ next: PreviewMode) {
        preferredMode = next
        guard next != mode else { return }
        mode = next
        notice = nil
        cancelNewComment()
        rebuildDocument()
    }

    // MARK: Loading

    private func reload() {
        generation += 1
        let generation = generation
        loadTask?.cancel()
        documentTask?.cancel()
        cancelNewComment()
        setDocument(nil)
        builtAnchors = nil
        load = .loading
        guard let target else { return }
        let commit = requestedCommit
        let forceLarge = forceLarge
        loadTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.previews.load(target, commit: commit, forceLarge: forceLarge)
            guard !Task.isCancelled, generation == self.generation else { return }
            self.load = result
            guard case .loaded(let content) = result else { return }
            if self.focusedThreadID == nil, let commentID = target.commentID {
                self.focusedThreadID = self.reviewThreads?.thread(containing: commentID)?.id
            }
            self.mode = self.automaticMode(for: content)
            self.rebuildDocument()
        }
    }

    private func automaticMode(for content: PreviewContent) -> PreviewMode {
        let hasPatch = content.patch.patch != nil
        switch preferredMode ?? (hasPatch ? .diff : .file) {
        case .file:
            if case .missing = content.file, hasPatch {
                notice = "File not present at \(Self.short(content.viewing.oid)) · showing the diff"
                return .diff
            }
            return .file
        case .diff:
            return hasPatch ? .diff : .file
        }
    }

    private func rebuildDocument() {
        documentTask?.cancel()
        guard let content else {
            setDocument(nil)
            return
        }
        let mode = mode
        let needsDocument: Bool
        switch (mode, content.file) {
        case (_, .collapsed): needsDocument = false
        case (.diff, _): needsDocument = content.patch.patch != nil
        case (.file, .text): needsDocument = true
        case (.file, _): needsDocument = false
        }
        if document?.mode != mode { setDocument(nil) }
        builtAnchors = anchorSignature
        guard needsDocument else { return }
        let generation = generation
        documentTask = Task { [weak self] in
            guard let self else { return }
            let built = await self.previews.document(for: content, mode: mode)
            guard !Task.isCancelled, generation == self.generation, mode == self.mode else { return }
            self.setDocument(built)
            let anchored = self.anchoredThreadIDs
            if !(self.focusedThreadID.map(anchored.contains) ?? false) {
                self.focusedThreadID = anchored.first
            }
            self.scrollRequest += 1
        }
    }

    private func setDocument(_ next: PreviewDocument?) {
        if next == nil, document == nil { return }
        document = next
        documentVersion += 1
    }

    /// Placement-relevant fields of the threads on the shown path.
    private var anchorSignature: [String] {
        guard let target else { return [] }
        return (previews.threads[target.ref]?.threads(on: target.path) ?? []).map {
            "\($0.id) \($0.isOutdated) \($0.diffSide) \($0.line ?? 0) \($0.startLine ?? 0) \($0.originalLine ?? 0) \($0.originalStartLine ?? 0)"
        }
    }

    /// Rebuilds the document when threads on the shown path appear, disappear or move (comments added or deleted
    /// here, in another window, or by a refresh).
    private func observeThreads() {
        withObservationTracking {
            _ = anchorSignature
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.content != nil, let built = self.builtAnchors, built != self.anchorSignature { self.rebuildDocument() }
                self.observeThreads()
            }
        }
    }

    // MARK: File list

    /// `sidebar` nil picks the default for a new pull request: on for review requests.
    private func setPullRequest(_ next: PreviewPullRequest?, sidebar: Bool?) {
        if next != pullRequest {
            pullRequest = next
            pullRequestSession += 1
            filesTask?.cancel()
            isLoadingFiles = false
            filesError = nil
            popover = nil
            reviewSummary = ""
            reviewEvent = .comment
            reviewError = nil
            isSubmittingReview = false
            isDiscardingReview = false
            commitHeadline = FilePreviewStore.defaultCommitHeadline
            commitError = nil
            isCommitting = false
            showsSidebar = sidebar ?? next.map { notch.group($0.threadID)?.thread.reason == .reviewRequested } ?? false
        } else if let sidebar {
            showsSidebar = sidebar
        }
        if isSidebarVisible, changedFiles == nil { loadFiles() }
    }

    /// `b`.
    func toggleSidebar() {
        guard !isPinned, pullRequest != nil else { return }
        showsSidebar.toggle()
        if showsSidebar, changedFiles == nil { loadFiles() }
    }

    func loadFiles() {
        guard let pr = pullRequest, !isLoadingFiles else { return }
        isLoadingFiles = true
        filesError = nil
        filesTask = Task { [weak self] in
            guard let self else { return }
            do throws(GitHubError) {
                let files = try await self.previews.loadFiles(pr.ref)
                guard !Task.isCancelled, self.pullRequest == pr else { return }
                self.isLoadingFiles = false
                self.openFirstFile(of: files)
            } catch {
                guard !Task.isCancelled, self.pullRequest == pr else { return }
                self.isLoadingFiles = false
                self.filesError = error.briefDescription
            }
        }
    }

    private func openFirstFile(of files: [ChangedFile]) {
        guard opensFirstFile, target == nil else { return }
        opensFirstFile = false
        if let first = files.first {
            openFile(first.path)
        } else {
            emptyMessage = "No changed files in this pull request"
        }
    }

    /// Retargets this window to `path` in the listed pull request.
    func openFile(_ path: String) {
        guard let pr = pullRequest else { return }
        show(PreviewTarget(threadID: pr.threadID, ref: pr.ref, path: path, commentID: nil))
    }

    /// `n` / `p`: next / previous changed file, wrapping. False when there is no list to move in.
    @discardableResult
    func moveFile(_ delta: Int) -> Bool {
        guard !isPinned, pullRequest != nil else { return false }
        guard let files = changedFiles, !files.isEmpty else {
            if changedFiles == nil { loadFiles() }
            return false
        }
        let index = target.flatMap { target in files.firstIndex { $0.path == target.path } }
        let next = index.map { ($0 + delta + files.count) % files.count } ?? (delta > 0 ? 0 : files.count - 1)
        openFile(files[next].path)
        return true
    }

    // MARK: Threads

    func focus(_ id: String, scroll: Bool = true) {
        focusedThreadID = id
        if scroll { scrollRequest += 1 }
    }

    /// `j` / `k`: next / previous anchored thread, wrapping.
    func moveFocus(_ delta: Int) {
        let ids = anchoredThreadIDs
        guard !ids.isEmpty else { return }
        let next: Int
        if let index = focusIndex {
            next = (index + delta + ids.count) % ids.count
        } else {
            next = delta > 0 ? 0 : ids.count - 1
        }
        focus(ids[next])
    }

    /// `r`: opens the reply composer in the focused thread. Returns false when there is none to reply in.
    @discardableResult
    func startReply(in id: String? = nil) -> Bool {
        guard let id = id ?? focusedThreadID ?? anchoredThreadIDs.first,
              let thread = thread(id), thread.viewerCanReply, !thread.isPending else { return false }
        focusedThreadID = id
        replyingThreadID = id
        replyFocusToken += 1
        scrollRequest += 1
        return true
    }

    func cancelReply() {
        replyingThreadID = nil
    }

    func sendReply(in thread: ReviewThread) async {
        let body = (drafts[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let target else { return }
        let session = pullRequestSession
        cardErrors[thread.id] = nil
        do throws(GitHubError) {
            try await previews.reply(body, to: thread, target: target)
            drafts[thread.id] = nil
            if replyingThreadID == thread.id { replyingThreadID = nil }
        } catch {
            guard session == pullRequestSession else { return }
            cardErrors[thread.id] = "Couldn’t send: \(error.briefDescription). Your reply is kept."
        }
    }

    func setResolved(_ thread: ReviewThread, _ resolved: Bool) async {
        guard let target else { return }
        let session = pullRequestSession
        cardErrors[thread.id] = nil
        do throws(GitHubError) {
            try await previews.setResolved(thread.id, in: target.ref, resolved: resolved)
        } catch {
            guard session == pullRequestSession else { return }
            cardErrors[thread.id] = "Couldn’t \(resolved ? "resolve" : "unresolve"): \(error.briefDescription)"
        }
    }

    func deletePendingComment(_ comment: ReviewComment, in thread: ReviewThread) async {
        guard let target else { return }
        let session = pullRequestSession
        cardErrors[thread.id] = nil
        do throws(GitHubError) {
            try await previews.deletePendingComment(comment.id, in: target.ref)
        } catch {
            guard session == pullRequestSession else { return }
            cardErrors[thread.id] = "Couldn’t delete: \(error.briefDescription)"
        }
    }

    // MARK: New comments

    /// A gutter selection from line index `a` to `b`: opens the new-comment composer, or beeps when the lines can't
    /// take a comment.
    func selectLines(_ a: Int, _ b: Int) {
        guard let document, let content, let target else { return }
        guard canComment else {
            NSSound.beep()
            flash(content.viewing.isOriginal ? "Jump to head to comment on this file" : "Comments can only be added at the pull request’s head")
            return
        }
        guard let position = document.commentPosition(from: a, to: b, path: target.path, patch: content.patch.patch) else {
            NSSound.beep()
            flash("Only lines in the diff can be commented on")
            return
        }
        newComment = NewCommentAnchor(position: position, startLineIndex: min(a, b), lineIndex: max(a, b))
        composerSession += 1
        isPostingComment = false
        newCommentError = nil
        newCommentFocusToken += 1
    }

    func cancelNewComment() {
        if newComment != nil {
            composerSession += 1
            isPostingComment = false
        }
        newComment = nil
        newCommentError = nil
        newCommentFocused = false
    }

    /// Return: adds the comment to the viewer's pending review. `now` (⌘Return, only without a pending review) also
    /// submits it as a COMMENT review on its own.
    func postNewComment(now: Bool) async {
        guard let anchor = newComment, let target, !isPostingComment else { return }
        let raw = newCommentText
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if now, hasPendingReview {
            NSSound.beep()
            return
        }
        let ref = target.ref
        let composer = composerSession
        let session = pullRequestSession
        let before = Set(reviewThreads?.threads.map(\.id) ?? [])
        isPostingComment = true
        newCommentError = nil
        // Closing or reopening the composer resets the flag for the new one.
        defer { if composer == composerSession { isPostingComment = false } }
        do throws(GitHubError) {
            try await previews.addReviewComment(body, at: anchor.position, in: ref)
        } catch {
            if composer == composerSession { newCommentError = "Couldn’t add the comment: \(error.briefDescription)" }
            return
        }
        if composer == composerSession {
            newCommentText = ""
            cancelNewComment()
            if self.target == target,
               let added = reviewThreads?.threads.first(where: { !before.contains($0.id) && $0.path == target.path }) {
                focusedThreadID = added.id
            }
        } else if newCommentText == raw {
            // The composer moved on but still holds the posted text: don't offer it again.
            newCommentText = ""
        }
        guard now else { return }
        do throws(GitHubError) {
            try await previews.submitReview(.comment, body: "", in: ref)
            if session == pullRequestSession { flash("Comment posted") }
        } catch {
            if session == pullRequestSession {
                flash("Added to your pending review, but couldn’t post it: \(error.briefDescription)")
            }
        }
    }

    // MARK: Review

    func togglePopover(_ next: PreviewPopover) {
        popover = popover == next ? nil : next
        if next == .review, popover == .review, reviewThreads?.viewerIsAuthor == true { reviewEvent = .comment }
    }

    func submitReview() async {
        guard let ref = target?.ref ?? pullRequest?.ref, !isSubmittingReview else { return }
        let session = pullRequestSession
        let event = reviewEvent
        let body = reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmittingReview = true
        reviewError = nil
        defer { if session == pullRequestSession { isSubmittingReview = false } }
        do throws(GitHubError) {
            try await previews.submitReview(event, body: body, in: ref)
            guard session == pullRequestSession else { return }
            reviewSummary = ""
            reviewEvent = .comment
            if popover == .review { popover = nil }
            let result = switch event {
            case .approve: "Review submitted · Approved"
            case .requestChanges: "Review submitted · Changes requested"
            case .comment: "Review submitted"
            }
            flash(result)
        } catch {
            guard session == pullRequestSession else { return }
            reviewError = error.briefDescription
            flash("Couldn’t submit the review: \(error.briefDescription)")
        }
    }

    func discardPendingReview() async {
        guard let ref = target?.ref ?? pullRequest?.ref, !isDiscardingReview else { return }
        let session = pullRequestSession
        let count = pendingCommentCount
        isDiscardingReview = true
        reviewError = nil
        defer { if session == pullRequestSession { isDiscardingReview = false } }
        do throws(GitHubError) {
            try await previews.discardPendingReview(in: ref)
            guard session == pullRequestSession else { return }
            if popover == .review { popover = nil }
            flash(count > 0 ? "Pending review discarded (\(Format.plural(count, "comment")))" : "Pending review discarded")
        } catch {
            guard session == pullRequestSession else { return }
            reviewError = error.briefDescription
            flash("Couldn’t discard the pending review: \(error.briefDescription)")
        }
    }

    // MARK: Suggestions

    func isBatched(_ commentID: String) -> Bool { batchedSuggestions.contains { $0.commentID == commentID } }

    func toggleBatch(_ item: SuggestionItem, in thread: ReviewThread) {
        guard let ref = target?.ref else { return }
        cardErrors[thread.id] = nil
        if isBatched(item.commentID) {
            previews.removeFromBatch(item.commentID, in: ref)
            return
        }
        do throws(GitHubError) {
            try previews.addToBatch(item, in: ref)
        } catch {
            cardErrors[thread.id] = "Couldn’t add to the batch: \(error.briefDescription)"
        }
    }

    /// Commits the batch as one commit on the head branch, then shows the file at the new head.
    func commitSuggestions() async {
        guard let target, !isCommitting else { return }
        let count = batchedSuggestions.count
        guard count > 0 else { return }
        let session = pullRequestSession
        let trimmed = commitHeadline.trimmingCharacters(in: .whitespacesAndNewlines)
        isCommitting = true
        commitError = nil
        defer { if session == pullRequestSession { isCommitting = false } }
        do throws(GitHubError) {
            try await previews.commitBatch(in: target.ref, headline: trimmed.isEmpty ? FilePreviewStore.defaultCommitHeadline : trimmed)
        } catch {
            if session == pullRequestSession { commitError = error.briefDescription }
            return
        }
        guard session == pullRequestSession else { return }
        commitHeadline = FilePreviewStore.defaultCommitHeadline
        if popover == .commit { popover = nil }
        // At the new head even when the focused comment is now outdated.
        requestedCommit = previews.threads[target.ref].map { .head($0.headOID) }
        reload()
        flash("Committed \(Format.plural(count, "suggestion"))")
    }

    // MARK: Actions

    /// File mode: the blob at the viewed commit and focused line. Diff mode: the focused comment.
    var gitHubURL: URL? {
        guard let target else { return nil }
        if mode == .file, let content {
            let path = target.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target.path
            let fragment = focusedLineNumber.map { "#L\($0)" } ?? ""
            return URL(string: "https://github.com/\(target.ref.repo.fullName)/blob/\(content.viewing.oid)/\(path)\(fragment)")
        }
        if let focusedThread = focusedThreadID.flatMap(thread) {
            let focused = target.commentID.flatMap { id in focusedThread.comments.first { $0.id == id } }
            if let url = (focused ?? focusedThread.root)?.url { return url }
        }
        return URL(string: "\(target.ref.htmlURL.absoluteString)/files")
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    /// A notice that clears itself after a few seconds.
    private func flash(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.notice == message else { return }
            self.notice = nil
        }
    }

    static func short(_ oid: String) -> String { String(oid.prefix(7)) }
}
