import Foundation
import Observation

struct StoredSearchSubject: Codable, Equatable, Sendable {
    var item: SearchItem
    var seenThrough: Date?
    var dismissedThrough: Date?
    var lastVisitAt: Date?
    var detail: SearchSubjectDetail?
}

struct StoredCustomSectionPage: Codable, Equatable, Sendable {
    var page: SearchPage
    var refreshedAt: Date
    var baselinesNewItems: Bool
}

/// Browse-only search results. Subject state and caches never touch notification threads.
@MainActor @Observable public final class CustomSectionStore {
    public private(set) var definitions: [CustomSection] = []
    public private(set) var results: [UUID: CustomSectionResult] = [:]
    public private(set) var conversations: [SearchItemID: SearchConversationState] = [:]

    private let service: (any GitHubSearchService)?
    private let database: GitokenDatabase
    private let now: any NowProvider
    private var account: AccountKey?
    private var subjects: [SearchItemID: StoredSearchSubject] = [:]
    private var baselinesNewItems: [UUID: Bool] = [:]
    private var retryAfter: Date?
    @ObservationIgnored private var accountGeneration = UUID()
    @ObservationIgnored private var sectionRequests: [UUID: UUID] = [:]
    @ObservationIgnored private var detailRequests: [SearchItemID: UUID] = [:]
    @ObservationIgnored private var opened: Set<SearchItemID> = []
    @ObservationIgnored private var lastAttempts: [UUID: Date] = [:]
    @ObservationIgnored private var listedIDs: Set<SearchItemID> = []

    init(service: (any GitHubSearchService)?, database: GitokenDatabase, now: any NowProvider) {
        self.service = service
        self.database = database
        self.now = now
    }

    public func configure(sections: [CustomSection]) {
        guard definitions != sections else { return }
        let previous = Dictionary(definitions.map { ($0.id, $0.query) }, uniquingKeysWith: { first, _ in first })
        let current = Dictionary(sections.map { ($0.id, $0.query) }, uniquingKeysWith: { first, _ in first })
        let invalidated = previous.keys.filter { current[$0] != previous[$0] }
        definitions = sections
        for id in invalidated {
            results[id] = nil
            baselinesNewItems[id] = nil
            sectionRequests[id] = nil
            lastAttempts[id] = nil
        }
        if !invalidated.isEmpty {
            rebuildListedIDs()
            detailRequests = [:]
            for id in conversations.keys { conversations[id]?.isLoading = false }
            opened = opened.filter { item($0) != nil }
        }
        do {
            try database.pruneCustomSectionCaches(keeping: sections)
            if let account {
                for section in sections where results[section.id] == nil {
                    try loadCache(section, account: account)
                }
            }
        } catch {
            recordStorageError(error)
        }
    }

    public func setAccount(_ account: AccountKey?) {
        guard self.account != account else { return }
        self.account = account
        accountGeneration = UUID()
        sectionRequests = [:]
        detailRequests = [:]
        opened = []
        lastAttempts = [:]
        retryAfter = nil
        results = [:]
        conversations = [:]
        listedIDs = []
        subjects = [:]
        baselinesNewItems = [:]
        guard let account else { return }
        do {
            subjects = try database.searchSubjectStates(for: account)
            for section in definitions { try loadCache(section, account: account) }
        } catch {
            recordStorageError(error)
        }
    }

    public func refreshAll(force: Bool = false) async {
        let generation = accountGeneration
        let baselineAccount = subjects.isEmpty
        for section in definitions {
            guard !Task.isCancelled, generation == accountGeneration else { return }
            await refreshSection(section.id, force: force, baselineAccount: baselineAccount)
        }
    }

    public func refreshSection(_ id: UUID, force: Bool = true) async {
        await refreshSection(id, force: force, baselineAccount: false)
    }

    private func refreshSection(_ id: UUID, force: Bool, baselineAccount: Bool) async {
        guard let section = definitions.first(where: { $0.id == id }), sectionRequests[id] == nil else { return }
        if !force, let last = lastAttempts[id] ?? results[id]?.refreshedAt,
           now.now().timeIntervalSince(last) < 300 { return }
        await fetch(section, page: 1, appending: false, baselineAccount: baselineAccount)
    }

    public func loadMore(_ id: UUID) async {
        guard let section = definitions.first(where: { $0.id == id }), sectionRequests[id] == nil,
              let next = results[id]?.page.nextPage, next <= 10 else { return }
        await fetch(section, page: next, appending: true)
    }

    public func previewQuery(_ query: String) async throws(GitHubError) -> SearchPage {
        if let error = availabilityError(requireAccount: false) { throw error }
        guard let service else { throw Self.unavailable }
        let generation = accountGeneration
        do throws(GitHubError) {
            let page = try await service.searchIssues(query: query, page: 1)
            guard generation == accountGeneration else {
                throw GitHubError.transport("The GitHub account changed while previewing this query.")
            }
            return page
        } catch {
            if generation == accountGeneration { recordRateLimit(error) }
            throw error
        }
    }

