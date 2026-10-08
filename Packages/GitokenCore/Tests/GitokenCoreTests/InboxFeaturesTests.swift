import Foundation
import GRDB
import Testing
@testable import GitokenCore

private let api = RepoRef(owner: "acme", name: "api")
private let cli = RepoRef(owner: "tools", name: "cli")
private let docs = RepoRef(owner: "other", name: "docs")
/// 13:00–15:00 UTC; `t0` (14:00) is inside.
private let afternoonQuiet = QuietHours(enabled: true, start: .init(hour: 13, minute: 0), end: .init(hour: 15, minute: 0))

@MainActor
@Suite struct MuteTests {
    @Test func repositoryRuleHidesGroupFromInboxCountsAndArrivals() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        h.github.add("2", at: t0 - 600, repo: api)
        await h.store.refresh()
        #expect(h.store.unseenCount == 2)

        h.store.mute(.repository("ACME/web"))
        h.github.update { $0.detailCalls = [] }
        #expect(h.store.groups.map(\.id) == [ThreadID("2")])
        #expect(h.store.unseenCount == 1)

        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("m1", by: sarah, at: h.now))
        await h.store.refresh()
        #expect(h.store.arrival == nil, "muted activity never arrives")
        #expect(h.store.unseenCount == 1)
        #expect(!h.github.update { $0.detailCalls }.contains(ThreadID("1")), "muted groups aren't hydrated")

        h.github.activity(on: "2", comment("a1", by: omar, at: h.now))
        await h.store.refresh()
        #expect(h.store.arrival?.groupID == ThreadID("2"))
    }

    @Test func organizationAndReasonRulesMatchOnlyTheirGroups() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        h.github.add("2", at: t0 - 500, reason: .mention, repo: api)
        h.github.add("3", at: t0 - 400, repo: cli)
        h.github.add("4", at: t0 - 300, reason: .mention, repo: cli)
        await h.store.refresh()

        h.store.mute(.organization("acme"))
        #expect(Set(h.store.groups.map(\.id)) == [ThreadID("3"), ThreadID("4")])
        h.store.mute(.reason(.mention))
        #expect(h.store.groups.map(\.id) == [ThreadID("3")])
        #expect(h.store.settings.muteRules == [.organization("acme"), .reason(.mention)])
    }

    @Test func mutingDropsTheArrivalOnScreenAndUnmutingRestoresTheGroupAsGitHubHasIt() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600, items: [comment("c0", by: sarah, at: t0 - 600)])
        await h.store.refresh()
        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c1", by: omar, at: h.now))
        await h.store.refresh()
        #expect(h.store.arrival?.groupID == ThreadID("1"))

        h.store.mute(.repository("acme/web"))
        #expect(h.store.arrival == nil)
        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c2", by: lea, at: h.now))
        await h.store.refresh()
        #expect(h.store.groups.isEmpty)

        h.store.unmute(.repository("acme/web"))
        let group = try #require(h.group("1"))
        #expect(group.bucket(at: h.now) == .new)
        #expect(h.store.arrival == nil, "unmuting restores the group without replaying what happened while muted")

        h.github.update { $0.detailCalls = [] }
        await h.store.refresh()
        #expect(h.github.update { $0.detailCalls } == [ThreadID("1")], "the next poll catches the timeline up")
        #expect(h.group("1")?.preview?.actor == lea)
    }

    @Test func activityOnGroupsMutedWhileQuietIsLeftOutOfTheSummary() async throws {
        let h = try Harness()
        h.store.setManualQuiet(true)
        h.github.add("1", at: t0 - 600)
        h.github.add("2", at: t0 - 600, repo: api)
        await h.store.refresh()
        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("q1", by: sarah, at: h.now))
        h.github.activity(on: "2", comment("q2", by: omar, at: h.now))
        await h.store.refresh()

        h.store.mute(.repository("acme/api"))
        h.clock.advance(by: 60)
        h.github.activity(on: "2", comment("q3", by: lea, at: h.now))
        await h.store.refresh()
        h.store.setManualQuiet(false)
        guard case .summary(let updates, let groups, _, _)? = h.store.arrival?.kind else {
            Issue.record("expected a summary, got \(String(describing: h.store.arrival))")
            return
        }
        #expect(updates == 1)
        #expect(groups == 1)
    }

    @Test func rulesSurviveRelaunch() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600)
        await h.store.refresh()
        h.store.mute(.reason(.reviewRequested))
        #expect(h.relaunched().groups.isEmpty)
    }
}

