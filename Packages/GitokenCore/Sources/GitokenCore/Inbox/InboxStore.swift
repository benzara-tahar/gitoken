import Foundation
import Observation
import os

/// The app's single source of truth. UI reads its properties and calls its intents; nothing else mutates state.
///
/// CONTRACT (implemented by the store slice): public signatures here are shared with the UI slice.
@MainActor
@Observable
public final class InboxStore {
    // MARK: Lifecycle

    /// Production wiring: `GitHubClient(tokens: GHCLITokenProvider())`, database in
    /// `~/Library/Application Support/Gitoken/gitoken.sqlite`, `SystemNow` (or the given clock).
    public static func live(now: any NowProvider = SystemNow()) throws -> InboxStore {
        let tokens = GHCLITokenProvider()
        return InboxStore(
            service: GitHubClient(tokens: tokens, now: now), database: try .onDisk(), now: now, tokens: tokens)
    }

    /// Fixture wiring for SwiftUI previews and `--fixtures` debug launches: `FixtureGitHubService`, in-memory database.
    public static func preview(now: any NowProvider = SystemNow()) -> InboxStore {
        let fixtures = FixtureGitHubService(now: now)
        let database: GitokenDatabase
        do {
            database = try .inMemory()
        } catch {
            preconditionFailure("In-memory database failed to open: \(error)")
        }
        let store = InboxStore(service: fixtures, database: database, now: now)
        store.fixtureService = fixtures
        return store
    }

    /// Non-nil only for `preview()` stores: the debug menu drives scripted arrivals through it, then calls `refresh()`.
    public private(set) var fixtureService: FixtureGitHubService?
    /// Set by `makeFilePreviewStore()`.
    public internal(set) var filePreviewStore: FilePreviewStore?

    public let now: any NowProvider
    public let customSections: CustomSectionStore


