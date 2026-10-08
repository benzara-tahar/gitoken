import Foundation
import Testing
@testable import GitokenCore

private func searchItem(_ id: String, at date: Date = t0, kind: SubjectKind = .pullRequest) -> SearchItem {
    SearchItem(id: SearchItemID(id), repo: repo, number: 42, kind: kind, title: "Subject \(id)",
               state: .open, author: sarah, updatedAt: date,
               htmlURL: URL(string: "https://github.com/acme/web/pull/42")!)
}

private func searchPage(_ items: [SearchItem], total: Int? = nil, next: Int? = nil, incomplete: Bool = false) -> SearchPage {
    SearchPage(items: items, totalCount: total ?? items.count, incompleteResults: incomplete, nextPage: next)
}

private func makeSearchDetail(_ item: SearchItem, at date: Date = t0) -> SearchSubjectDetail {
    SearchSubjectDetail(id: item.id, title: item.title, state: item.state, author: item.author,
                        htmlURL: item.htmlURL, items: [comment("c1", by: sarah, at: date)], checks: nil, fetchedAt: date)
}

private actor SectionSearchService: GitHubSearchService {
    struct Call: Equatable, Sendable {
        let query: String
        let page: Int
    }
    var calls: [Call] = []
    var detailCalls: [SearchItemID] = []
    private var responses: [Call: Result<SearchPage, GitHubError>] = [:]
    private var details: [SearchItemID: Result<SearchSubjectDetail, GitHubError>] = [:]
    private var pausedQueries: Set<String> = []
    private var searchGates: [String: CheckedContinuation<Void, Never>] = [:]
    private var pausedDetails: Set<SearchItemID> = []
    private var detailGates: [SearchItemID: CheckedContinuation<Void, Never>] = [:]
    private var searchWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var detailWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func respond(_ query: String, page: Int = 1, with result: Result<SearchPage, GitHubError>) {
        responses[Call(query: query, page: page)] = result
    }
    func respondDetail(_ item: SearchItem, with result: Result<SearchSubjectDetail, GitHubError>) {
        details[item.id] = result
    }
    func pauseSearch(_ query: String) { pausedQueries.insert(query) }
    func pauseDetail(_ id: SearchItemID) { pausedDetails.insert(id) }
    func releaseSearch(_ query: String) {
        pausedQueries.remove(query)
        searchGates.removeValue(forKey: query)?.resume()
    }
    func releaseDetail(_ id: SearchItemID) {
        pausedDetails.remove(id)
        detailGates.removeValue(forKey: id)?.resume()
    }
    func waitForSearches(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { searchWaiters.append((count, $0)) }
    }
    func waitForDetails(_ count: Int) async {
        if detailCalls.count >= count { return }
        await withCheckedContinuation { detailWaiters.append((count, $0)) }
    }
    func searchIssues(query: String, page: Int) async throws(GitHubError) -> SearchPage {
        let call = Call(query: query, page: page)
        let result = responses[call] ?? .success(searchPage([]))
        calls.append(call)
        let ready = searchWaiters.filter { $0.0 <= calls.count }
        searchWaiters.removeAll { $0.0 <= calls.count }
        for (_, waiter) in ready { waiter.resume() }
        if pausedQueries.contains(query) {
            await withCheckedContinuation { searchGates[query] = $0 }
        }
        return try result.get()
    }
    func searchDetail(for item: SearchItem) async throws(GitHubError) -> SearchSubjectDetail {
        let result = details[item.id] ?? .success(makeSearchDetail(item))
        detailCalls.append(item.id)
        let ready = detailWaiters.filter { $0.0 <= detailCalls.count }
        detailWaiters.removeAll { $0.0 <= detailCalls.count }
        for (_, waiter) in ready { waiter.resume() }
        if pausedDetails.contains(item.id) {
            await withCheckedContinuation { detailGates[item.id] = $0 }
        }
        return try result.get()
    }
}

extension SectionSearchService.Call: Hashable {}

@MainActor @Suite struct CustomSectionStoreTests {
    let account = AccountKey(login: "akim")