@MainActor
@Suite struct NotificationTypeTests {
    @Test(arguments: NotificationReason.allCases)
    func reasonAllowlistAndMuteRulesAreIndependentPresentationGates(_ reason: NotificationReason) {
        let thread = makeThread("1", updatedAt: t0, reason: reason)
        var settings = AppSettings()
        #expect(settings.presents(thread))
        settings.enabledNotificationReasons.remove(reason)
        #expect(!settings.presents(thread))
        settings.enabledNotificationReasons.insert(reason)
        settings.muteRules = [.repository(repo.fullName)]
        #expect(!settings.presents(thread))
        settings.muteRules = []
        #expect(settings.presents(thread))
    }

    @Test func excludedActivityStaysTrackedAcrossPollsAndRelaunchWithoutGitHubWrites() async throws {
        let h = try Harness()
        let id = ThreadID("1")
        h.store.updateSettings { $0.enabledNotificationReasons.remove(.mention) }
        h.github.add("1", at: t0 - 600, reason: .mention, items: [comment("c0", by: sarah, at: t0 - 600)])
        await h.store.refresh()
        #expect(h.store.groups.isEmpty)
        #expect(h.store.unseenCount == 0)
        #expect(h.store.pendingCount == 0)
        #expect(h.github.update { $0.detailCalls }.isEmpty)

        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c1", by: lea, at: h.now))
        await h.store.refresh()
        #expect(h.store.arrival == nil)
        let tracked = try #require(try h.database.threads(for: AccountKey(login: me.login)).first)
        #expect(tracked.thread.unread)
        #expect(tracked.thread.updatedAt == h.now)
        #expect(tracked.doneAt == nil)
        #expect(tracked.needsHydration)
        #expect(h.github.update { $0.markReadCalls }.isEmpty)
        #expect(h.github.update { $0.markDoneCalls }.isEmpty)

        let relaunched = h.relaunched()
        #expect(relaunched.groups.isEmpty)
        relaunched.updateSettings { $0.enabledNotificationReasons.insert(.mention) }
        #expect(relaunched.groups.map(\.id) == [id])
        #expect(relaunched.unseenCount == 1)
        #expect(relaunched.arrival == nil, "re-enabling does not replay excluded arrivals")
        await relaunched.refresh()
        #expect(relaunched.groups.first?.preview?.actor == lea)
        #expect(h.github.update { $0.detailCalls } == [id])
        #expect(relaunched.arrival == nil)
    }

