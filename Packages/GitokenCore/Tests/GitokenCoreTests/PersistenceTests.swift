import Foundation
import GRDB
import Testing
@testable import GitokenCore

@Suite struct PersistenceTests {
    let account = AccountKey(login: "akim")

    func fullyPopulatedRow() -> TrackedThread {
        // Sub-millisecond fractions catch lossy date storage, which would break `updatedAt` comparisons.
        var row = TrackedThread(thread: makeThread("42", updatedAt: t0 + 0.123456, lastReadAt: t0 - 99.5))
        row.state = .merged
        row.preview = ActivityPreview(actor: sarah, verb: .approved, snippet: "Ship it", at: t0 - 1.000_25)
        row.actors = [omar, sarah]
        row.unseenCount = 4
        row.seenThrough = t0 - 0.000_7
        row.lastVisitAt = t0 - 3600.5
        row.doneAt = t0 + 10.9
        row.snoozedUntil = t0 + 1800.333
        row.resurfaced = .snoozeEnded
        row.hydratedThrough = t0 - 0.25
        row.keptLocally = true
        return row
    }

    @Test func onDiskDatabaseCreatesItsDirectoryAndRoundTripsRowsExactly() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gitoken-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "nested/gitoken.sqlite")
        let row = fullyPopulatedRow()
        let detail = ThreadDetail(
            threadID: row.id, title: "PR 42", state: .open, author: sarah, htmlURL: row.thread.htmlURL,
            items: [comment("c1", by: sarah, at: t0 - 0.5)], checks: nil, fetchedAt: t0 + 0.75)

        do {
            let db = try GitokenDatabase.onDisk(at: url)
            try db.save([row], for: account)
            try db.save(detail, for: account)
        }

        let reopened = try GitokenDatabase.onDisk(at: url)
        #expect(try reopened.threads(for: account) == [row])
        #expect(try reopened.detail(for: row.id, account: account) == detail)
    }

    @Test func rowsAreScopedToTheirAccount() throws {
        let db = try GitokenDatabase.inMemory()
        let other = AccountKey(host: "github.com", login: "someone-else")
        try db.save([fullyPopulatedRow()], for: account)
        #expect(try db.threads(for: other).isEmpty)

        var updated = fullyPopulatedRow()
        updated.doneAt = nil
        try db.save([updated], for: account)
        #expect(try db.threads(for: account) == [updated], "saving again updates in place")

        try db.deleteThreads([updated.id], for: account)
        #expect(try db.threads(for: account).isEmpty)
    }

    @Test func appStateRoundTripsQuietBookkeeping() throws {
        let db = try GitokenDatabase.inMemory()
        #expect(try db.appState() == nil)

        var state = PersistedAppState()
        state.settings = AppSettings(appearance: .fluid, motion: .reduced, display: .pill,
                                     quietHours: QuietHours(enabled: true, start: .init(hour: 23, minute: 30), end: .init(hour: 7, minute: 15)),
                                     launchAtLogin: true)
        state.manualQuiet = true
        state.globalSnoozeUntil = t0 + 0.5
        state.lastModified = "Fri, 02 Oct 2026 13:59:00 GMT"
        state.viewer = me
        state.collected = CollectedActivity(updates: 5, groupIDs: [ThreadID("1"), ThreadID("2")], actors: [sarah, lea])
        state.collectedReason = .quietHours(until: .init(hour: 7, minute: 15))
        try db.save(state)
        #expect(try db.appState() == state)

        state.collectedReason = .globalSnooze(until: t0 + 1800)
        state.viewer = nil
        try db.save(state)
        #expect(try db.appState() == state, "single row is overwritten")
    }

    @Test func richBodiesMigrationDropsOldDetailsAndCleansSnippets() throws {
        let queue = try DatabaseQueue()
        try GitokenDatabase.migrator.migrate(queue, upTo: "v1")
        var row = fullyPopulatedRow()
        row.hydratedThrough = row.thread.updatedAt
        row.preview = ActivityPreview(
            actor: sarah, verb: .reviewed, snippet: "<!-- ccr-overview-v2 --> ## Copilot review overview **Findings:** 1", at: t0)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO threadDetail (accountHost, accountLogin, threadID, detail, fetchedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [account.host, account.login, row.id.rawValue, #"{"items":[{"payload":{"comment":{"body":"raw"}}}]}"#, 0])
        }
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO thread (accountHost, accountLogin, id, thread, updatedAt, unread, state, preview, actors,
                unseenCount, hydratedThrough, keptLocally) VALUES (?, ?, ?, ?, ?, 1, 'open', ?, '[]', 0, ?, 0)
                """,
                arguments: [
                    account.host, account.login, row.id.rawValue,
                    String(decoding: try JSONEncoder().encode(row.thread), as: UTF8.self),
                    row.thread.updatedAt.timeIntervalSinceReferenceDate,
                    String(decoding: try JSONEncoder().encode(row.preview), as: UTF8.self),
                    row.thread.updatedAt.timeIntervalSinceReferenceDate,
                ])
        }

        let db = try GitokenDatabase(queue: queue)
        #expect(try db.detail(for: row.id, account: account) == nil, "old-shape timelines are dropped, not decoded")
        let migrated = try #require(try db.threads(for: account).first)
        #expect(migrated.hydratedThrough == nil, "rows re-hydrate to rebuild previews from rich bodies")
        #expect(migrated.preview?.snippet == "Copilot review overview Findings: 1")
        #expect(migrated.preview?.actor == sarah)
    }
}
