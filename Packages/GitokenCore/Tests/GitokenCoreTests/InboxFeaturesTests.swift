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

    @Test func groupsOvernightActivityByRepoAndAddsShelfChangesOnce() async throws {
        let h = try await collectAcrossRepos()
        var shelfCalls = 0
        h.store.overnightShelfLines = {
            shelfCalls += 1
            return ["#142 is ready to merge", "CI failed on #305"]
        }

        h.advance(minutes: 58)
        #expect(h.store.arrival == nil)
        #expect(shelfCalls == 0)
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
        #expect(summary.shelfChanges == ["#142 is ready to merge", "CI failed on #305"])

        h.store.dismissArrival()
        h.advance(minutes: 5)
        #expect(h.store.arrival == nil)
        #expect(shelfCalls == 1)
    }

    @Test func lockedWhenQuietHoursEndDefersToFirstUnlock() async throws {
        let h = try await collectAcrossRepos()
        h.store.overnightShelfLines = { ["#142 is ready to merge"] }
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
        #expect(summary.shelfChanges == ["#142 is ready to merge"])

        h.store.dismissArrival()
        h.store.pause()
        h.store.resume()
        #expect(h.store.arrival == nil, "only the first unlock after quiet hours shows it")
    }

    @Test func shelfChangesAloneStillMakeAMorningCard() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.quietHours = afternoonQuiet }
        h.github.add("1", at: t0 - 600)
        await h.store.refresh()
        h.store.overnightShelfLines = { ["CI failed on #305"] }
        h.advance(minutes: 60)
        #expect(h.store.arrival?.kind == .morningSummary(MorningSummary(
            updates: 0, conversations: 0, topRepos: [], shelfChanges: ["CI failed on #305"], actors: [])))
    }

    @Test func quietNightWithNothingToReportShowsNothing() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.quietHours = afternoonQuiet }
        h.store.overnightShelfLines = { [] }
        h.advance(minutes: 60)
        #expect(h.store.quietReason == nil)
        #expect(h.store.arrival == nil)
    }

    @Test func relaunchAfterQuietHoursPublishesOnFirstTickWithShelfChanges() async throws {
        let h = try await collectAcrossRepos()
        h.clock.advance(by: 3600)
        let relaunched = h.relaunched()
        #expect(relaunched.arrival == nil, "waits until the shelf is wired and the store runs")
        relaunched.overnightShelfLines = { ["#142 is ready to merge"] }
        relaunched.tick()
        guard case .morningSummary(let summary)? = relaunched.arrival?.kind else {
            Issue.record("expected a morning summary, got \(String(describing: relaunched.arrival))")
            return
        }
        #expect(summary.topRepos.first == .init(repo: repo, updates: 4), "per-conversation counts survive the relaunch")
        #expect(summary.shelfChanges == ["#142 is ready to merge"])
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
