import Foundation
import Testing
@testable import GitokenCore

private func reviewRequest(_ id: String, of reviewer: Actor, by actor: Actor, at date: Date) -> TimelineItem {
    TimelineItem(id: id, actor: actor, createdAt: date, payload: .event(.reviewRequested, detail: reviewer.login), url: nil)
}

@MainActor
@Suite struct OnlyMyWorkTests {
    /// 1: my PR. 2: a PR I reviewed that GitHub still lists as `review_requested`. 3: a pending review request.
    /// 4: someone else's PR that mentions me. 5: a team mention.
    private func seeded() async throws -> Harness {
        let h = try Harness()
        h.store.updateSettings { $0.onlyMyWork = true }
        h.github.add("1", at: t0 - 600, reason: .author, items: [comment("c1", by: sarah, at: t0 - 600)])
        h.github.update { $0.authors[ThreadID("1")] = me }
        h.github.add("2", at: t0 - 600, items: [review("r2", by: me, at: t0 - 700, .changesRequested)])
        h.github.add("3", at: t0 - 600, items: [reviewRequest("q3", of: me, by: sarah, at: t0 - 600)])
        h.github.add("4", at: t0 - 600, reason: .mention, items: [comment("c4", by: omar, at: t0 - 600, "@akim thoughts?")])
        h.github.add("5", at: t0 - 600, reason: .teamMention, items: [comment("c5", by: omar, at: t0 - 600, "@acme/web")])
        await h.store.refresh()
        return h
    }

    @Test func inboxKeepsOwnPullRequestsReviewedOnesAndMentions() async throws {
        let h = try await seeded()
        #expect(Set(h.store.groups.map(\.id)) == [ThreadID("1"), ThreadID("2"), ThreadID("4")])

        h.store.updateSettings { $0.onlyMyWork = false }
        #expect(h.store.groups.count == 5, "turning it off brings every tracked thread back")
    }

    @Test func ownWorkAnnouncesAnyActivityFromOthers() async throws {
        let h = try await seeded()
        h.clock.advance(by: 60)
        h.github.activity(on: "2", comment("c2", by: sarah, at: h.now, "Fixed, please re-check"))
        await h.store.refresh()
        #expect(h.store.arrival?.groupID == ThreadID("2"))
    }

    @Test func reviewRequestsNeverAnnounce() async throws {
        let h = try await seeded()
        h.clock.advance(by: 60)
        h.github.activity(on: "2", reviewRequest("q2", of: me, by: sarah, at: h.now))
        h.github.activity(on: "3", comment("c3", by: sarah, at: h.now, "Ping"))
        h.github.add("6", at: h.now, items: [reviewRequest("q6", of: me, by: omar, at: h.now)])
        await h.store.refresh()
        #expect(h.store.arrival == nil)
        #expect(h.group("6") == nil)
    }

    @Test func othersThreadsAnnounceOnlyWhenTheNewActivityMentionsMe() async throws {
        let h = try await seeded()
        h.clock.advance(by: 60)
        h.github.activity(on: "4", comment("c4b", by: sarah, at: h.now, "Agreed"))
        await h.store.refresh()
        #expect(h.store.arrival == nil)

        h.clock.advance(by: 60)
        h.github.activity(on: "3", comment("c3", by: sarah, at: h.now, "@akim can you look today?"))
        await h.store.refresh()
        #expect(h.store.arrival?.groupID == ThreadID("3"), "a mention brings a review request in")
        #expect(h.group("3") != nil)
    }

    @Test func reviewingAPendingRequestMakesItOwnWork() async throws {
        let h = try await seeded()
        h.clock.advance(by: 60)
        h.github.activity(on: "3", review("r3", by: me, at: h.now, .approved))
        await h.store.refresh()
        #expect(h.group("3") != nil)

        h.clock.advance(by: 60)
        h.github.activity(on: "3", comment("c3", by: sarah, at: h.now, "Thanks!"))
        await h.store.refresh()
        #expect(h.store.arrival?.groupID == ThreadID("3"))
    }

    @Test func learnedInvolvementSurvivesRelaunch() async throws {
        let h = try await seeded()
        let relaunched = h.relaunched()
        await relaunched.refresh()
        #expect(Set(relaunched.groups.map(\.id)) == [ThreadID("1"), ThreadID("2"), ThreadID("4")])
    }
}
