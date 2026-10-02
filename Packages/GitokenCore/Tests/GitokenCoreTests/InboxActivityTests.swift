import Foundation
import Testing
@testable import GitokenCore

@Suite struct InboxActivityTests {
    func detail(_ items: [TimelineItem]) -> ThreadDetail {
        ThreadDetail(
            threadID: ThreadID("1"), title: "PR", state: .open, author: sarah, htmlURL: URL(string: "https://github.com/acme/web/pull/1")!,
            items: items, checks: nil, fetchedAt: t0)
    }

    @Test func previewDescribesNewestActivityNotByViewer() {
        let d = detail([
            comment("c1", by: sarah, at: t0 - 300),
            review("r1", by: omar, at: t0 - 200, .changesRequested, comments: [
                reviewComment("rc1", databaseID: 1, by: omar, at: t0 - 200, "Please   rename\nthis"),
            ]),
            comment("c2", by: me, at: t0 - 100, "Will do"),
        ])
        #expect(ActivityAnalysis.preview(of: d, viewer: me)
            == ActivityPreview(actor: omar, verb: .requestedChanges, snippet: "Please rename this", at: t0 - 200))
    }

    @Test func previewFallsBackToViewerWhenNobodyElseActed() {
        let d = detail([comment("c1", by: me, at: t0, "Opening thoughts")])
        #expect(ActivityAnalysis.preview(of: d, viewer: me)?.actor == me)
    }

    @Test func mentionsMatchWholeHandlesOnly() {
        #expect(ActivityAnalysis.mentions(me, in: "@akim can you look?"))
        #expect(ActivityAnalysis.mentions(me, in: "thoughts, @AKIM."))
        #expect(!ActivityAnalysis.mentions(me, in: "cc @akimbo"))
        #expect(!ActivityAnalysis.mentions(me, in: "mail team@akim"))
        #expect(!ActivityAnalysis.mentions(me, in: "ping @akim-bot"))

        let d = detail([comment("c1", by: sarah, at: t0, "@akim what do you think?")])
        #expect(ActivityAnalysis.preview(of: d, viewer: me)?.verb == .mentioned)
    }

    @Test func failedChecksNameTheFailures() {
        let checks = CheckSummary(status: .failure, commitSHA: "abc", failedChecks: ["lint", "e2e"], passedCount: 3, pendingCount: 0)
        let d = detail([TimelineItem(id: "k", actor: ciBot, createdAt: t0, payload: .checks(checks), url: nil)])
        #expect(ActivityAnalysis.preview(of: d, viewer: me) == ActivityPreview(actor: ciBot, verb: .checksFailed, snippet: "lint, e2e", at: t0))
    }

    @Test func actorsAreLastThreeDistinctHumansOtherThanViewerNewestLast() {
        let d = detail([
            comment("1", by: sarah, at: t0 - 7), comment("2", by: omar, at: t0 - 6), comment("3", by: ciBot, at: t0 - 5),
            comment("4", by: me, at: t0 - 4), comment("5", by: lea, at: t0 - 3), comment("6", by: sarah, at: t0 - 2),
            comment("7", by: nina, at: t0 - 1),
        ])
        #expect(ActivityAnalysis.actors(in: d, viewer: me) == [lea, sarah, nina])
    }

    @Test func unseenCountCountsOthersAfterLastVisit() {
        var row = TrackedThread(thread: makeThread("1", updatedAt: t0))
        row.lastVisitAt = t0 - 250
        row.absorb(detail([
            comment("old", by: sarah, at: t0 - 300), comment("mine", by: me, at: t0 - 200),
            comment("new", by: omar, at: t0 - 100), TimelineItem(id: "ci", actor: ciBot, createdAt: t0 - 50,
                payload: .checks(CheckSummary(status: .success, commitSHA: "a", failedChecks: [], passedCount: 4, pendingCount: 0)), url: nil),
        ]), viewer: me, includeAI: true)
        #expect(row.unseenCount == 2)
        #expect(row.preview?.verb == .checksPassed)
        #expect(row.actors == [sarah, omar])
    }

    @Test func longSnippetsAreCollapsedAndTruncated() throws {
        let text = String(repeating: "word ", count: 100)
        let snippet = try #require(ActivityAnalysis.snippet(text))
        #expect(snippet.count == ActivityAnalysis.maxSnippetLength)
        #expect(snippet.hasSuffix("…"))
        #expect(ActivityAnalysis.snippet(" \n\t ") == nil)
    }
}
