import Foundation
import Testing
@testable import GitokenCore

@MainActor
@Suite struct InboxStoreTests {
    let one = ThreadID("1")
    let two = ThreadID("2")
    let three = ThreadID("3")

    // MARK: Seen / done

    @Test func groupGoesNewThenPendingThenDoneThenBackToNewOnLaterActivity() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600, items: [comment("c1", by: sarah, at: t0 - 600)])
        await h.store.refresh()
        #expect(h.bucket("1") == .new)
        #expect(h.store.arrival == nil, "the first sync builds the inbox without announcing")

        await h.store.openConversation(one)
        h.store.closeConversation(one)
        #expect(h.bucket("1") == .pending)

        h.store.markDone(one)
        await h.store.waitForPendingSync()
        #expect(h.bucket("1") == .done)
        #expect(h.github.update { $0.markDoneCalls } == [one])
        await h.store.refresh()
        #expect(h.bucket("1") == .done, "GitHub no longer listing a done thread keeps it done")

        h.clock.advance(by: 300)
        h.github.activity(on: "1", comment("c2", by: omar, at: h.now))
        await h.store.refresh()
        let group = try #require(h.group("1"))
        #expect(group.bucket(at: h.now) == .new)
        #expect(group.doneAt == nil)
        #expect(group.resurfaced == .reopenedFromDone)
        guard case .activity(let id, let latest, let reopened)? = h.store.arrival?.kind else {
            Issue.record("expected an activity arrival, got \(String(describing: h.store.arrival))")
            return
        }
        #expect(id == one)
        #expect(reopened)
        #expect(latest.actor == omar)
    }

    @Test func openingMarksSeenOnGitHubButNeverDone() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        h.github.add("2", at: t0 - 500)
        await h.store.refresh()
        #expect(h.store.unseenCount == 2)

        await h.store.openConversation(one)
        #expect(h.store.unseenCount == 1)
        #expect(h.store.pendingCount == 1)
        #expect(h.group("1")?.doneAt == nil)
        #expect(h.github.update { $0.markReadCalls } == [one])
        #expect(h.github.update { $0.markDoneCalls }.isEmpty)

        await h.store.refresh()
        #expect(h.bucket("1") == .pending, "GitHub now reports it read; still not done")
    }

    @Test func markReadFailureKeepsOptimisticSeenAndReportsError() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600, items: [comment("c1", by: sarah, at: t0 - 600)])
        await h.store.refresh()
        h.github.update { $0.markReadError = .http(status: 502, message: "Bad gateway") }

        await h.store.openConversation(one)
        #expect(h.group("1")?.isUnseen == false)
        #expect(h.store.lastSyncError == .http(status: 502, message: "Bad gateway"))

        h.github.update { $0.version += 1 }
        await h.store.refresh()
        #expect(h.bucket("1") == .pending, "GitHub still says unread, but nothing newer than what was seen")

        h.clock.advance(by: 120)
        h.github.activity(on: "1", comment("c2", by: sarah, at: h.now))
        await h.store.refresh()
        #expect(h.bucket("1") == .new, "newer activity beats the optimistic read")
    }

    @Test func threadMissingFromFullListingIsDoneElsewhere() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        h.github.add("2", at: t0 - 500)
        await h.store.refresh()

        h.clock.advance(by: 60)
        h.github.doneElsewhere("2")
        await h.store.refresh()
        #expect(h.bucket("2") == .done)
        #expect(h.group("2")?.doneAt == h.now)
        #expect(h.bucket("1") == .new)
        #expect(h.github.update { $0.markDoneCalls }.isEmpty)
    }

    @Test func undoneGroupSurvivesAbsenceUntilGitHubListsItAgain() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        await h.store.refresh()
        h.store.markDone(one)
        await h.store.waitForPendingSync()
        await h.store.refresh()

        h.store.undoDone(one)
        h.github.update { $0.version += 1 }
        await h.store.refresh()
        #expect(h.group("1")?.doneAt == nil, "GitHub still has it done; the local undo must stick")

        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c2", by: sarah, at: h.now))
        await h.store.refresh()
        h.github.doneElsewhere("1")
        await h.store.refresh()
        #expect(h.bucket("1") == .done, "once listed again, absence means done elsewhere")
    }

    @Test func notModifiedPollKeepsStateAndSendsLastModified() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600, items: [comment("c1", by: sarah, at: t0 - 600)])
        h.github.add("2", at: t0 - 500, unread: false)
        await h.store.refresh()
        let before = h.store.groups
        let detailCalls = h.github.update { $0.detailCalls.count }

        h.clock.advance(by: 60)
        await h.store.refresh()
        #expect(h.github.update { $0.pollLastModified } == [nil, "v2"])
        #expect(h.store.groups == before)
        #expect(h.github.update { $0.detailCalls.count } == detailCalls)
        #expect(h.store.lastSyncAt == h.now)
    }

    @Test func outOfScopeThreadsStayOutButKnownThreadsAreKeptWhenTheirReasonChanges() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600, reason: .mention)
        h.github.add("2", at: t0 - 500, reason: .subscribed)
        await h.store.refresh()
        #expect(h.store.groups.map(\.id) == [one])

        h.clock.advance(by: 60)
        h.github.update {
            $0.listing[one] = makeThread("1", updatedAt: h.now, reason: .subscribed)
            $0.timelines[one] = [comment("c2", by: sarah, at: h.now)]
            $0.version += 1
        }
        await h.store.refresh()
        #expect(h.bucket("1") == .new)
        #expect(h.store.arrival?.groupID == one)
    }

    @Test func hydrationFailureKeepsThreadWithGenericPreview() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        await h.store.refresh()
        h.github.update { $0.detailErrors[one] = .http(status: 502, message: nil) }

        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c2", by: sarah, at: h.now))
        await h.store.refresh()
        let group = try #require(h.group("1"))
        #expect(group.preview == ActivityPreview(actor: nil, verb: .updated, snippet: nil, at: h.now))
        #expect(group.bucket(at: h.now) == .new)
        guard case .activity(_, let latest, _)? = h.store.arrival?.kind else {
            Issue.record("expected an activity arrival")
            return
        }
        #expect(latest.verb == .updated)
    }

    // MARK: Arrivals

    @Test func burstOnOneGroupMergesIntoOneArrival() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        await h.store.refresh()

        var ids: Set<UUID> = []
        for (index, actor) in [sarah, omar, sarah].enumerated() {
            h.clock.advance(by: 20)
            h.github.activity(on: "1", comment("burst-\(index)", by: actor, at: h.now))
            await h.store.refresh()
            ids.insert(try #require(h.store.arrival).id)
        }
        let arrival = try #require(h.store.arrival)
        #expect(ids.count == 1, "merging must not restart the arrival")
        #expect(arrival.updateCount == 3)
        #expect(arrival.actors == [omar, sarah])

        h.store.dismissArrival()
        #expect(h.store.arrival == nil)
    }

    @Test func activityOnAnotherGroupQueuesBehindCurrentArrival() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        h.github.add("2", at: t0 - 600)
        await h.store.refresh()

        h.clock.advance(by: 30)
        h.github.activity(on: "1", comment("a", by: sarah, at: h.now))
        await h.store.refresh()
        let first = try #require(h.store.arrival)

        h.clock.advance(by: 30)
        h.github.activity(on: "2", comment("b", by: omar, at: h.now))
        await h.store.refresh()
        #expect(h.store.arrival == first)

        h.clock.advance(by: 30)
        h.github.activity(on: "2", comment("c", by: lea, at: h.now))
        await h.store.refresh()
        #expect(h.store.arrival?.id == first.id)

        h.store.dismissArrival()
        let second = try #require(h.store.arrival)
        #expect(second.groupID == two)
        #expect(second.updateCount == 2, "queued same-group activity merges too")
        #expect(second.actors == [omar, lea])

        h.store.dismissArrival()
        #expect(h.store.arrival == nil)
    }

    @Test func pollWithSeveralNewItemsCountsOthersActivityAndShowsHumansFirst() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600, items: [comment("old", by: sarah, at: t0 - 600)])
        await h.store.refresh()

        h.github.activity(on: "1", comment("n1", by: sarah, at: t0 - 60))
        h.github.activity(on: "1", comment("mine", by: me, at: t0 - 50))
        h.github.activity(on: "1", comment("bot", by: ciBot, at: t0 - 45))
        h.github.activity(on: "1", comment("n2", by: omar, at: t0 - 40))
        await h.store.refresh()
        let arrival = try #require(h.store.arrival)
        #expect(arrival.updateCount == 3, "only activity by others after the previous update counts")
        #expect(arrival.actors == [sarah, omar], "bots only appear when no human acted")
    }

    // MARK: Quiet

    @Test func quietHoursCollectActivityAndSummarizeWhenTheyEnd() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.quietHours = QuietHours(enabled: true, start: .init(hour: 13, minute: 0), end: .init(hour: 15, minute: 0)) }
        #expect(h.store.quietReason == .quietHours(until: .init(hour: 15, minute: 0)))
        h.github.add("1", at: t0 - 600, unread: false, items: [comment("c0", by: sarah, at: t0 - 600)])
        h.github.add("2", at: t0 - 600, unread: false)
        await h.store.refresh()
        await h.store.openConversation(one)
        h.store.closeConversation(one)
        #expect(h.store.unseenCount == 0)

        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("q1", by: sarah, at: h.now))
        await h.store.refresh()
        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("q2", by: omar, at: h.now))
        h.github.activity(on: "2", comment("q3", by: lea, at: h.now))
        await h.store.refresh()

        #expect(h.store.arrival == nil)
        #expect(h.group("1")?.unseenCount == 2)
        #expect(h.store.unseenCount == 2)

        h.advance(minutes: 50)
        #expect(h.store.quietReason == .quietHours(until: .init(hour: 15, minute: 0)))
        #expect(h.store.arrival == nil)
        h.advance(minutes: 10)
        #expect(h.store.quietReason == nil)
        let summary = try #require(h.store.arrival)
        #expect(summary.kind == .summary(
            updates: 3, groups: 2, actors: [sarah, omar, lea], endedReason: .quietHours(until: .init(hour: 15, minute: 0))))

        h.store.dismissArrival()
        h.advance(minutes: 1)
        #expect(h.store.arrival == nil, "the summary is published once")
    }

    @Test func globalSnoozeTakesPrecedenceOverManualQuiet() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        await h.store.refresh()

        h.store.setManualQuiet(true)
        h.store.snoozeAll(.oneHour)
        #expect(h.store.quietReason == .globalSnooze(until: t0 + 3600))

        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("a", by: sarah, at: h.now))
        await h.store.refresh()
        #expect(h.store.arrival == nil)

        h.advance(minutes: 60)
        #expect(h.store.globalSnoozeUntil == nil)
        #expect(h.store.quietReason == .manual)
        #expect(h.store.arrival == nil, "still quiet: manual quiet outlives the global snooze")

        h.store.setManualQuiet(false)
        #expect(h.store.arrival?.kind == .summary(updates: 1, groups: 1, actors: [sarah], endedReason: .manual))
    }

    @Test func endingGlobalSnoozeEarlySummarizesAndQueuedArrivalsFoldIntoIt() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        h.github.add("2", at: t0 - 600)
        await h.store.refresh()
        h.clock.advance(by: 30)
        h.github.activity(on: "1", comment("a", by: sarah, at: h.now))
        h.github.activity(on: "2", comment("b", by: omar, at: h.now))
        await h.store.refresh()
        #expect(h.store.arrival != nil)

        h.store.snoozeAll(.thirtyMinutes)
        #expect(h.store.arrival == nil, "no arrivals while quiet")
        h.store.endGlobalSnooze()
        let until = t0 + 30 + 30 * 60
        let summary = try #require(h.store.arrival)
        #expect(summary.kind == .summary(updates: 1, groups: 1, actors: [omar], endedReason: .globalSnooze(until: until)),
                "the arrival on screen was already shown; the waiting one is summarized")
    }

    // MARK: Snooze

    @Test func groupSnoozeHidesActivityUntilExpiryThenResurfaces() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        await h.store.refresh()

        h.store.snooze(one, .thirtyMinutes)
        #expect(h.bucket("1") == .snoozed)
        #expect(h.store.unseenCount == 0)

        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("a", by: sarah, at: h.now))
        await h.store.refresh()
        #expect(h.store.arrival == nil)
        #expect(h.bucket("1") == .snoozed)

        h.advance(minutes: 28)
        #expect(h.bucket("1") == .snoozed)
        #expect(h.store.arrival == nil)

        h.advance(minutes: 2)
        let group = try #require(h.group("1"))
        #expect(group.bucket(at: h.now) == .new)
        #expect(group.snoozedUntil == nil)
        #expect(group.resurfaced == .snoozeEnded)
        #expect(h.store.arrival?.kind == .snoozeEnded(groupID: one))
    }

    @Test func snoozeExpiringDuringQuietResurfacesWithoutArrival() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        await h.store.refresh()
        h.store.snooze(one, .thirtyMinutes)
        h.store.setManualQuiet(true)

        h.advance(minutes: 31)
        #expect(h.group("1")?.resurfaced == .snoozeEnded)
        #expect(h.store.arrival == nil)
    }

    // MARK: Auth

    @Test func authErrorsBlockUntilRefreshSucceeds() async throws {
        let h = try Harness()
        h.github.update { $0.viewer = .failure(.auth(.notLoggedIn(detail: "no oauth token"))) }
        await h.store.refresh()
        #expect(h.store.phase == .blocked(.notLoggedIn(detail: "no oauth token")))
        #expect(h.github.update { $0.pollLastModified }.isEmpty)

        h.github.update { $0.viewer = .success(me) }
        h.github.add("1", at: t0 - 600)
        await h.store.refresh()
        #expect(h.store.phase == .ready(viewer: me))
        #expect(h.store.groups.count == 1)

        h.github.update { $0.pollError = .auth(.tokenRejected(status: 401, scopes: nil)) }
        await h.store.refresh()
        #expect(h.store.phase == .blocked(.tokenRejected(status: 401, scopes: nil)))
        #expect(h.store.groups.count == 1, "cached inbox stays")
    }

    // MARK: Conversation

    @Test func conversationCapturesPreviousVisitAsBoundary() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600, items: [comment("c1", by: sarah, at: t0 - 600)])
        await h.store.refresh()

        await h.store.openConversation(one)
        #expect(h.store.conversations[one]?.lastVisitAt == nil)
        #expect(h.store.conversations[one]?.detail?.items.map(\.id) == ["c1"])
        #expect(h.store.conversations[one]?.isLoading == false)
        h.store.closeConversation(one)
        let firstVisit = h.now

        h.clock.advance(by: 600)
        h.github.activity(on: "1", comment("c2", by: omar, at: h.now))
        await h.store.refresh()
        #expect(h.group("1")?.unseenCount == 1)

        h.clock.advance(by: 60)
        await h.store.openConversation(one)
        #expect(h.store.conversations[one]?.lastVisitAt == firstVisit)
        h.store.closeConversation(one)
        #expect(h.group("1")?.lastVisitAt == h.now)
        #expect(h.group("1")?.unseenCount == 0)
    }

    @Test func repliesAppendToConversationAndThreadUnderTheirReview() async throws {
        let h = try Harness()
        let parent = reviewComment("rc1", databaseID: 77, by: sarah, at: t0 - 900, "Rename this")
        h.github.add("1", at: t0 - 900, items: [review("r1", by: sarah, at: t0 - 900, .changesRequested, comments: [parent])])
        await h.store.refresh()
        await h.store.openConversation(one)

        try await h.store.reply(to: one, body: "Thanks!", inReplyTo: nil)
        try await h.store.reply(to: one, body: "Done", inReplyTo: parent)

        let items = try #require(h.store.conversations[one]?.detail?.items)
        #expect(items.count == 2)
        #expect(items.last?.payload == .comment(body: "Thanks!"))
        guard case .review(_, _, let comments) = items.first?.payload else {
            Issue.record("expected the review first")
            return
        }
        #expect(comments.map(\.body) == ["Rename this", "Done"])

        h.github.update { $0.postError = .http(status: 403, message: "Locked") }
        await #expect(throws: GitHubError.http(status: 403, message: "Locked")) {
            try await h.store.reply(to: one, body: "Hello?", inReplyTo: nil)
        }
        #expect(h.store.conversations[one]?.detail?.items.count == 2)
    }

    // MARK: Persistence

    @Test func stateSurvivesRelaunch() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        h.github.add("2", at: t0 - 500)
        h.github.add("3", at: t0 - 400)
        await h.store.refresh()

        await h.store.openConversation(one)
        h.store.closeConversation(one)
        h.store.markDone(two)
        await h.store.waitForPendingSync()
        h.store.snooze(three, .oneHour)
        h.store.updateSettings {
            $0 = AppSettings.preset(.fluid, keeping: $0)
            $0.display = .pill
            $0.quietHours.enabled = false
        }
        h.store.setManualQuiet(true)
        h.store.snoozeAll(.untilTomorrow)

        let relaunched = h.relaunched()
        #expect(relaunched.phase == .ready(viewer: me))
        #expect(relaunched.groups == h.store.groups)
        #expect(relaunched.groups.first { $0.id == one }?.lastVisitAt == t0)
        #expect(relaunched.groups.first { $0.id == two }?.doneAt == t0)
        #expect(relaunched.groups.first { $0.id == three }?.snoozedUntil == t0 + 3600)
        #expect(relaunched.settings == h.store.settings)
        #expect(relaunched.settings.appearance == .fluid)
        #expect(relaunched.manualQuiet)
        #expect(relaunched.globalSnoozeUntil == utc.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9)))
        #expect(relaunched.quietReason == h.store.quietReason)

        await relaunched.refresh()
        #expect(h.github.update { $0.pollLastModified }.last == "v3", "Last-Modified survives the relaunch")
    }

    @Test func activityCollectedBeforeQuitIsSummarizedAfterRelaunchOnceQuietIsOver() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        await h.store.refresh()
        h.store.snoozeAll(.thirtyMinutes)
        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("a", by: sarah, at: h.now))
        await h.store.refresh()

        h.clock.advance(by: 3600)
        let relaunched = h.relaunched()
        #expect(relaunched.arrival?.kind == .summary(
            updates: 1, groups: 1, actors: [sarah], endedReason: .globalSnooze(until: t0 + 1800)))
    }
}
