import Foundation
import Testing
@testable import GitokenCore

@MainActor
@Suite struct AIReviewTests {
    let copilot = Actor(login: "copilot-pull-request-reviewer", name: "Copilot", isBot: true)
    let one = ThreadID("1")

    @Test func reviewersMatchByLoginWithOrWithoutBotSuffix() {
        #expect(AIReviewers.isAI(Actor(login: "copilot-pull-request-reviewer")))
        #expect(AIReviewers.isAI(Actor(login: "CodeRabbitAI[bot]", isBot: true)))
        #expect(AIReviewers.isAI(Actor(login: "gemini-code-assist[bot]")))
        #expect(AIReviewers.isAI(Actor(login: "Copilot", isBot: true)))
        #expect(AIReviewers.isAI(Actor(login: "cursor[bot]")))
        #expect(!AIReviewers.isAI(Actor(login: "copilot")), "a human named copilot is not an AI reviewer")
        #expect(!AIReviewers.isAI(Actor(login: "cursor")))
        #expect(!AIReviewers.isAI(Actor(login: "github-actions", isBot: true)))
        #expect(!AIReviewers.isAI(Actor(login: "coderabbitai-fan")))
    }

    @Test func aiOnlyActivityIsNotAnnouncedAndKeepsTheHumanPreviewWhenNotifyIsOff() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600, items: [comment("c1", by: sarah, at: t0 - 600, "Please rename this")])
        await h.store.refresh()
        let before = try #require(h.group("1")?.preview)

        h.clock.advance(by: 60)
        h.github.activity(on: "1", review("ai", by: copilot, at: h.now, .commented))
        await h.store.refresh()

        #expect(h.store.arrival == nil)
        let group = try #require(h.group("1"))
        #expect(group.preview == before)
        #expect(group.actors == [sarah])
        #expect(group.unseenCount == 1, "only the human comment counts")
        #expect(group.bucket(at: h.now) == .new, "GitHub's unread state still puts it in New")

        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c2", by: omar, at: h.now, "Looks fine to me"))
        await h.store.refresh()
        #expect(h.store.arrival?.groupID == one, "human activity still announces")
        #expect(h.store.arrival?.updateCount == 1)
    }

    @Test func aiActivityBehavesLikeAnyActorWhenNotifyIsOn() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.notifyAIReviews = true }
        h.github.add("1", at: t0 - 600, items: [comment("c1", by: sarah, at: t0 - 600)])
        await h.store.refresh()

        h.clock.advance(by: 60)
        h.github.activity(on: "1", review("ai", by: copilot, at: h.now, .commented))
        await h.store.refresh()

        guard case .activity(let id, let latest, _)? = h.store.arrival?.kind else {
            Issue.record("expected an activity arrival, got \(String(describing: h.store.arrival))")
            return
        }
        #expect(id == one)
        #expect(latest.actor == copilot)
        #expect(h.group("1")?.unseenCount == 2)
    }

    @Test func turningNotifyOffRederivesPreviewsFromCachedTimelines() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.notifyAIReviews = true }
        h.github.add("1", at: t0 - 600, items: [
            comment("c1", by: sarah, at: t0 - 600), review("ai", by: copilot, at: t0 - 300, .commented),
        ])
        await h.store.refresh()
        #expect(h.group("1")?.preview?.actor == copilot)

        h.store.updateSettings { $0.notifyAIReviews = false }
        #expect(h.group("1")?.preview?.actor == sarah)
        #expect(h.group("1")?.unseenCount == 1)
    }

    @Test func openConversationPicksUpNewActivityOnPoll() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600, items: [comment("c1", by: sarah, at: t0 - 600)])
        await h.store.refresh()
        await h.store.openConversation(one)

        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c2", by: omar, at: h.now))
        await h.store.refresh()
        #expect(h.store.conversations[one]?.detail?.items.map(\.id) == ["c1", "c2"])
    }
}
