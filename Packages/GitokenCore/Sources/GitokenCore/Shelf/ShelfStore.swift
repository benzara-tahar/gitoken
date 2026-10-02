import Foundation
import Observation
import os

/// PR Shelf state: the viewer's open PRs plus pinned ones, polled about every 90 s. Changes between polls become
/// `ShelfEvent`s (filtered by `settings.shelf.events`); outside quiet time they publish a `pulse`, during quiet
/// they go to the overnight log for the morning summary. Create through `InboxStore.makeShelfStore()`.
@MainActor
@Observable
public final class ShelfStore {
    public static let pollInterval: Duration = .seconds(90)
    /// Retry delay while the inbox has not identified the account yet.
    static let accountRetryInterval: Duration = .seconds(10)
    /// Overnight events older than this are dropped unread (no morning summary consumed them).
    static let overnightRetention: TimeInterval = 24 * 60 * 60

    // MARK: State

    /// Newest update first.
    public private(set) var items: [ShelfItem] = []
    /// Bumped once per poll that produced enabled events outside quiet time.
    public private(set) var pulse: ShelfPulse?
    public private(set) var isRefreshing = false
    public private(set) var lastSyncAt: Date?
    public private(set) var lastSyncError: GitHubError?
    /// Enabled events collected while the inbox was quiet, oldest first. Persisted until taken.
    public private(set) var overnightChanges: [ShelfEvent] = []

    public var settings: ShelfSettings { settingsProvider() }

    public func status(for ref: PullRequestRef) -> PullRequestStatus? { known[ref] }

    // MARK: Intents

    /// Pins a PR from a dropped GitHub URL. Returns the parsed reference.
    @discardableResult
    public func pin(url: URL) async throws(ShelfError) -> PullRequestRef {
        guard let ref = PullRequestRef(url: url) else { throw .notAPullRequestURL }
        try await pin(ref)
        return ref
    }

    /// Fetches the PR first; unknown or inaccessible PRs are not pinned. Pinning adds no events.
    public func pin(_ ref: PullRequestRef) async throws(ShelfError) {
        guard let account = currentAccount() else { throw .github(.transport("Not signed in yet")) }
        if pins[ref] != nil { return }
        let fetched: [PullRequestStatus]
        do throws(GitHubError) {
            fetched = try await service.pullRequests([ref])
        } catch {
            throw .github(error)
        }
        guard let status = fetched.first(where: { $0.ref == ref }), loadedAccount == account else { throw .notFound }
        let at = now.now()
        pins[ref] = at
        known[ref] = status
        persist { db in
            try db.savePin(ref, at: at, for: account)
            try db.saveShelfStatuses([status], mine: mine, removing: [], for: account)
        }
        rebuildItems()
    }

    /// Removes a pinned PR; the viewer's own open PRs stay on the shelf regardless.
    public func unpin(_ ref: PullRequestRef) {
        guard let account = loadedAccount, pins.removeValue(forKey: ref) != nil else { return }
        let drop = !mine.contains(ref)
        if drop { known[ref] = nil }
        persist { db in
            try db.deletePin(ref, for: account)
            if drop { try db.saveShelfStatuses([], mine: [], removing: [ref], for: account) }
        }
        rebuildItems()
    }

    /// Merges at the head SHA the card shows, then re-reads the PR. The merge itself raises no event.
    public func merge(_ ref: PullRequestRef, method: MergeMethod) async throws(GitHubError) {
        guard let status = known[ref] else { throw .http(status: 404, message: "This pull request is no longer on the shelf.") }
        try await service.merge(status, method: method)
        locallyMerged.insert(ref)
        let refreshed = try? await service.pullRequests([ref])
        guard let account = loadedAccount else { return }
        if pins[ref] != nil {
            if let fresh = refreshed?.first(where: { $0.ref == ref }) {
                known[ref] = fresh
                persist { db in try db.saveShelfStatuses([fresh], mine: mine, removing: [], for: account) }
            }
        } else {
            known[ref] = nil
            mine.remove(ref)
            persist { db in try db.saveShelfStatuses([], mine: [], removing: [ref], for: account) }
        }
        rebuildItems()
    }

    /// Markdown for an AI coding agent (see `AgentContext`).
    public func agentContext(for ref: PullRequestRef) async throws(GitHubError) -> String {
        try await service.agentContext(for: ref)
    }

