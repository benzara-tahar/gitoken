import Foundation
import GRDB
import Testing
@testable import GitokenCore

@Suite struct SettingsStorageTests {
    @Test func settingsStoredByAnOlderReleaseLoadWithDefaultsForNewKeys() throws {
        let db = try GitokenDatabase.inMemory()
        try db.save(PersistedAppState())
        let legacy = #"{"appearance":"fluid","display":"pill","launchAtLogin":true,"motion":"elastic","quietHours":{"enabled":false,"end":{"minutes":420},"start":{"minutes":1380}}}"#
        try db.queue.write { try $0.execute(sql: "UPDATE appState SET settings = ?", arguments: [legacy]) }

        let loaded = try #require(try db.appState()).settings
        #expect(loaded == AppSettings(
            appearance: .fluid, motion: .elastic, display: .pill,
            quietHours: QuietHours(enabled: false, start: .init(hour: 23, minute: 0), end: .init(hour: 7, minute: 0)),
            launchAtLogin: true, sound: .drop, soundVolume: 0.35, aiReviews: .collapse, notifyAIReviews: false))
    }

    @Test func obsoleteLocalSettingsAreIgnoredAndNotSavedAgain() throws {
        let db = try GitokenDatabase.inMemory()
        try db.save(PersistedAppState())
        let legacy = """
            {"appearance":"fluid","motion":"reduced","savedReplies":["Thanks!"],"hotKey":null,
             "editor":{"custom":{"template":"code {path}"}},"worktreeRoot":"~/Worktrees",
             "repoPaths":{"platform/web":"/Users/test/code/web"},"cloneSearchRoots":["~/code"]}
            """
        try db.queue.write { try $0.execute(sql: "UPDATE appState SET settings = ?", arguments: [legacy]) }

        var state = try #require(try db.appState())
        #expect(state.settings == AppSettings(
            appearance: .fluid, motion: .reduced, hotKey: nil, savedReplies: ["Thanks!"]))
        state.settings.sound = .chime
        try db.save(state)
        #expect(try db.appState()?.settings == state.settings)
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state.settings)) as? [String: Any])
        for key in ["editor", "worktreeRoot", "repoPaths", "cloneSearchRoots"] {
            #expect(encoded[key] == nil)
        }
    }

    @Test func soundAndAIReviewChoicesRoundTrip() throws {
        let db = try GitokenDatabase.inMemory()
        var state = PersistedAppState()
        state.settings.sound = .tap
        state.settings.soundVolume = 0.8
        state.settings.aiReviews = .hide
        state.settings.notifyAIReviews = true
        try db.save(state)
        #expect(try db.appState()?.settings == state.settings)
    }

    @Test(arguments: [
        Set<NotificationReason>(),
        Set<NotificationReason>([.mention, .reviewRequested]),
        Set(NotificationReason.allCases),
    ])
    func notificationReasonAllowlistRoundTripsWithoutChangingOtherChoices(
        _ reasons: Set<NotificationReason>
    ) throws {
        let db = try GitokenDatabase.inMemory()
        var state = PersistedAppState()
        state.settings.enabledNotificationReasons = reasons
        state.settings.notifyAIReviews = true
        state.settings.muteRules = [.repository("acme/web")]
        try db.save(state)
        #expect(try db.appState()?.settings == state.settings)
    }

    @Test func absentNotificationReasonAllowlistEnablesEveryReason() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"notifyAIReviews":false}"#.utf8))
        #expect(settings.enabledNotificationReasons == Set(NotificationReason.allCases))
        #expect(!settings.notifyAIReviews)
    }
}