    @Test func disablingTypesImmediatelyPrunesCurrentAndQueuedArrivals() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600, reason: .mention)
        h.github.add("2", at: t0 - 600, reason: .mention)
        h.github.add("3", at: t0 - 600)
        await h.store.refresh()
        h.clock.advance(by: 60)
        for id in ["1", "2", "3"] {
            h.github.activity(on: id, comment("c\(id)", by: sarah, at: h.now))
        }
        await h.store.refresh()
        #expect(h.store.arrival?.groupID == ThreadID("1"))
        h.store.updateSettings { $0.enabledNotificationReasons.remove(.mention) }
        #expect(h.store.arrival?.groupID == ThreadID("3"))
        #expect(h.store.groups.map(\.id) == [ThreadID("3")])
        h.store.dismissArrival()
        #expect(h.store.arrival == nil)
        h.store.updateSettings { $0.enabledNotificationReasons.insert(.mention) }
        #expect(h.store.unseenCount == 3)
        #expect(h.store.arrival == nil)
    }

    @Test func filteringQuietActivityPrunesCountsAndActorsAcrossRelaunch() async throws {
        let h = try Harness()
        h.store.setManualQuiet(true)
        h.github.add("1", at: t0 - 600, reason: .mention)
        h.github.add("2", at: t0 - 600)
        await h.store.refresh()
        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c1", by: sarah, at: h.now))
        h.github.activity(on: "2", comment("c2", by: omar, at: h.now))
        await h.store.refresh()
        h.store.updateSettings { $0.enabledNotificationReasons.remove(.mention) }
        let relaunched = h.relaunched()
        relaunched.setManualQuiet(false)
        guard case .summary(let updates, let groups, let actors, _)? = relaunched.arrival?.kind else {
            Issue.record("expected the retained group's summary")
            return
        }
        #expect(updates == 1)
        #expect(groups == 1)
        #expect(actors == [omar])
    }

    @Test func filteringOvernightActivityPrunesMorningSummary() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.quietHours = afternoonQuiet }
        h.github.add("1", at: t0 - 600, reason: .mention, repo: api)
        h.github.add("2", at: t0 - 600)
        await h.store.refresh()
        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c1", by: sarah, at: h.now))
        h.github.activity(on: "2", comment("c2", by: omar, at: h.now))
        await h.store.refresh()
        h.store.updateSettings { $0.enabledNotificationReasons.remove(.mention) }
        h.advance(minutes: 59)
        guard case .morningSummary(let summary)? = h.store.arrival?.kind else {
            Issue.record("expected the retained group's morning summary")
            return
        }
        #expect(summary.updates == 1)
        #expect(summary.conversations == 1)
        #expect(summary.topRepos == [.init(repo: repo, updates: 1)])
        #expect(summary.actors == [omar])
        h.store.updateSettings { $0.enabledNotificationReasons.remove(.reviewRequested) }
        #expect(h.store.arrival == nil, "an already published summary is pruned too")
    }

    @Test func snoozeExpiryAndAIReanalysisDoNotBypassTheReasonFilter() async throws {
        let h = try Harness()
        let ai = Actor(login: "copilot-pull-request-reviewer", isBot: true)
        h.github.add("1", at: t0 - 600, reason: .mention, items: [
            comment("c0", by: sarah, at: t0 - 600),
            review("ai", by: ai, at: t0 - 300, .commented),
        ])
        await h.store.refresh()
        h.store.snooze(ThreadID("1"), .thirtyMinutes)
        h.store.updateSettings {
            $0.enabledNotificationReasons.remove(.mention)
            $0.notifyAIReviews = true
        }
        h.advance(minutes: 31)
        #expect(h.store.groups.isEmpty)
        #expect(h.store.arrival == nil)
        h.store.updateSettings { $0.enabledNotificationReasons.insert(.mention) }
        #expect(h.group("1")?.preview?.actor == ai)
        #expect(h.bucket("1") == .new)
        #expect(h.group("1")?.resurfaced == .snoozeEnded)
        #expect(h.store.arrival == nil)
    }

    @Test func pollingAppliesAChangedReasonWithoutDiscardingTheTrackedThread() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.enabledNotificationReasons.remove(.mention) }
        h.github.add("1", at: t0 - 600)
        await h.store.refresh()
        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c1", by: sarah, at: h.now))
        await h.store.refresh()
        #expect(h.store.arrival != nil)
        h.github.add("1", at: h.now, reason: .mention)
        await h.store.refresh()
        #expect(h.store.groups.isEmpty)
        #expect(h.store.arrival == nil)
        h.github.add("1", at: h.now, reason: .reviewRequested)
        await h.store.refresh()
        #expect(h.store.unseenCount == 1)
        #expect(h.store.arrival == nil)
        #expect(try h.database.threads(for: AccountKey(login: me.login)).count == 1)
    }
}

@MainActor
@Suite struct NotificationSummaryFilterTests {
    @Test func publishedSummarySurvivesUnrelatedExclusionsButDropsWhenItsTypeIsExcluded() async throws {
        let h = try Harness()
        h.github.add("1", at: t0 - 600, reason: .mention)
        h.github.add("2", at: t0 - 600)
        await h.store.refresh()
        h.store.setManualQuiet(true)
        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c1", by: sarah, at: h.now))
        await h.store.refresh()
        h.store.setManualQuiet(false)
        let summary = try #require(h.store.arrival)

        h.store.updateSettings { $0.enabledNotificationReasons.remove(.reviewRequested) }
        #expect(h.store.arrival == summary, "an unrelated hidden thread must not discard the summary")
        h.clock.advance(by: 60)
        h.github.activity(on: "2", comment("c2", by: omar, at: h.now))
        await h.store.refresh()
        #expect(h.store.arrival == summary, "subsequent polling preserves unrelated summaries")
        h.store.updateSettings { $0.enabledNotificationReasons.remove(.mention) }
        #expect(h.store.arrival == nil)
    }