    /// Returns and clears the overnight log (the morning summary consumes it once).
    public func takeOvernightChanges() -> [ShelfEvent] {
        let taken = overnightChanges
        guard !taken.isEmpty else { return [] }
        overnightChanges = []
        if let account = loadedAccount { persist { db in try db.clearOvernight(for: account) } }
        return taken
    }

    // MARK: Lifecycle

    /// Polls now, then every `pollInterval`.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        isPaused = false
        startPolling(after: .zero)
    }

    public func stop() {
        isStarted = false
        isPaused = false
        pollLoop.stop()
    }

    /// System sleep / screen lock. Idempotent.
    public func pause() {
        guard isStarted, !isPaused else { return }
        isPaused = true
        pollLoop.stop()
    }

    /// Wake / unlock: polls immediately. Idempotent.
    public func resume() {
        guard isStarted, isPaused else { return }
        isPaused = false
        startPolling(after: .zero)
    }

    /// Polls now (joining or following any poll in flight) and restarts the poll timer.
    public func refresh() async {
        let next = await pollCycle(fresh: true)
        guard isStarted, !isPaused else { return }
        startPolling(after: next)
    }

    // MARK: Wiring

    private static let log = Logger(subsystem: "io.github.benzara-tahar.Gitoken", category: "ShelfStore")

    private let service: any PullRequestService
    private let database: GitokenDatabase
    private let now: any NowProvider
    private let accountProvider: @MainActor () -> AccountKey?
    private let settingsProvider: @MainActor () -> ShelfSettings
    private let quietProvider: @MainActor () -> QuietReason?

    @ObservationIgnored private var loadedAccount: AccountKey?
    @ObservationIgnored private var known: [PullRequestRef: PullRequestStatus] = [:]
    @ObservationIgnored private var mine: Set<PullRequestRef> = []
    @ObservationIgnored private var pins: [PullRequestRef: Date] = [:]
    /// Merged from the shelf: a later poll seeing the merge must not announce it.
    @ObservationIgnored private var locallyMerged: Set<PullRequestRef> = []
    @ObservationIgnored private var nextPulseID = 1
    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    private let pollLoop = RepeatingTask()

    init(
        service: any PullRequestService, database: GitokenDatabase, now: any NowProvider,
        account: @escaping @MainActor () -> AccountKey?, settings: @escaping @MainActor () -> ShelfSettings,
        quietReason: @escaping @MainActor () -> QuietReason?
    ) {
        self.service = service
        self.database = database
        self.now = now
        self.accountProvider = account
        self.settingsProvider = settings
        self.quietProvider = quietReason
        if let account = account() { load(account) }
    }

    /// The current account, reloading persisted shelf state when it changed.
    private func currentAccount() -> AccountKey? {
        guard let account = accountProvider() else { return nil }
        if account != loadedAccount { load(account) }
        return account
    }

    private func load(_ account: AccountKey) {
        let snapshot: ShelfSnapshot
        do {
            snapshot = try database.shelfSnapshot(for: account)
        } catch {
            Self.log.error("Loading shelf failed: \(String(describing: error), privacy: .public)")
            snapshot = ShelfSnapshot()
        }
        loadedAccount = account
        pins = snapshot.pins
        known = snapshot.statuses
        mine = snapshot.mine
        let cutoff = now.now().addingTimeInterval(-Self.overnightRetention)
        overnightChanges = snapshot.overnight.filter { $0.at >= cutoff }
        locallyMerged = []
        rebuildItems()
    }

    // MARK: Polling

    private func startPolling(after delay: Duration) {
        pollLoop.start(after: delay) { [weak self] in await self?.pollCycle(fresh: false) }
    }

    private func pollCycle(fresh: Bool) async -> Duration {
        await pollNow(fresh: fresh)
        guard loadedAccount != nil, accountProvider() != nil else { return Self.accountRetryInterval }
        var delay = Self.pollInterval
        if let retryAfter {
            let wait = retryAfter.timeIntervalSince(now.now())
            if wait > 0 { delay = max(delay, .seconds(wait)) }
        }
        return delay
    }

    /// Serialized like the inbox poll: a fresh caller waits for the poll in flight and then polls again.
    private func pollNow(fresh: Bool) async {
        if let running = inFlight {
            await running.value
            guard fresh else { return }
        }
        if let running = inFlight {
            await running.value
            return
        }
        let task = Task {
            await self.performPoll()
            self.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    private func performPoll() async {
        guard settings.enabled, let account = currentAccount() else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let fetchedMine: [PullRequestStatus]
        do throws(GitHubError) {
            fetchedMine = try await service.myOpenPullRequests()
        } catch {
            record(error)
            return
        }
        let mineRefs = Set(fetchedMine.map(\.ref))
        // Own PRs leave the search once merged/closed; look them up once more to learn how they ended.
        let vanished = mine.subtracting(mineRefs).subtracting(pins.keys)
        let lookups = Set(pins.keys).subtracting(mineRefs).union(vanished)
            .sorted { ($0.repo.fullName, $0.number) < ($1.repo.fullName, $1.number) }
        var looked: [PullRequestStatus]?
        if !lookups.isEmpty {
            do throws(GitHubError) {
                looked = try await service.pullRequests(lookups)
            } catch {
                record(error)
            }
        } else {
            looked = []
        }
        guard loadedAccount == account else { return }

        let at = now.now()
        var events: [ShelfEvent] = []
        var saved: [PullRequestStatus] = []
        var removed: [PullRequestRef] = []
        var nextMine = mineRefs

        func absorb(_ status: PullRequestStatus) {
            if let old = known[status.ref] {
                var found = ShelfEventDetector.events(from: old, to: status, at: at)
                if locallyMerged.contains(status.ref) { found.removeAll { $0.kind == .merged } }
                events += found
            }
            if known[status.ref] != status { saved.append(status) }
            known[status.ref] = status
        }

        for status in fetchedMine { absorb(status) }
        if let looked {
            let byRef = Dictionary(looked.map { ($0.ref, $0) }, uniquingKeysWith: { _, last in last })
            for ref in lookups {
                guard let status = byRef[ref] else {
                    // Inaccessible now: forget an own PR; a pin keeps its last-known state.
                    if vanished.contains(ref) {
                        known[ref] = nil
                        removed.append(ref)
                    }
                    continue
                }
                absorb(status)
                if vanished.contains(ref) {
                    if status.state == .open {
                        nextMine.insert(ref)  // search index lag
                    } else {
                        known[ref] = nil
                        removed.append(ref)
                    }
                }
            }
        } else {
            nextMine.formUnion(vanished)  // retry the lookup next poll
        }
        locallyMerged.subtract(removed)
        if nextMine != mine {
            mine = nextMine
            saved = Array(known.values)  // every row's isMine flag may have flipped
        }
        saved.removeAll { removed.contains($0.ref) }
        let mineSnapshot = mine
        persist { db in try db.saveShelfStatuses(saved, mine: mineSnapshot, removing: removed, for: account) }

        rebuildItems()
        if looked != nil || lookups.isEmpty {
            lastSyncError = nil
            retryAfter = nil
        }
        lastSyncAt = at
        announce(events, account: account)
    }

    private func record(_ error: GitHubError) {
        if case .rateLimited(let resetAt) = error { retryAfter = resetAt }
        lastSyncError = error
    }

    private func announce(_ events: [ShelfEvent], account: AccountKey) {
        let enabled = settings.events
        let wanted = events.filter { enabled.contains($0.kind) }
        guard !wanted.isEmpty else { return }
        if quietProvider() != nil {
            let cutoff = now.now().addingTimeInterval(-Self.overnightRetention)
            overnightChanges = overnightChanges.filter { $0.at >= cutoff } + wanted
            persist { db in
                try db.clearOvernight(before: cutoff, for: account)
                try db.appendOvernight(wanted, for: account)
            }
        } else {
            pulse = ShelfPulse(id: nextPulseID, events: wanted)
            nextPulseID += 1
        }
    }

    // MARK: Storage

    private func rebuildItems() {
        let next = known.values
            .filter { pins[$0.ref] != nil || mine.contains($0.ref) }
            .sorted { a, b in
                a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : (a.ref.repo.fullName, a.ref.number) < (b.ref.repo.fullName, b.ref.number)
            }
            .map { ShelfItem(status: $0, isPinned: pins[$0.ref] != nil, isMine: mine.contains($0.ref)) }
        if next != items { items = next }
    }

    private func persist(_ write: (GitokenDatabase) throws -> Void) {
        do {
            try write(database)
        } catch {
            Self.log.error("Saving shelf failed: \(String(describing: error), privacy: .public)")
        }
    }
}