    private func store(_ service: SectionSearchService, database: GitokenDatabase, clock: OffsetNow, sections: [CustomSection]) -> CustomSectionStore {
        let store = CustomSectionStore(service: service, database: database, now: clock)
        store.configure(sections: sections)
        store.setAccount(account)
        return store
    }

    @Test func overlappingSectionsShareSeenDismissedAndVisitsWithoutChangingNotificationsOrAlerts() async throws {
        let db = try GitokenDatabase.inMemory()
        var native = TrackedThread(thread: makeThread("42", updatedAt: t0))
        native.unseenCount = 3
        try db.save([native], for: account)
        var app = PersistedAppState()
        app.collected.add(groupID: native.id, count: 3, actors: [sarah])
        app.manualQuiet = true
        try db.save(app)
        let clock = OffsetNow.fixed(t0)
        let service = SectionSearchService()
        let a = CustomSection(name: "Reviews", query: "is:pr review-requested:@me")
        let b = CustomSection(name: "Repository", query: "repo:acme/web")
        let initial = searchItem("PR_node")
        await service.respond(a.query, with: .success(searchPage([initial])))
        await service.respond(b.query, with: .success(searchPage([initial])))
        let store = store(service, database: db, clock: clock, sections: [a, b])
        await store.refreshAll()
        #expect(!store.isUnseen(initial))
        store.dismiss(initial)
        #expect(store.items(in: a.id).isEmpty)
        #expect(store.items(in: b.id).isEmpty)
        #expect(store.dismissedCount(in: a.id) == 1)
        store.restore(initial.id)
        #expect(store.items(in: a.id) == [initial])
        #expect(store.items(in: b.id) == [initial])
        let updated = searchItem("PR_node", at: t0 + 10)
        await service.respond(a.query, with: .success(searchPage([updated])))
        await store.refreshSection(a.id)
        #expect(store.isUnseen(updated))
        #expect(store.isUnseen(initial), "The same subject has one seen boundary even in an older section cache")
        clock.advance(by: 20)
        await store.openConversation(initial)
        #expect(!store.isUnseen(updated))
        #expect(store.conversations[initial.id]?.lastVisitAt == nil)
        store.closeConversation(initial.id)
        clock.advance(by: 30)
        await store.openConversation(updated)
        #expect(store.conversations[initial.id]?.lastVisitAt == t0 + 20)
        #expect(try db.threads(for: account) == [native])
        #expect(try db.appState() == app, "Search browsing must not mutate collected arrivals, settings, quiet state or badges")
        #expect(try db.detail(for: native.id, account: account) == nil)
    }

    @Test func baselineQueryEditsAndPresentationEditsPreserveExistingUnseenState() async throws {
        let db = try GitokenDatabase.inMemory()
        let service = SectionSearchService()
        let clock = OffsetNow.fixed(t0)
        var section = CustomSection(name: "A", query: "is:pr state:open")
        let known = searchItem("known")
        await service.respond(section.query, with: .success(searchPage([known])))
        let store = store(service, database: db, clock: clock, sections: [section])
        await store.refreshAll()
        let updated = searchItem("known", at: t0 + 30)
        let newlyArrived = searchItem("later", at: t0 + 30)
        await service.respond(section.query, with: .success(searchPage([updated, newlyArrived])))
        await store.refreshSection(section.id)
        #expect(store.isUnseen(updated))
        #expect(store.isUnseen(newlyArrived), "Previously unknown subjects on a later refresh are new activity")
        let previous = store.results[section.id]
        section.name = "Renamed"
        section.isCollapsed = true
        store.configure(sections: [section])
        #expect(store.results[section.id] == previous)
        #expect(await service.calls.count == 2)
        section.query = "is:pr (state:open OR state:closed) archived:false"
        let unknown = searchItem("query-new", kind: .issue)
        await service.respond(section.query, with: .success(searchPage([updated, unknown])))
        store.configure(sections: [section])
        #expect(store.results[section.id] == nil)
        await store.refreshSection(section.id)
        #expect(store.isUnseen(updated), "A new query must not clear an existing unseen boundary")
        #expect(!store.isUnseen(unknown), "Only newly unknown items are baselined for a new query")
        #expect(store.item(newlyArrived.id) == nil, "Refresh and query edits remove subjects no longer matching")
    }

