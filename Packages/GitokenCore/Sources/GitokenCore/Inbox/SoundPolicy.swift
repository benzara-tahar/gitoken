import Foundation

/// A sound to play right now.
public struct SoundCue: Equatable, Sendable {
    public var sound: ArrivalSound
    /// 0…1, already scaled for the arrival kind.
    public var volume: Double
}

/// Decides when an arrival is announced audibly. Feed it every published `InboxStore.arrival` value; it plays once
/// per new arrival id (a burst merging into the current arrival keeps its id, so it stays one sound) and never more
/// often than `minimumInterval`. Arrivals it declines are still remembered, so they cannot sound later — e.g. when
/// fullscreen ends.
public struct SoundPolicy: Sendable {
    public static let minimumInterval: TimeInterval = 2
    /// Summaries and snooze reminders are re-announcements of collected/known activity.
    public static let reminderVolumeScale = 0.75

    public struct Context: Sendable {
        public var settings: AppSettings
        public var quietReason: QuietReason?
        public var hiddenForFullscreen: Bool
        /// An open panel consumes arrivals without announcing them, so they stay silent too.
        public var panelOpen: Bool

        public init(settings: AppSettings, quietReason: QuietReason?, hiddenForFullscreen: Bool, panelOpen: Bool) {
            self.settings = settings
            self.quietReason = quietReason
            self.hiddenForFullscreen = hiddenForFullscreen
            self.panelOpen = panelOpen
        }
    }

    private var lastArrivalID: UUID?
    private var lastPlayedAt: Date?

    public init() {}

    public mutating func cue(for arrival: Arrival?, context: Context, now: Date) -> SoundCue? {
        guard let arrival, arrival.id != lastArrivalID else { return nil }
        lastArrivalID = arrival.id
        let settings = context.settings
        guard settings.sound != .off, settings.soundVolume > 0, context.quietReason == nil, !context.hiddenForFullscreen,
              !context.panelOpen
        else { return nil }
        if let last = lastPlayedAt, now.timeIntervalSince(last) < Self.minimumInterval { return nil }
        lastPlayedAt = now
        let scale: Double = switch arrival.kind {
        case .activity: 1
        case .snoozeEnded, .summary: Self.reminderVolumeScale
        }
        return SoundCue(sound: settings.sound, volume: min(1, settings.soundVolume) * scale)
    }
}