    @Test(arguments: [false, true])
    func publishedMixedSummaryRetainsAllowedActivityWithoutReplayingTheAnnouncement(_ morning: Bool) async throws {
        let h = try Harness()
        if morning {
            h.store.updateSettings { $0.quietHours = afternoonQuiet }
        } else {
            h.store.setManualQuiet(true)
        }
        h.github.add("1", at: t0 - 600, reason: .mention, repo: api)
        h.github.add("2", at: t0 - 600)
        await h.store.refresh()
        h.clock.advance(by: 60)
        h.github.activity(on: "1", comment("c1", by: sarah, at: h.now))
        h.github.activity(on: "2", comment("c2", by: omar, at: h.now))
        await h.store.refresh()
        if morning {
            h.advance(minutes: 59)
        } else {
            h.store.setManualQuiet(false)
        }
        let before = try #require(h.store.arrival)
        h.store.updateSettings { $0.enabledNotificationReasons.remove(.mention) }
        let retained = try #require(h.store.arrival)
        #expect(retained.id == before.id)
        #expect(retained.actors == [omar])
        if morning {
            #expect(retained.kind == .morningSummary(MorningSummary(
                updates: 1, conversations: 1, topRepos: [.init(repo: repo, updates: 1)], actors: [omar])))
        } else {
            #expect(retained.kind == .summary(updates: 1, groups: 1, actors: [omar], endedReason: .manual))
        }
    }
}

@MainActor
@Suite struct MorningSummaryTests {
    /// Quiet 13:00–15:00 with activity on five conversations in four repositories, collected at 14:01.
    private func collectAcrossRepos() async throws -> Harness {
        let h = try Harness()
        h.store.updateSettings { $0.quietHours = afternoonQuiet }
        h.github.add("1", at: t0 - 600)
        h.github.add("2", at: t0 - 600)
        h.github.add("3", at: t0 - 600, repo: api)
        h.github.add("4", at: t0 - 600, repo: cli)
        h.github.add("5", at: t0 - 600, repo: docs)
        await h.store.refresh()
        h.clock.advance(by: 60)
        let at = h.now
        h.github.update { s in
            s.timelines[ThreadID("1"), default: []] += [comment("a", by: sarah, at: at), comment("b", by: omar, at: at)]
            s.timelines[ThreadID("3"), default: []] += [comment("c", by: lea, at: at), comment("d", by: nina, at: at)]
        }
        h.github.activity(on: "1", comment("e", by: sarah, at: at))
        h.github.activity(on: "2", comment("f", by: omar, at: at))
        h.github.activity(on: "3", comment("g", by: lea, at: at))
        h.github.activity(on: "4", comment("h", by: nina, at: at))
        h.github.activity(on: "5", comment("i", by: nina, at: at))
        await h.store.refresh()
        #expect(h.store.arrival == nil)
        return h
    }

    @Test func groupsOvernightActivityByRepoAndPublishesOnce() async throws {
        let h = try await collectAcrossRepos()

        h.advance(minutes: 58)
        #expect(h.store.arrival == nil)
        h.advance(minutes: 1)
        guard case .morningSummary(let summary)? = h.store.arrival?.kind else {
            Issue.record("expected a morning summary, got \(String(describing: h.store.arrival))")
            return
        }
        #expect(summary.updates == 9)
        #expect(summary.conversations == 5)
        #expect(summary.topRepos == [
            .init(repo: repo, updates: 4), .init(repo: api, updates: 3), .init(repo: docs, updates: 1),
        ], "busiest first, ties by name, at most three")

        h.store.dismissArrival()
        h.advance(minutes: 5)
        #expect(h.store.arrival == nil)
    }

    @Test func lockedWhenQuietHoursEndDefersToFirstUnlock() async throws {
        let h = try await collectAcrossRepos()
        h.advance(minutes: 30)
        h.store.pause()
        h.advance(minutes: 40)
        #expect(h.store.quietReason == nil)
        #expect(h.store.arrival == nil, "nobody is looking: hold the summary")
        h.advance(minutes: 120)
        #expect(h.store.arrival == nil)

        h.store.resume()
        guard case .morningSummary(let summary)? = h.store.arrival?.kind else {
            Issue.record("expected a morning summary on unlock, got \(String(describing: h.store.arrival))")
            return
        }
        #expect(summary.updates == 9)

        h.store.dismissArrival()
        h.store.pause()
        h.store.resume()
        #expect(h.store.arrival == nil, "only the first unlock after quiet hours shows it")
    }


    @Test func quietNightWithNothingToReportShowsNothing() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.quietHours = afternoonQuiet }
        h.advance(minutes: 60)
        #expect(h.store.quietReason == nil)
        #expect(h.store.arrival == nil)
    }

    @Test func relaunchAfterQuietHoursPublishesOnFirstTick() async throws {
        let h = try await collectAcrossRepos()
        h.clock.advance(by: 3600)
        let relaunched = h.relaunched()
        #expect(relaunched.arrival == nil, "waits until the store runs while the Mac is in use")
        relaunched.tick()
        guard case .morningSummary(let summary)? = relaunched.arrival?.kind else {
            Issue.record("expected a morning summary, got \(String(describing: relaunched.arrival))")
            return
        }
        #expect(summary.topRepos.first == .init(repo: repo, updates: 4), "per-conversation counts survive the relaunch")
    }
}