    @Test func dismissedActivityReappearsEverywhereAndUndoRestoresEverywhere() async throws {
        let db = try GitokenDatabase.inMemory()
        let service = SectionSearchService()
        let a = CustomSection(name: "A", query: "a")
        let b = CustomSection(name: "B", query: "b")
        let old = searchItem("same")
        for query in [a.query, b.query] { await service.respond(query, with: .success(searchPage([old]))) }
        let store = store(service, database: db, clock: .fixed(t0), sections: [a, b])
        await store.refreshAll()
        store.dismiss(old)
        let updated = searchItem("same", at: t0 + 1)
        await service.respond(a.query, with: .success(searchPage([updated])))
        await store.refreshSection(a.id)
        #expect(store.items(in: a.id) == [updated])
        #expect(store.items(in: b.id) == [old], "New activity clears the hiding effect in every overlapping section")
        #expect(store.dismissedCount(in: b.id) == 0)
        store.dismiss(old)
        #expect(store.items(in: a.id).isEmpty)
        #expect(store.items(in: b.id).isEmpty)
        store.restoreAllDismissed()
        #expect(store.items(in: a.id) == [updated])
        #expect(store.items(in: b.id) == [old])
    }

    @Test func paginationDeduplicatesInServerOrderAndRefreshReplacesRowsWhileErrorsRetainGoodCache() async throws {
        let db = try GitokenDatabase.inMemory()
        let service = SectionSearchService()
        let section = CustomSection(name: "Paged", query: "sort:updated-desc")
        let a = searchItem("a")
        let b = searchItem("b")
        let c = searchItem("c")
        await service.respond(section.query, with: .success(searchPage([a, b], total: 3, next: 2)))
        await service.respond(section.query, page: 2, with: .success(searchPage([b, c], total: 3, incomplete: true)))
        let store = store(service, database: db, clock: .fixed(t0), sections: [section])
        await store.refreshSection(section.id)
        await store.loadMore(section.id)
        #expect(store.items(in: section.id) == [a, b, c])
        #expect(!store.isUnseen(c), "Initial pagination is part of the first baseline")
        #expect(store.results[section.id]?.page.incompleteResults == true)
        let cached = store.results[section.id]?.page
        let failure = GitHubError.http(status: 503, message: "Unavailable")
        await service.respond(section.query, with: .failure(failure))
        await store.refreshSection(section.id)
        #expect(store.results[section.id]?.page == cached)
        #expect(store.results[section.id]?.error == failure)
        #expect(store.results[section.id]?.isLoading == false)
        await service.respond(section.query, with: .success(searchPage([c])))
        await store.refreshSection(section.id)
        #expect(store.items(in: section.id) == [c])
        #expect(store.results[section.id]?.error == nil)
        #expect(store.item(a.id) == nil)
        #expect(await service.calls.map(\.page) == [1, 2, 1, 1])
    }

    @Test func previewIsEphemeralAndPollingThrottleAndRateLimitsPreventRetryStorms() async throws {
        let db = try GitokenDatabase.inMemory()
        let service = SectionSearchService()
        let clock = OffsetNow.fixed(t0)
        let a = CustomSection(name: "A", query: "a")
        let b = CustomSection(name: "B", query: "b")
        let item = searchItem("preview")
        let query = "is:issue (label:bug OR label:urgent) archived:false sort:updated-desc"
        await service.respond(query, with: .success(searchPage([item], total: 1001, incomplete: true)))
        let store = store(service, database: db, clock: clock, sections: [a, b])
        let preview = try await store.previewQuery(query)
        #expect(preview.items == [item])
        #expect(store.definitions == [a, b])
        #expect(store.results.isEmpty)
        #expect(store.conversations.isEmpty)
        #expect(try db.searchSubjectStates(for: account).isEmpty)
        #expect(try db.customSectionCache(for: a, account: account) == nil)
        let reset = t0 + 600
        await service.respond(a.query, with: .failure(.rateLimited(resetAt: reset)))
        await store.refreshAll(force: true)
        #expect(await service.calls.count == 2, "Preview plus one rate-limited request; other sections must not hit the network")
        #expect(store.results[b.id]?.error == .rateLimited(resetAt: reset))
        await store.refreshAll(force: true)
        #expect(await service.calls.count == 2)
        clock.advance(by: 601)
        await service.respond(a.query, with: .success(searchPage([])))
        await store.refreshAll()
        #expect(await service.calls.count == 4)
        await store.refreshAll()
        #expect(await service.calls.count == 4)
        clock.advance(by: 300)
        await store.refreshAll()
        #expect(await service.calls.count == 6)
    }

