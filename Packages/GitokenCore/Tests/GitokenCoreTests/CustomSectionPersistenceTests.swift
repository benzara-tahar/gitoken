import Foundation
import GRDB
import Testing
@testable import GitokenCore

@MainActor @Suite struct CustomSectionPersistenceTests {
    let account = AccountKey(login: "akim")

    @Test func settingsHaveNoSeededSectionsAndRoundTripNameQueryCollapseAndOrder() throws {
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"appearance":"fluid"}"#.utf8))
        #expect(older.customSections.isEmpty)
        #expect(AppSettings().customSections.isEmpty)
        let sections = [
            CustomSection(name: "Needs review", query: "is:pr (review-requested:@me OR user-review-requested:akim) archived:false", isCollapsed: true),
            CustomSection(name: "Bugs", query: "is:issue label:bug state:open sort:created-desc"),
        ]
        let settings = AppSettings(customSections: sections)
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: encoded) == settings)
        let db = try GitokenDatabase.inMemory()
        var state = PersistedAppState()
        state.settings = settings
        try db.save(state)
        #expect(try db.appState()?.settings.customSections == sections)
    }

    @Test func customSectionMigrationPreservesExistingNotificationHistoryAndSettings() throws {
        let queue = try DatabaseQueue()
        try GitokenDatabase.migrator.migrate(queue, upTo: "v5-collected-group-actors")
        let thread = makeThread("existing", updatedAt: t0)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO thread (accountHost, accountLogin, id, thread, updatedAt, unread, state, actors,
                unseenCount, keptLocally) VALUES (?, ?, ?, ?, ?, 1, 'open', '[]', 7, 0)
                """, arguments: [account.host, account.login, thread.id.rawValue,
                                   try StorageJSON.encode(thread), t0.timeIntervalSinceReferenceDate])
        }
        let migrated = try GitokenDatabase(queue: queue)
        let rows = try migrated.threads(for: account)
        #expect(rows.count == 1)
        #expect(rows.first?.thread == thread)
        #expect(rows.first?.unseenCount == 7)
        #expect(try migrated.searchSubjectStates(for: account).isEmpty)
        try queue.read { db throws in
            #expect(try db.tableExists("searchSubjectState"))
            #expect(try db.tableExists("customSectionCache"))
            #expect(try db.tableExists("threadDetail"))
            #expect(try db.tableExists("appState"))
        }
    }

    @Test func subjectStateAndQueryCacheRoundTripExactlyAndAreAccountScoped() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gitoken-custom-sections-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "gitoken.sqlite")
        let section = CustomSection(name: "A", query: "repo:acme/web is:pr")
        let item = SearchItem(id: SearchItemID("PR_subject"), repo: repo, number: 42, kind: .pullRequest,
                              title: "PR", state: .open, author: sarah, updatedAt: t0 + 0.123456,
                              htmlURL: URL(string: "https://github.com/acme/web/pull/42")!)
        let detail = SearchSubjectDetail(id: item.id, title: item.title, state: item.state, author: item.author,
                                         htmlURL: item.htmlURL, items: [comment("c", by: sarah, at: t0 + 0.333333)],
                                         checks: nil, fetchedAt: t0 + 0.987654)
        let subject = StoredSearchSubject(item: item, seenThrough: t0 - 0.123456,
                                          dismissedThrough: item.updatedAt, lastVisitAt: t0 - 0.765432, detail: detail)
        let cache = StoredCustomSectionPage(
            page: SearchPage(items: [item], totalCount: 1042, incompleteResults: true, nextPage: 2),
            refreshedAt: t0 + 0.234567, baselinesNewItems: true)
        do {
            let db = try GitokenDatabase.onDisk(at: url)
            try db.saveCustomSection(cache, section: section, subjects: [subject], account: account)
        }
        let reopened = try GitokenDatabase.onDisk(at: url)
        #expect(try reopened.searchSubjectStates(for: account) == [item.id: subject])
        #expect(try reopened.customSectionCache(for: section, account: account) == cache)
        let other = AccountKey(login: "other")
        #expect(try reopened.searchSubjectStates(for: other).isEmpty)
        #expect(try reopened.customSectionCache(for: section, account: other) == nil)
        var edited = section
        edited.query += " state:closed"
        #expect(try reopened.customSectionCache(for: edited, account: account) == nil)
        try reopened.pruneCustomSectionCaches(keeping: [edited])
        #expect(try reopened.customSectionCache(for: section, account: account) == nil)
        #expect(try reopened.searchSubjectStates(for: account) == [item.id: subject], "Edits drop results, not subject history")
        #expect(try reopened.threads(for: account).isEmpty)
    }
}