@MainActor
@Suite struct ReactionTests {
    private func openConversation() async throws -> Harness {
        let h = try Harness()
        let opened = TimelineItem(
            id: "opened-PR_node1", actor: sarah, createdAt: t0 - 900, payload: .opened(body: "Fix the flicker"), url: nil)
        let inline = reviewComment("PRRC_1", databaseID: 9001, by: sarah, at: t0 - 600, "Nit")
        h.github.add("1", at: t0 - 600, items: [
            opened, comment("IC_1", by: omar, at: t0 - 700), review("PRR_1", by: sarah, at: t0 - 600, .commented, comments: [inline]),
        ])
        await h.store.refresh()
        await h.store.openConversation(ThreadID("1"))
        return h
    }

    private func items(_ h: Harness) -> [TimelineItem] { h.store.conversations[ThreadID("1")]?.detail?.items ?? [] }

    @Test func reactionsTargetTheRightNodeAndShowImmediately() async throws {
        let h = try await openConversation()
        let one = ThreadID("1")
        let description = try #require(items(h).first?.reactionSubjectID)
        try await h.store.addReaction(.rocket, to: description, in: one)
        try await h.store.addReaction(.heart, to: "PRRC_1", in: one)
        try await h.store.addReaction(.heart, to: "PRRC_1", in: one)

        #expect(h.github.update { $0.reactionCalls.map(\.subjectID) } == ["PR_node1", "PRRC_1", "PRRC_1"])
        #expect(h.github.update { $0.reactionCalls.map(\.content) } == [.rocket, .heart, .heart])
        let shown = items(h)
        #expect(shown[0].reactions == [ReactionCount(content: .rocket, count: 1, viewerHasReacted: true)])
        guard case .review(_, _, let comments) = shown[2].payload else { return }
        #expect(comments[0].reactions == [ReactionCount(content: .heart, count: 1, viewerHasReacted: true)],
                "reacting again with the same emoji doesn't count the viewer twice")
        #expect(shown[2].reactions.isEmpty, "the review comment's reaction isn't put on its review")
        #expect(shown[1].reactions.isEmpty)
    }

    @Test func refusedReactionRollsBackOnScreenAndInTheCache() async throws {
        let h = try await openConversation()
        h.github.update { $0.reactionError = .graphQL(["Viewer cannot react"]) }
        await #expect(throws: GitHubError.graphQL(["Viewer cannot react"])) {
            try await h.store.addReaction(.eyes, to: "IC_1", in: ThreadID("1"))
        }
        #expect(items(h)[1].reactions.isEmpty)
        let cached = try #require(try h.database.detail(for: ThreadID("1"), account: AccountKey(login: me.login)))
        #expect(cached.items[1].reactions.isEmpty)
    }

    @Test func cachedTimelinesFromBeforeReactionsStillLoad() throws {
        let legacy = #"{"actor":{"isBot":false,"login":"sarah"},"createdAt":0,"id":"IC_1","payload":{"comment":{"body":{"markdown":"Hi"}}}}"#
        let item = try JSONDecoder().decode(TimelineItem.self, from: Data(legacy.utf8))
        #expect(item.reactions.isEmpty)
        #expect(item.reactionSubjectID == "IC_1")
    }
}

@Suite struct WorkflowSettingsStorageTests {
    @Test func disabledShortcutStaysDisabledWhileMissingKeyMeansDefault() throws {
        let db = try GitokenDatabase.inMemory()
        var state = PersistedAppState()
        state.settings.hotKey = nil
        try db.save(state)
        #expect(try db.appState()?.settings.hotKey == nil, "an explicit null is the user's choice, not a missing key")

        let legacy = #"{"appearance":"calm"}"#
        try db.queue.write { try $0.execute(sql: "UPDATE appState SET settings = ?", arguments: [legacy]) }
        #expect(try db.appState()?.settings.hotKey == .openInbox)
    }

    @Test func reboundShortcutMuteRulesAndSavedRepliesRoundTrip() throws {
        let db = try GitokenDatabase.inMemory()
        var state = PersistedAppState()
        state.settings.hotKey = HotKey(keyCode: 45, modifiers: [.control, .shift])
        state.settings.muteRules = [.repository("platform/web"), .organization("platform"), .reason(.ciActivity)]
        state.settings.savedReplies = ["On it", "Thanks!"]
        try db.save(state)
        #expect(try db.appState()?.settings == state.settings)
    }
}