    public func openConversation(_ item: SearchItem) async {
        guard account != nil else { return }
        var state = subjects[item.id] ?? StoredSearchSubject(
            item: item, seenThrough: nil, dismissedThrough: nil, lastVisitAt: nil, detail: nil)
        if item.updatedAt >= state.item.updatedAt { state.item = item }
        subjects[item.id] = state
        let newVisit = !opened.contains(item.id)
        opened.insert(item.id)
        await fetchConversation(for: subjects[item.id]?.item ?? item, newVisit: newVisit)
    }

    public func closeConversation(_ id: SearchItemID) {
        opened.remove(id)
        detailRequests[id] = nil
        conversations[id]?.isLoading = false
        guard var state = subjects[id] else { return }
        state.lastVisitAt = now.now()
        state.seenThrough = max(state.seenThrough ?? .distantPast, state.item.updatedAt)
        subjects[id] = state
        persist([state])
    }

    public func item(_ id: SearchItemID) -> SearchItem? {
        guard listedIDs.contains(id) else { return nil }
        return subjects[id]?.item
    }

    public func items(in id: UUID) -> [SearchItem] {
        (results[id]?.page.items ?? []).filter { !isDismissed($0) }
    }

    public func isUnseen(_ item: SearchItem) -> Bool {
        let latest = subjects[item.id]?.item.updatedAt ?? item.updatedAt
        return (subjects[item.id]?.seenThrough ?? .distantPast) < max(latest, item.updatedAt)
    }

    public func markSeen(_ item: SearchItem) {
        guard var state = subjects[item.id] else { return }
        state.seenThrough = max(state.seenThrough ?? .distantPast, max(state.item.updatedAt, item.updatedAt))
        subjects[item.id] = state
        persist([state])
    }

    public func dismiss(_ item: SearchItem) {
        guard var state = subjects[item.id] else { return }
        state.dismissedThrough = max(state.item.updatedAt, item.updatedAt)
        subjects[item.id] = state
        persist([state])
    }

    public func restore(_ id: SearchItemID) {
        guard var state = subjects[id] else { return }
        state.dismissedThrough = nil
        subjects[id] = state
        persist([state])
    }

    public func restoreAllDismissed() {
        var restored: [StoredSearchSubject] = []
        for (id, var state) in subjects where state.dismissedThrough != nil {
            state.dismissedThrough = nil
            subjects[id] = state
            restored.append(state)
        }
        persist(restored)
    }

    public func dismissedCount(in id: UUID) -> Int {
        (results[id]?.page.items ?? []).reduce(0) { $0 + (isDismissed($1) ? 1 : 0) }
    }

    private func isDismissed(_ item: SearchItem) -> Bool {
        guard let boundary = subjects[item.id]?.dismissedThrough else { return false }
        return max(subjects[item.id]?.item.updatedAt ?? item.updatedAt, item.updatedAt) <= boundary
    }

    private func loadCache(_ section: CustomSection, account: AccountKey) throws {
        guard let cache = try database.customSectionCache(for: section, account: account) else { return }
        results[section.id] = CustomSectionResult(page: cache.page, refreshedAt: cache.refreshedAt)
        listedIDs.formUnion(cache.page.items.lazy.map(\.id))
        baselinesNewItems[section.id] = cache.baselinesNewItems
    }

