import Foundation
import Testing
@testable import GitokenCore

@Suite struct SoundPolicyTests {
    let start = Date(timeIntervalSinceReferenceDate: 812_000_000)
    let settings = AppSettings(sound: .chime, soundVolume: 0.4)

    func context(
        _ settings: AppSettings? = nil, quiet: QuietReason? = nil, fullscreen: Bool = false, panelOpen: Bool = false
    ) -> SoundPolicy.Context {
        .init(settings: settings ?? self.settings, quietReason: quiet, hiddenForFullscreen: fullscreen, panelOpen: panelOpen)
    }

    func activity(_ id: UUID = UUID(), count: Int = 1) -> Arrival {
        Arrival(
            id: id, kind: .activity(groupID: ThreadID("7"), latest: .generic(at: start), reopened: false),
            updateCount: count, actors: [])
    }

    @Test func burstMergingIntoTheCurrentArrivalSoundsOnce() {
        var policy = SoundPolicy()
        let id = UUID()
        #expect(policy.cue(for: activity(id), context: context(), now: start) == SoundCue(sound: .chime, volume: 0.4))
        #expect(policy.cue(for: activity(id, count: 2), context: context(), now: start + 0.3) == nil)
        #expect(policy.cue(for: activity(id, count: 5), context: context(), now: start + 10) == nil, "merges never re-sound")
    }

    @Test func newArrivalsAreThrottledToOneSoundPerInterval() {
        var policy = SoundPolicy()
        #expect(policy.cue(for: activity(), context: context(), now: start) != nil)
        let throttled = activity()
        #expect(policy.cue(for: throttled, context: context(), now: start + 1.9) == nil)
        #expect(policy.cue(for: throttled, context: context(), now: start + 5) == nil, "a declined arrival stays silent")
        #expect(policy.cue(for: activity(), context: context(), now: start + 2) != nil, "interval measured from last play")
    }

    @Test func suppressedArrivalsDoNotSoundWhenTheSuppressionLifts() {
        var policy = SoundPolicy()
        let duringFullscreen = activity()
        #expect(policy.cue(for: duringFullscreen, context: context(fullscreen: true), now: start) == nil)
        #expect(policy.cue(for: duringFullscreen, context: context(), now: start + 5) == nil)

        let consumedByOpenPanel = activity()
        #expect(policy.cue(for: consumedByOpenPanel, context: context(panelOpen: true), now: start + 8) == nil)
        #expect(policy.cue(for: consumedByOpenPanel, context: context(), now: start + 9) == nil, "closing the panel stays silent")

        #expect(policy.cue(for: activity(), context: context(quiet: .manual), now: start + 10) == nil)
        #expect(policy.cue(for: activity(), context: context(quiet: .globalSnooze(until: start + 99)), now: start + 20) == nil)

        var off = settings
        off.sound = .off
        #expect(policy.cue(for: activity(), context: context(off), now: start + 30) == nil)
        off = settings
        off.soundVolume = 0
        #expect(policy.cue(for: activity(), context: context(off), now: start + 40) == nil)

        #expect(policy.cue(for: activity(), context: context(), now: start + 41) != nil, "suppression does not start the throttle")
    }

    @Test func drainingToNilDoesNotReplayTheLastArrival() {
        var policy = SoundPolicy()
        let shown = activity()
        #expect(policy.cue(for: shown, context: context(), now: start) != nil)
        #expect(policy.cue(for: nil, context: context(), now: start + 3) == nil)
        #expect(policy.cue(for: shown, context: context(), now: start + 6) == nil)
    }

    @Test func summaryAndSnoozeEndedPlayTheSameSoundSofter() {
        var policy = SoundPolicy()
        let summary = Arrival(kind: .summary(updates: 4, groups: 2, actors: [], endedReason: .manual), updateCount: 4, actors: [])
        let expected = 0.4 * SoundPolicy.reminderVolumeScale
        #expect(policy.cue(for: summary, context: context(), now: start) == SoundCue(sound: .chime, volume: expected))
        let snoozeEnded = Arrival(kind: .snoozeEnded(groupID: ThreadID("9")), updateCount: 1, actors: [])
        #expect(policy.cue(for: snoozeEnded, context: context(), now: start + 3) == SoundCue(sound: .chime, volume: expected))
    }
}