    /// Starts the poll loop: poll immediately, then sleep max(X-Poll-Interval, 60s) with tolerance.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        isPaused = false
        tick()
        startPolling(after: .zero)
        ticker.start(after: Self.tickInterval) { [weak self] in
            guard let self else { return nil }
            self.tick()
            return Self.tickInterval
        }
    }

    /// Pauses polling (system sleep / screen lock). Idempotent.
    public func pause() {
        isAway = true
        guard isStarted, !isPaused else { return }
        isPaused = true
        pollLoop.stop()
    }

    /// Resumes polling and polls immediately (wake / unlock); publishes a morning summary held back while away.
    /// Idempotent.
    public func resume() {
        isAway = false
        guard isStarted, isPaused else {
            syncQuietState()
            return
        }
        isPaused = false
        tick()
        startPolling(after: .zero)
    }

    /// Manual refresh / Retry from the blocked state (re-runs `gh auth token`).
    public func refresh() async {
        await tokens?.invalidate()
        needsViewerCheck = true
        let next = await pollCycle(fresh: true)
        tick()
        guard isStarted, !isPaused else { return }
        if let next { startPolling(after: next) } else { pollLoop.stop() }
    }

    /// Re-evaluates time-based state (snooze expiry, quiet end → summary arrival). Called by the store's own
    /// minute timer and after the debug clock advances.
    public func tick() {
        let current = now.now()
        if let until = globalSnoozeUntil, until <= current {
            globalSnoozeUntil = nil
            saveAppState()
        }
        syncQuietState()

        let expired = rows.values
            .filter { $0.doneAt == nil && $0.snoozedUntil.map { $0 <= current } == true }
            .sorted { ($0.snoozedUntil!, $0.id.rawValue) < ($1.snoozedUntil!, $1.id.rawValue) }
        guard !expired.isEmpty else { return }
        var changed: [TrackedThread] = []
        for var row in expired {
            row.snoozedUntil = nil
            row.resurfaced = .snoozeEnded
            changed.append(row)
            if currentQuietReason == nil, settings.presents(row.thread) {
                arrivals.enqueue(Arrival(kind: .snoozeEnded(groupID: row.id), updateCount: 1, actors: row.actors))
            }
        }
        store(changed)
        publishArrival()
    }

    // MARK: State

    public private(set) var phase: StorePhase = .starting
    public private(set) var lastSyncAt: Date?
    public private(set) var lastSyncError: GitHubError?

    /// All tracked groups allowed by notification types and mute rules, newest activity first.
    public private(set) var groups: [InboxGroup] = []
    public func groups(in bucket: InboxBucket) -> [InboxGroup] {
        let current = now.now()
        return groups.filter { $0.bucket(at: current) == bucket }
    }
    /// Notch badge: number of groups in `.new`.
    public var unseenCount: Int { groups(in: .new).count }
    public var pendingCount: Int { groups(in: .pending).count }

    public private(set) var settings: AppSettings = .init()
    public func updateSettings(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let reanalyze = next.notifyAIReviews != settings.notifyAIReviews
        let filtersChanged = next.muteRules != settings.muteRules
            || next.enabledNotificationReasons != settings.enabledNotificationReasons
        settings = next
        if filtersChanged { applyPresentationFilters() }
        customSections.configure(sections: next.customSections)
        saveAppState()
        syncQuietState()
        if reanalyze { reabsorbCachedDetails() }
    }

    /// Hides matching groups from the inbox, counts, arrivals, and sounds. Their activity keeps being tracked, so
    /// `unmute` brings them back as they are on GitHub.
    public func mute(_ rule: MuteRule) {
        updateSettings { if !$0.muteRules.contains(rule) { $0.muteRules.append(rule) } }
    }

    public func unmute(_ rule: MuteRule) {
        updateSettings { $0.muteRules.removeAll { $0 == rule } }
    }

    private func applyPresentationFilters() {
        let excluded = Set(rows.values.filter { !settings.presents($0.thread) }.map(\.id))
        arrivals.remove(excluded)
        collected.remove(excluded)
        rebuildGroups()
        publishArrival()
    }

    /// Re-derives previews/participants/unseen counts from cached timelines after the AI-review policy changed.
    private func reabsorbCachedDetails() {
        guard let account, let viewer else { return }
        var changed: [TrackedThread] = []
        for (id, var row) in rows where !row.needsHydration {
            guard let detail = conversations[id]?.detail ?? cachedDetail(id, account: account) else { continue }
            row.absorb(detail, viewer: viewer, includeAI: settings.notifyAIReviews)
            changed.append(row)
        }
        store(changed)
    }

    public private(set) var manualQuiet: Bool = false
    public private(set) var globalSnoozeUntil: Date?
    /// Non-nil while arrival animations are suppressed. Activity still collects.
    public var quietReason: QuietReason? { currentQuietReason }

    /// Current announcement. Same-group activity merges into it (same `id`). Nil when idle or quiet.
    public private(set) var arrival: Arrival?
    /// UI calls this when the arrival's display time elapses or the user dismisses it; the next queued one shows.
    public func dismissArrival() {
        arrivals.dismiss()
        publishArrival()
    }

    public private(set) var conversations: [ThreadID: ConversationState] = [:]

    /// Open conversation detail, else the cached one. Never hits the network.
    public func detail(for id: ThreadID) -> ThreadDetail? {
        conversations[id]?.detail ?? account.flatMap { cachedDetail(id, account: $0) }
    }

    // MARK: Intents

    /// Captures the visit boundary, marks the group seen (locally + GitHub read), and hydrates the timeline.
    public func openConversation(_ id: ThreadID) async {
        guard var row = rows[id], let account, let viewer else { return }
        conversations[id] = ConversationState(
            detail: conversations[id]?.detail ?? cachedDetail(id, account: account), lastVisitAt: row.lastVisitAt,
            isLoading: true)
        let needsRemoteRead = row.thread.unread
        row.markSeen(through: row.thread.updatedAt)
        row.resurfaced = nil
        store([row])
        arrivals.remove(groupID: id)
        publishArrival()

        let service = service
        let thread = row.thread
        async let readError = Self.markRead(id, needed: needsRemoteRead, service: service)
        let result = await Self.fetchDetail(thread, service: service)
        if let error = await readError { lastSyncError = error }

        switch result {
        case .success(let detail):
            conversations[id]?.detail = detail
            conversations[id]?.error = nil
            saveDetail(detail, account: account)
            guard var row = rows[id], self.viewer == viewer else { break }
            if let newest = detail.items.last?.createdAt { row.markSeen(through: newest) }
            if row.thread.updatedAt == thread.updatedAt { row.absorb(detail, viewer: viewer, includeAI: settings.notifyAIReviews) }
            store([row])
        case .failure(let error):
            conversations[id]?.error = error
        }
        conversations[id]?.isLoading = false
    }

    /// Records `lastVisitAt = now` for the group.
    public func closeConversation(_ id: ThreadID) {
        guard var row = rows[id] else { return }
        row.lastVisitAt = now.now()
        row.unseenCount = 0
        store([row])
    }

    /// Local + GitHub done. New activity later returns the group to the inbox with `.reopenedFromDone`.
    public func markDone(_ id: ThreadID) {
        guard var row = rows[id], row.doneAt == nil else { return }
        row.doneAt = now.now()
        row.snoozedUntil = nil
        row.resurfaced = nil
        row.keptLocally = false
        store([row])
        arrivals.remove(groupID: id)
        publishArrival()
        sync { (service: any GitHubService) async throws(GitHubError) in try await service.markDone(id) }
    }

    /// Local undo (GitHub re-surfaces the thread on its next activity).
    public func undoDone(_ id: ThreadID) {
        guard var row = rows[id], row.doneAt != nil else { return }
        row.doneAt = nil
        row.keptLocally = true
        store([row])
    }

    public func snooze(_ id: ThreadID, _ option: SnoozeOption) {
        guard var row = rows[id], row.doneAt == nil else { return }
        row.snoozedUntil = option.deadline(from: now.now(), calendar: calendar)
        row.resurfaced = nil
        store([row])
        arrivals.remove(groupID: id)
        publishArrival()
    }

    public func unsnooze(_ id: ThreadID) {
        guard var row = rows[id], row.snoozedUntil != nil else { return }
        row.snoozedUntil = nil
        store([row])
    }

    public func snoozeAll(_ option: SnoozeOption) {
        globalSnoozeUntil = option.deadline(from: now.now(), calendar: calendar)
        saveAppState()
        syncQuietState()
    }

    public func endGlobalSnooze() {
        guard globalSnoozeUntil != nil else { return }
        globalSnoozeUntil = nil
        saveAppState()
        syncQuietState()
    }

    public func setManualQuiet(_ on: Bool) {
        guard manualQuiet != on else { return }
        manualQuiet = on
        saveAppState()
        syncQuietState()
    }

    /// Posts to GitHub and appends the result to the open conversation. `inReplyTo` threads under a review comment.
    public func reply(to id: ThreadID, body: String, inReplyTo: ReviewComment?) async throws(GitHubError) {
        guard let thread = rows[id]?.thread, let number = thread.number, let account else {
            throw .http(status: 422, message: "This notification has no conversation to reply to.")
        }
        let edit: (ThreadDetail) -> ThreadDetail
        let postedAt: Date
        if let parent = inReplyTo {
            let comment = try await service.replyToReviewComment(
                repo: thread.repo, number: number, commentDatabaseID: parent.databaseID, body: body)
            edit = { $0.inserting(comment, replyingTo: parent) }
            postedAt = comment.createdAt
        } else {
            let item = try await service.postComment(repo: thread.repo, number: number, body: body)
            edit = { $0.appending(item) }
            postedAt = item.createdAt
        }
        if var row = rows[id] {
            row.markSeen(through: postedAt)
            store([row])
        }
        guard let base = conversations[id]?.detail ?? cachedDetail(id, account: account) else { return }
        let updated = edit(base)
        if conversations[id] != nil { conversations[id]?.detail = updated }
        saveDetail(updated, account: account)
    }

    /// Adds the viewer's reaction to the description, a comment, a review, or a review comment (`subjectID` is its node
    /// id, see `TimelineItem.reactionSubjectID`). The conversation shows it immediately; a refusal rolls it back.
    public func addReaction(_ content: ReactionContent, to subjectID: String, in id: ThreadID) async throws(GitHubError) {
        let account = account
        let before = conversations[id]?.detail ?? account.flatMap { cachedDetail(id, account: $0) }
        let optimistic = before.flatMap { detail in
            detail.items.addingReaction(content, to: subjectID).map { detail.replacingItems($0) }
        }
        if let optimistic { show(optimistic, for: id, account: account) }
        do throws(GitHubError) {
            try await service.addReaction(content, subjectID: subjectID)
        } catch {
            if let before, let optimistic, conversations[id]?.detail ?? optimistic == optimistic {
                show(before, for: id, account: account)
            }
            throw error
        }
    }

    private func show(_ detail: ThreadDetail, for id: ThreadID, account: AccountKey?) {
        if conversations[id] != nil { conversations[id]?.detail = detail }
        if let account { saveDetail(detail, account: account) }
    }

    // MARK: Wiring

    static let minimumPollInterval: TimeInterval = 60
    static let tickInterval: Duration = .seconds(60)
    static let maxConcurrentHydrations = 4
    /// Unchanged-but-never-hydrated rows (first sync, earlier failures) hydrated per poll, newest unseen first.
    static let backfillPerPoll = 20
    /// Done rows GitHub no longer lists are forgotten after this long.
    static let doneRetention: TimeInterval = 30 * 24 * 60 * 60

    private static let log = Logger(subsystem: "io.github.benzara-tahar.Gitoken", category: "InboxStore")

    let service: any GitHubService
    private let tokens: (any TokenProvider)?
    let database: GitokenDatabase
    let calendar: Calendar

    @ObservationIgnored private var rows: [ThreadID: TrackedThread] = [:]
    @ObservationIgnored private var viewer: Actor?
    @ObservationIgnored private var lastModified: String?
    @ObservationIgnored private var collected = CollectedActivity()
    @ObservationIgnored private var collectedReason: QuietReason?
    @ObservationIgnored private var arrivals = ArrivalQueue()
    private var currentQuietReason: QuietReason?

    @ObservationIgnored private(set) var pollInterval: TimeInterval = InboxStore.minimumPollInterval
    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private var needsViewerCheck = true
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isPaused = false
    /// Mac asleep or locked (`pause()` until `resume()`), whether or not polling has started.
    @ObservationIgnored private var isAway = false
    private let pollLoop = RepeatingTask()
    private let ticker = RepeatingTask()
    @ObservationIgnored private var inFlightPoll: Task<Void, Never>?
    @ObservationIgnored private var syncTasks: [UUID: Task<Void, Never>] = [:]

    init(
        service: any GitHubService, database: GitokenDatabase, now: any NowProvider, tokens: (any TokenProvider)? = nil,
        calendar: Calendar = .current
    ) {
        self.service = service
        self.database = database
        self.now = now
        self.tokens = tokens
        self.calendar = calendar
        customSections = CustomSectionStore(service: service as? any GitHubSearchService, database: database, now: now)

        let saved: PersistedAppState
        do {
            saved = try database.appState() ?? PersistedAppState()
        } catch {
            Self.log.error("Loading app state failed: \(String(describing: error), privacy: .public)")
            saved = PersistedAppState()
        }
        settings = saved.settings
        customSections.configure(sections: saved.settings.customSections)
        manualQuiet = saved.manualQuiet
        globalSnoozeUntil = saved.globalSnoozeUntil
        lastModified = saved.lastModified
        collected = saved.collected
        collectedReason = saved.collectedReason
        if let viewer = saved.viewer {
            self.viewer = viewer
            phase = .ready(viewer: viewer)
            rows = loadRows(for: AccountKey(login: viewer.login))
            customSections.setAccount(AccountKey(login: viewer.login))
        }
        applyPresentationFilters()
        syncQuietState(live: false)
    }

    private var account: AccountKey? { viewer.map { AccountKey(login: $0.login) } }

    /// Waits for fire-and-forget GitHub writes (`markDone`) to finish.
    func waitForPendingSync() async {
        while let task = syncTasks.values.first { await task.value }
    }

    // MARK: Polling

    private func startPolling(after delay: Duration) {
        pollLoop.start(after: delay) { [weak self] in await self?.pollCycle(fresh: false) }
    }

    /// Polls, then returns the delay until the next poll, or nil when blocked on auth.
    private func pollCycle(fresh: Bool) async -> Duration? {
        await pollNow(fresh: fresh)
        if case .blocked = phase { return nil }
        var seconds = max(pollInterval, Self.minimumPollInterval)
        if let retryAfter { seconds = max(seconds, retryAfter.timeIntervalSince(now.now())) }
        return .seconds(seconds)
    }

    /// Polls are serialized. A non-fresh caller joins the poll in flight; a fresh one waits for it and then
    /// polls again, unless another poll started meanwhile (which already began after the request).
    private func pollNow(fresh: Bool) async {
        if let inFlight = inFlightPoll {
            await inFlight.value
            guard fresh else { return }
        }
        if let inFlight = inFlightPoll {
            await inFlight.value
            return
        }
        let task = Task {
            await self.performPoll()
            self.inFlightPoll = nil
        }
        inFlightPoll = task
        await task.value
    }

    private func performPoll() async {
        guard let viewer = await verifiedViewer() else { return }
        let account = AccountKey(login: viewer.login)

        let result: NotificationPoll
        do throws(GitHubError) {
            result = try await service.pollNotifications(lastModified: lastModified)
        } catch {
            recordSyncFailure(error)
            return
        }
        guard self.viewer == viewer else { return }
        retryAfter = nil
        syncQuietState()

        var changes: [ThreadChange] = []
        switch result {
        case .notModified(let interval):
            pollInterval = interval
        case .updated(let threads, let newLastModified, let interval):
            pollInterval = interval
            let initialSync = rows.isEmpty && lastModified == nil
            changes = applyListing(threads, account: account, initialSync: initialSync)
            lastModified = newLastModified
            saveAppState()
        }

        let details = await hydrate(changes, account: account, viewer: viewer)
        guard self.viewer == viewer else { return }
        announce(changes, details: details, viewer: viewer)
        lastSyncAt = now.now()
        lastSyncError = nil
    }

    private func verifiedViewer() async -> Actor? {
        if !needsViewerCheck, let viewer { return viewer }
        do throws(GitHubError) {
            let fetched = try await service.viewer()
            adopt(viewer: fetched)
            needsViewerCheck = false
            return fetched
        } catch {
            recordSyncFailure(error)
            return nil
        }
    }

    private func adopt(viewer fetched: Actor) {
        let previous = viewer
        viewer = fetched
        phase = .ready(viewer: fetched)
        customSections.setAccount(AccountKey(login: fetched.login))
        if previous?.login.caseInsensitiveCompare(fetched.login) != .orderedSame {
            // First run or the gh account changed: everything below is per-account.
            if previous != nil {
                lastModified = nil
                collected = CollectedActivity()
                collectedReason = nil
                arrivals = ArrivalQueue()
                conversations = [:]
                publishArrival()
            }
            rows = loadRows(for: AccountKey(login: fetched.login))
            rebuildGroups()
        }
        saveAppState()
    }

    private func recordSyncFailure(_ error: GitHubError) {
        switch error {
        case .auth(let auth): phase = .blocked(auth)
        case .rateLimited(let resetAt): retryAfter = resetAt
        case .http, .graphQL, .decoding, .transport: break
        }
        lastSyncError = error
    }

    // MARK: Poll diff

    private struct ThreadChange {
        let id: ThreadID
        /// Stored `updatedAt` before this poll; nil for a thread seen for the first time.
        let previousUpdatedAt: Date?
        let reopened: Bool
        /// False during the very first sync, which only builds the inbox.
        let announce: Bool
    }

    /// Merges a full `all=true` listing into the rows and returns threads with new activity.
    private func applyListing(_ threads: [NotificationThread], account: AccountKey, initialSync: Bool) -> [ThreadChange] {
        let current = now.now()
        var changes: [ThreadChange] = []
        var changed: [TrackedThread] = []
        var listed = Set<ThreadID>()

        for thread in threads {
            listed.insert(thread.id)
            guard var row = rows[thread.id] else {
                // Known threads stay tracked whatever their latest reason; only new ones must be in scope.
                guard thread.reason.isInInboxScope else { continue }
                changed.append(TrackedThread(thread: thread))
                changes.append(ThreadChange(id: thread.id, previousUpdatedAt: nil, reopened: false, announce: !initialSync))
                continue
            }
            guard row.thread != thread || row.keptLocally else { continue }
            let previous = row.thread.updatedAt
            row.thread = thread
            row.keptLocally = false
            if thread.updatedAt > previous {
                let reopened = row.doneAt != nil
                if reopened {
                    row.doneAt = nil
                    row.resurfaced = .reopenedFromDone
                }
                changes.append(ThreadChange(id: thread.id, previousUpdatedAt: previous, reopened: reopened, announce: !initialSync))
            }
            changed.append(row)
        }

        var forgotten: [ThreadID] = []
        for (id, var row) in rows where !listed.contains(id) {
            if row.doneAt == nil, !row.keptLocally {
                // GitHub only omits threads from an all=true listing once they are done: marked done elsewhere.
                row.doneAt = current
                row.snoozedUntil = nil
                row.resurfaced = nil
                changed.append(row)
                arrivals.remove(groupID: id)
            } else if let doneAt = row.doneAt, current.timeIntervalSince(doneAt) > Self.doneRetention {
                forgotten.append(id)
            }
        }

        store(changed, rebuild: false)
        if !forgotten.isEmpty {
            for id in forgotten {
                rows[id] = nil
                conversations[id] = nil
            }
            do {
                try database.deleteThreads(forgotten, for: account)
            } catch {
                Self.log.error("Deleting threads failed: \(String(describing: error), privacy: .public)")
            }
        }
        applyPresentationFilters()
        return changes
    }

    /// Hydrates every announceable change plus a bounded backfill of rows never hydrated, then folds the timelines
    /// into the rows. Returns the details fetched this round.
    private func hydrate(_ changes: [ThreadChange], account: AccountKey, viewer: Actor) async -> [ThreadID: ThreadDetail] {
        let policy = settings
        let urgentIDs = changes.filter(\.announce).map(\.id)
        let urgent = urgentIDs.compactMap { rows[$0] }.filter { $0.needsHydration && policy.presents($0.thread) }
        let urgentSet = Set(urgentIDs)
        // Excluded rows stay tracked; the next poll's backfill catches them up after re-enabling.
        let backfill = rows.values
            .filter { !urgentSet.contains($0.id) && $0.doneAt == nil && $0.needsHydration && policy.presents($0.thread) }
            .sorted { a, b in
                a.isUnseen != b.isUnseen ? a.isUnseen : a.thread.updatedAt > b.thread.updatedAt
            }
            .prefix(Self.backfillPerPoll)
        let targets = (urgent + backfill).map(\.thread)
        guard !targets.isEmpty else { return [:] }

        let results = await Self.fetchDetails(targets, service: service, maxConcurrent: Self.maxConcurrentHydrations)

        var details: [ThreadID: ThreadDetail] = [:]
        var changed: [TrackedThread] = []
        for thread in targets {
            guard var row = rows[thread.id], row.thread.updatedAt == thread.updatedAt, let result = results[thread.id] else {
                continue
            }
            switch result {
            case .success(let detail):
                row.absorb(detail, viewer: viewer, includeAI: settings.notifyAIReviews)
                details[thread.id] = detail
                if conversations[thread.id] != nil { conversations[thread.id]?.detail = detail }
                saveDetail(detail, account: account)
            case .failure:
                row.absorbHydrationFailure()
            }
            changed.append(row)
        }
        store(changed)
        return details
    }

    private func announce(_ changes: [ThreadChange], details: [ThreadID: ThreadDetail], viewer: Actor) {
        let current = now.now()
        var collectedChanged = false
        for change in changes where change.announce {
            guard let row = rows[change.id], row.doneAt == nil, row.isUnseen, !row.isSnoozed(at: current),
                  settings.presents(row.thread) else { continue }
            let includeAI = settings.notifyAIReviews
            let fresh = details[change.id].map {
                ActivityAnalysis.items(in: $0, byOthersThan: viewer, after: change.previousUpdatedAt, includeAI: includeAI)
            } ?? []
            // AI-only activity stays in the inbox (GitHub still lists it unread) but is not announced.
            if !includeAI, fresh.isEmpty, let detail = details[change.id],
               !ActivityAnalysis.items(in: detail, byOthersThan: viewer, after: change.previousUpdatedAt).isEmpty
            {
                continue
            }
            let count = change.previousUpdatedAt == nil ? 1 : max(1, fresh.count)
            // Bots (CI) only show when no human took part in the new activity.
            let humans = fresh.map(\.actor).filter { !$0.isBot }
            var actors = [Actor]().merging(humans.isEmpty ? fresh.map(\.actor) : humans)
            if actors.isEmpty, let actor = row.preview?.actor, !ActivityAnalysis.isViewer(actor, viewer) { actors = [actor] }
            if let reason = currentQuietReason {
                collected.add(groupID: change.id, count: count, actors: actors)
                collectedReason = reason
                collectedChanged = true
            } else {
                arrivals.announce(
                    groupID: change.id, latest: row.preview ?? .generic(at: row.thread.updatedAt), reopened: change.reopened,
                    count: count, actors: actors)
            }
        }
        if collectedChanged { saveAppState() }
        publishArrival()
    }

    private nonisolated static func fetchDetail(
        _ thread: NotificationThread, service: any GitHubService
    ) async -> Result<ThreadDetail, GitHubError> {
        guard thread.kind.hasTimeline else {
            return .failure(.http(status: 404, message: "\(thread.kind.rawValue) has no conversation timeline"))
        }
        do throws(GitHubError) {
            return .success(try await service.threadDetail(for: thread))
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func fetchDetails(
        _ threads: [NotificationThread], service: any GitHubService, maxConcurrent: Int
    ) async -> [ThreadID: Result<ThreadDetail, GitHubError>] {
        await withTaskGroup(of: (ThreadID, Result<ThreadDetail, GitHubError>).self) { group in
            var pending = threads.makeIterator()
            for _ in 0..<maxConcurrent {
                guard let thread = pending.next() else { break }
                group.addTask { (thread.id, await fetchDetail(thread, service: service)) }
            }
            var results: [ThreadID: Result<ThreadDetail, GitHubError>] = [:]
            while let (id, result) = await group.next() {
                results[id] = result
                if let thread = pending.next() {
                    group.addTask { (thread.id, await fetchDetail(thread, service: service)) }
                }
            }
            return results
        }
    }

    private nonisolated static func markRead(_ id: ThreadID, needed: Bool, service: any GitHubService) async -> GitHubError? {
        guard needed else { return nil }
        do throws(GitHubError) {
            try await service.markRead(id)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Arrivals & quiet

    /// Tracks quiet transitions. Entering quiet folds waiting arrivals into the collected summary and hides the
    /// current one; leaving quiet publishes the summary if anything was collected (also after a relaunch).
    /// When scheduled quiet hours end, a morning summary waits until the Mac is in use rather than publishing
    /// during initialization or while asleep/locked.
    private func syncQuietState(live: Bool = true) {
        let reason = QuietPolicy.reason(
            now: now.now(), globalSnoozeUntil: globalSnoozeUntil, manualQuiet: manualQuiet,
            quietHours: settings.quietHours, calendar: calendar)
        let wasQuiet = currentQuietReason != nil
        if currentQuietReason != reason { currentQuietReason = reason }
        var collectedChanged = false

        if let reason {
            if !wasQuiet {
                for waiting in arrivals.clear() { collected.add(waiting) }
                collectedChanged = true
            }
            if collectedReason != reason {
                collectedReason = reason
                collectedChanged = true
            }
        } else if let endedReason = collectedReason {
            let morning = if case .quietHours = endedReason { true } else { false }
            if !morning || (live && !isAway) {
                if morning {
                    publishMorningSummary()
                } else if !collected.isEmpty {
                    arrivals.enqueue(collected.summary(endedReason: endedReason), collected: collected)
                }
                collected = CollectedActivity()
                collectedReason = nil
                collectedChanged = true
            }
        }

        if collectedChanged { saveAppState() }
        publishArrival()
    }

    private func publishMorningSummary() {
        let repos = Dictionary(uniqueKeysWithValues: collected.groupIDs.compactMap { id -> (ThreadID, RepoRef)? in
            guard let row = rows[id], settings.presents(row.thread) else { return nil }
            return (id, row.thread.repo)
        })
        let summary = collected.morningSummary(repo: { repos[$0] })
        guard !summary.isEmpty else { return }
        arrivals.enqueue(
            Arrival(kind: .morningSummary(summary), updateCount: 1, actors: summary.actors),
            collected: collected, repos: repos)
    }

    private func publishArrival() {
        if arrival != arrivals.current { arrival = arrivals.current }
    }

    // MARK: GitHub writes

    private func sync(_ operation: @escaping @Sendable (any GitHubService) async throws(GitHubError) -> Void) {
        let service = service
        let key = UUID()
        syncTasks[key] = Task {
            do throws(GitHubError) {
                try await operation(service)
            } catch {
                self.lastSyncError = error
            }
            self.syncTasks[key] = nil
        }
    }

    // MARK: Storage

    /// Writes rows to memory and disk, then refreshes `groups`.
    private func store(_ changed: [TrackedThread], rebuild: Bool = true) {
        guard !changed.isEmpty else { return }
        for row in changed { rows[row.id] = row }
        if let account {
            do {
                try database.save(changed, for: account)
            } catch {
                Self.log.error("Saving threads failed: \(String(describing: error), privacy: .public)")
            }
        }
        if rebuild { rebuildGroups() }
    }

    private func rebuildGroups() {
        let next = rows.values.filter { settings.presents($0.thread) }.map(\.group).sorted { a, b in
            a.lastActivityAt != b.lastActivityAt ? a.lastActivityAt > b.lastActivityAt : a.id.rawValue < b.id.rawValue
        }
        if next != groups { groups = next }
    }

    private func loadRows(for account: AccountKey) -> [ThreadID: TrackedThread] {
        do {
            return Dictionary(try database.threads(for: account).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        } catch {
            Self.log.error("Loading threads failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func saveAppState() {
        let state = PersistedAppState(
            settings: settings, manualQuiet: manualQuiet, globalSnoozeUntil: globalSnoozeUntil, lastModified: lastModified,
            viewer: viewer, collected: collected, collectedReason: collectedReason)
        do {
            try database.save(state)
        } catch {
            Self.log.error("Saving app state failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func cachedDetail(_ id: ThreadID, account: AccountKey) -> ThreadDetail? {
        do {
            return try database.detail(for: id, account: account)
        } catch {
            Self.log.error("Loading cached timeline failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func saveDetail(_ detail: ThreadDetail, account: AccountKey) {
        do {
            try database.save(detail, for: account)
        } catch {
            Self.log.error("Caching timeline failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension ThreadDetail {
    func replacingItems(_ items: [TimelineItem]) -> ThreadDetail {
        ThreadDetail(
            threadID: threadID, title: title, state: state, author: author, htmlURL: htmlURL, items: items, checks: checks,
            fetchedAt: fetchedAt)
    }

    func appending(_ item: TimelineItem) -> ThreadDetail { replacingItems(items + [item]) }

    /// Threads the reply under the review holding `parent`; a standalone review item if that review isn't loaded.
    func inserting(_ comment: ReviewComment, replyingTo parent: ReviewComment) -> ThreadDetail {
        var items = items
        for index in items.indices {
            guard case .review(let state, let body, let comments) = items[index].payload,
                  comments.contains(where: { $0.id == parent.id }) else { continue }
            items[index] = items[index].with(payload: .review(state: state, body: body, comments: comments + [comment]))
            return replacingItems(items)
        }
        return appending(TimelineItem(
            id: comment.id, actor: comment.author, createdAt: comment.createdAt,
            payload: .review(state: .commented, body: "", comments: [comment]), url: comment.url))
    }
}