    private func fetch(_ section: CustomSection, page: Int, appending: Bool, baselineAccount: Bool = false) async {
        let id = section.id
        if let error = availabilityError() {
            var result = results[id] ?? CustomSectionResult()
            result.error = error
            results[id] = result
            return
        }
        guard let service, let account else { return }
        let generation = accountGeneration
        let request = UUID()
        sectionRequests[id] = request
        lastAttempts[id] = now.now()
        let previousResult = results[id]
        let baseline = appending ? (baselinesNewItems[id] ?? true) : results[id]?.refreshedAt == nil
        var loading = results[id] ?? CustomSectionResult()
        loading.isLoading = true
        loading.error = nil
        results[id] = loading
        do {
            let response = try await service.searchIssues(query: section.query, page: page)
            guard generation == accountGeneration, sectionRequests[id] == request,
                  definitions.contains(where: { $0.id == id && $0.query == section.query }) else { return }
            sectionRequests[id] = nil
            var merged = response
            var rows = appending ? (results[id]?.page.items ?? []) : []
            var indices = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            for item in response.items {
                if let index = indices[item.id] {
                    if item.updatedAt >= rows[index].updatedAt { rows[index] = item }
                } else if rows.count < 1000 {
                    indices[item.id] = rows.count
                    rows.append(item)
                }
            }
            merged.items = rows
            merged.incompleteResults = response.incompleteResults || (appending && (results[id]?.page.incompleteResults ?? false))
            if rows.count >= 1000 || (merged.nextPage ?? 0) > 10 { merged.nextPage = nil }
            var changed: [StoredSearchSubject] = []
            for item in response.items {
                if let previous = subjects[item.id], item.updatedAt > previous.item.updatedAt,
                   detailRequests[item.id] != nil {
                    detailRequests[item.id] = nil
                    conversations[item.id]?.isLoading = false
                }
                var state = subjects[item.id] ?? StoredSearchSubject(
                    item: item, seenThrough: baseline ? item.updatedAt : nil,
                    dismissedThrough: nil, lastVisitAt: nil, detail: nil)
                if item.updatedAt >= state.item.updatedAt { state.item = item }
                if baselineAccount { state.seenThrough = max(state.seenThrough ?? .distantPast, state.item.updatedAt) }
                subjects[item.id] = state
                changed.append(state)
            }
            let refreshedAt = now.now()
            results[id] = CustomSectionResult(page: merged, refreshedAt: refreshedAt)
            rebuildListedIDs()
            baselinesNewItems[id] = baseline
            do {
                try database.saveCustomSection(
                    StoredCustomSectionPage(page: merged, refreshedAt: refreshedAt, baselinesNewItems: baseline),
                    section: section, subjects: changed, account: account)
            } catch { recordStorageError(error) }
            for item in response.items where opened.contains(item.id) {
                guard generation == accountGeneration, definitions.contains(where: { $0.id == id && $0.query == section.query }) else { return }
                await fetchConversation(for: subjects[item.id]?.item ?? item, newVisit: false)
            }
        } catch {
            guard generation == accountGeneration, sectionRequests[id] == request else { return }
            sectionRequests[id] = nil
            if Task.isCancelled {
                results[id] = previousResult
                lastAttempts[id] = nil
                return
            }
            results[id]?.isLoading = false
            results[id]?.error = error
            recordRateLimit(error)
        }
    }

    private func fetchConversation(for item: SearchItem, newVisit: Bool) async {
        guard let account, var state = subjects[item.id], detailRequests[item.id] == nil else { return }
        let generation = accountGeneration
        let request = UUID()
        let previousVisit = state.lastVisitAt
        state.seenThrough = max(state.seenThrough ?? .distantPast, item.updatedAt)
        if newVisit { state.lastVisitAt = now.now() }
        subjects[item.id] = state
        var conversation = conversations[item.id] ?? SearchConversationState(detail: state.detail)
        if newVisit { conversation.lastVisitAt = previousVisit }
        conversation.error = availabilityError()
        conversation.isLoading = conversation.error == nil
        conversations[item.id] = conversation
        persist([state])
        guard conversation.error == nil, let service else { return }
        detailRequests[item.id] = request
        do {
            let detail = try await service.searchDetail(for: item)
            guard generation == accountGeneration, detailRequests[item.id] == request else { return }
            detailRequests[item.id] = nil
            conversations[item.id]?.detail = detail
            conversations[item.id]?.isLoading = false
            if var current = subjects[item.id] {
                current.detail = detail
                subjects[item.id] = current
                do { try database.saveSearchSubjects([current], for: account) }
                catch { recordStorageError(error) }
            }
        } catch {
            guard generation == accountGeneration, detailRequests[item.id] == request else { return }
            detailRequests[item.id] = nil
            conversations[item.id]?.isLoading = false
            conversations[item.id]?.error = error
            recordRateLimit(error)
        }
    }

    private static var unavailable: GitHubError { .transport("Custom-section search is unavailable for this service.") }

    private func availabilityError(requireAccount: Bool = true) -> GitHubError? {
        guard service != nil else { return Self.unavailable }
        if requireAccount, account == nil { return .transport("Sign in to load custom sections.") }
        if let retryAfter, now.now() < retryAfter { return .rateLimited(resetAt: retryAfter) }
        return nil
    }

    private func recordRateLimit(_ error: GitHubError) {
        if case .rateLimited(let resetAt) = error {
            retryAfter = resetAt ?? now.now().addingTimeInterval(300)
        }
    }

    private func rebuildListedIDs() {
        var ids: Set<SearchItemID> = []
        for result in results.values {
            for item in result.page.items { ids.insert(item.id) }
        }
        listedIDs = ids
    }

    private func persist(_ states: [StoredSearchSubject]) {
        guard let account, !states.isEmpty else { return }
        do { try database.saveSearchSubjects(states, for: account) }
        catch { recordStorageError(error) }
    }

    private func recordStorageError(_ error: any Error) {
        let failure = GitHubError.transport("Custom-section storage failed: \(error)")
        for section in definitions {
            var result = results[section.id] ?? CustomSectionResult()
            result.error = failure
            results[section.id] = result
        }
        for id in conversations.keys { conversations[id]?.error = failure }
    }
}