    @Test func unavailableServiceShowsExplicitErrors() async throws {
        let db = try GitokenDatabase.inMemory()
        let store = CustomSectionStore(service: nil, database: db, now: OffsetNow.fixed(t0))
        let section = CustomSection(name: "A", query: "a")
        store.configure(sections: [section])
        store.setAccount(account)
        await store.refreshAll()
        #expect(store.results[section.id]?.error == .transport("Custom-section search is unavailable for this service."))
        await #expect(throws: GitHubError.transport("Custom-section search is unavailable for this service.")) {
            try await store.previewQuery("a")
        }
    }

    @Test func staleSearchCompletionsCannotWinAfterQueryEditRemovalOrAccountSwitch() async throws {
        let db = try GitokenDatabase.inMemory()
        let service = SectionSearchService()
        var section = CustomSection(name: "A", query: "old")
        let old = searchItem("old")
        let fresh = searchItem("fresh")
        await service.respond("old", with: .success(searchPage([old])))
        await service.respond("new", with: .success(searchPage([fresh])))
        await service.pauseSearch("old")
        let store = store(service, database: db, clock: .fixed(t0), sections: [section])
        let pending = Task { await store.refreshSection(section.id) }
        await service.waitForSearches(1)
        section.query = "new"
        store.configure(sections: [section])
        await store.refreshSection(section.id)
        await service.releaseSearch("old")
        await pending.value
        #expect(store.items(in: section.id) == [fresh])
        #expect(try db.searchSubjectStates(for: account)[old.id] == nil)
        await service.pauseSearch("new")
        let removed = Task { await store.refreshSection(section.id) }
        await service.waitForSearches(3)
        store.configure(sections: [])
        await service.releaseSearch("new")
        await removed.value
        #expect(store.results.isEmpty)
        #expect(try db.customSectionCache(for: section, account: account) == nil)
        store.configure(sections: [section])
        await service.pauseSearch("new")
        let switched = Task { await store.refreshSection(section.id) }
        await service.waitForSearches(4)
        store.setAccount(AccountKey(login: "other"))
        await service.releaseSearch("new")
        await switched.value
        #expect(store.results.isEmpty)
        #expect(try db.searchSubjectStates(for: AccountKey(login: "other")).isEmpty)
    }

    @Test func staleDetailsCannotWinAfterQueryEditRemovalOrAccountSwitch() async throws {
        for invalidation in 0..<3 {
            let db = try GitokenDatabase.inMemory()
            let service = SectionSearchService()
            var section = CustomSection(name: "A", query: "a")
            let item = searchItem("subject")
            await service.respond(section.query, with: .success(searchPage([item])))
            let store = store(service, database: db, clock: .fixed(t0), sections: [section])
            await store.refreshAll()
            await service.pauseDetail(item.id)
            let pending = Task { await store.openConversation(item) }
            await service.waitForDetails(1)
            switch invalidation {
            case 0:
                section.query = "edited"
                store.configure(sections: [section])
            case 1:
                store.configure(sections: [])
            default:
                store.setAccount(AccountKey(login: "other"))
            }
            await service.releaseDetail(item.id)
            await pending.value
            #expect(store.conversations[item.id]?.detail == nil)
            #expect(store.conversations[item.id]?.isLoading != true)
            #expect(try db.searchSubjectStates(for: account)[item.id]?.detail == nil)
        }
    }

    @Test func refreshedOpenedSubjectUpdatesItsDetailWithoutMarkingGitHubNotifications() async throws {
        let db = try GitokenDatabase.inMemory()
        let service = SectionSearchService()
        let section = CustomSection(name: "A", query: "a")
        let initial = searchItem("opened")
        await service.respond(section.query, with: .success(searchPage([initial])))
        let store = store(service, database: db, clock: .fixed(t0), sections: [section])
        await store.refreshAll()
        await store.openConversation(initial)
        let updated = searchItem("opened", at: t0 + 5)
        let detail = makeSearchDetail(updated, at: t0 + 10)
        await service.respond(section.query, with: .success(searchPage([updated])))
        await service.respondDetail(updated, with: .success(detail))
        await store.refreshSection(section.id)
        #expect(store.conversations[initial.id]?.detail == detail)
        #expect(!store.isUnseen(updated))
        #expect(await service.detailCalls.count == 2)
        #expect(try db.threads(for: account).isEmpty)
    }

    @Test func restartAndAccountSwitchRestoreSharedSeenDismissalVisitsAndDetailCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gitoken-section-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "gitoken.sqlite")
        let clock = OffsetNow.fixed(t0)
        let service = SectionSearchService()
        var a = CustomSection(name: "A", query: "a")
        let b = CustomSection(name: "B", query: "b")
        let initial = searchItem("shared")
        for query in [a.query, b.query] { await service.respond(query, with: .success(searchPage([initial]))) }
        do {
            let db = try GitokenDatabase.onDisk(at: url)
            let store = store(service, database: db, clock: clock, sections: [a, b])
            await store.refreshAll()
            await store.openConversation(initial)
            clock.advance(by: 10)
            store.closeConversation(initial.id)
            let updated = searchItem("shared", at: t0 + 5)
            await service.respond(a.query, with: .success(searchPage([updated])))
            await store.refreshSection(a.id)
            #expect(store.isUnseen(updated))
            store.dismiss(updated)
        }
        let db = try GitokenDatabase.onDisk(at: url)
        a.name = "Renamed"
        a.isCollapsed = true
        let restarted = store(service, database: db, clock: clock, sections: [b, a])
        #expect(restarted.definitions == [b, a])
        #expect(restarted.dismissedCount(in: a.id) == 1)
        #expect(restarted.items(in: b.id).isEmpty)
        let updated = try #require(restarted.item(initial.id))
        #expect(restarted.isUnseen(updated))
        let other = AccountKey(login: "other")
        restarted.setAccount(other)
        #expect(restarted.results.isEmpty)
        await restarted.refreshAll(force: true)
        #expect(!restarted.items(in: a.id).isEmpty, "Dismissals must not cross accounts")
        #expect(!restarted.isUnseen(updated), "An account's own initial baseline is independent")
        restarted.setAccount(account)
        #expect(restarted.items(in: a.id).isEmpty)
        #expect(restarted.isUnseen(updated))
        restarted.restore(updated.id)
        #expect(!restarted.items(in: b.id).isEmpty)
        await service.respondDetail(updated, with: .failure(.http(status: 503, message: "Try later")))
        clock.advance(by: 20)
        await restarted.openConversation(updated)
        #expect(restarted.conversations[updated.id]?.lastVisitAt == t0 + 10)
        #expect(restarted.conversations[updated.id]?.detail == makeSearchDetail(initial))
        #expect(restarted.conversations[updated.id]?.error == .http(status: 503, message: "Try later"))
        #expect(!restarted.isUnseen(updated), "Opening marks only local seen even if hydration fails")
        let third = store(service, database: try GitokenDatabase.onDisk(at: url), clock: clock, sections: [b, a])
        #expect(!third.items(in: a.id).isEmpty)
        #expect(!third.isUnseen(updated))
    }

    @Test func searchRetrievalCapKeepsTotalAndIncompleteWarningsWithoutFetchingAnEleventhPage() async throws {
        let db = try GitokenDatabase.inMemory()
        let service = SectionSearchService()
        let section = CustomSection(name: "Cap", query: "is:pr")
        let rows = (0..<1000).map { searchItem("node-\($0)") }
        await service.respond(section.query, with: .success(searchPage(rows, total: 1200, next: 11, incomplete: true)))
        let store = store(service, database: db, clock: .fixed(t0), sections: [section])
        await store.refreshAll()
        await store.loadMore(section.id)
        #expect(store.items(in: section.id).count == 1000)
        #expect(store.results[section.id]?.page.totalCount == 1200)
        #expect(store.results[section.id]?.page.incompleteResults == true)
        #expect(store.results[section.id]?.page.nextPage == nil)
        #expect(await service.calls.count == 1)
    }

    @Test func markSeenIsLocalPersistsAndDoesNotFetchDetail() async throws {
        let db = try GitokenDatabase.inMemory()
        let service = SectionSearchService()
        let a = CustomSection(name: "A", query: "a")
        let b = CustomSection(name: "B", query: "b")
        let initial = searchItem("shared")
        for query in [a.query, b.query] { await service.respond(query, with: .success(searchPage([initial]))) }
        let store = store(service, database: db, clock: .fixed(t0), sections: [a, b])
        await store.refreshAll()
        let updated = searchItem("shared", at: t0 + 5)
        await service.respond(a.query, with: .success(searchPage([updated])))
        await store.refreshSection(a.id)
        #expect(store.isUnseen(initial))
        store.markSeen(initial)
        #expect(!store.isUnseen(updated))
        #expect(store.conversations.isEmpty)
        #expect(await service.detailCalls.isEmpty)
        #expect(try db.searchSubjectStates(for: account)[initial.id]?.seenThrough == updated.updatedAt)
        #expect(try db.threads(for: account).isEmpty)
    }

    @Test func previewResultCanOpenNativelyWithoutSavingASectionOrCreatingANotification() async throws {
        let db = try GitokenDatabase.inMemory()
        let service = SectionSearchService()
        let subject = searchItem("preview-only")
        await service.respond("author:sarah", with: .success(searchPage([subject])))
        let store = store(service, database: db, clock: .fixed(t0), sections: [])
        let page = try await store.previewQuery("author:sarah")
        #expect(try db.searchSubjectStates(for: account).isEmpty)
        await store.openConversation(try #require(page.items.first))
        #expect(try db.searchSubjectStates(for: account)[subject.id]?.lastVisitAt == t0)
        #expect(!store.isUnseen(subject))
        #expect(store.definitions.isEmpty)
        #expect(store.results.isEmpty)
        #expect(try db.threads(for: account).isEmpty)
        #expect(try db.searchSubjectStates(for: account)[subject.id]?.seenThrough == subject.updatedAt)
    }

    @Test func accountChangeRejectsInFlightPreview() async throws {
        let service = SectionSearchService()
        let subject = searchItem("private-account-result")
        await service.respond("a", with: .success(searchPage([subject])))
        await service.pauseSearch("a")
        let store = store(service, database: try .inMemory(), clock: .fixed(t0), sections: [])
        let task = Task { try await store.previewQuery("a") }
        await service.waitForSearches(1)
        store.setAccount(AccountKey(login: "other"))
        await service.releaseSearch("a")
        do {
            _ = try await task.value
            Issue.record("An old account's preview must not appear after switching accounts")
        } catch let error as GitHubError {
            if case .transport = error {} else { Issue.record("Unexpected preview error: \(error)") }
        } catch {
            Issue.record("Unexpected preview error: \(error)")
        }
        #expect(store.conversations.isEmpty)
    }

    @Test func closingTheListCancelsRemainingSectionRefreshes() async throws {
        let service = SectionSearchService()
        let a = CustomSection(name: "A", query: "a")
        let b = CustomSection(name: "B", query: "b")
        await service.respond(a.query, with: .success(searchPage([searchItem("a")])))
        await service.respond(b.query, with: .success(searchPage([searchItem("b")])))
        await service.pauseSearch(a.query)
        let store = store(service, database: try .inMemory(), clock: .fixed(t0), sections: [a, b])
        let task = Task { await store.refreshAll() }
        await service.waitForSearches(1)
        task.cancel()
        await service.releaseSearch(a.query)
        await task.value
        #expect(store.items(in: a.id).map(\.id) == [SearchItemID("a")])
        #expect(store.results[b.id] == nil)
        #expect(await service.calls == [.init(query: a.query, page: 1)])
    }
}
