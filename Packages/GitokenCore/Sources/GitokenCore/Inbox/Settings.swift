import Foundation

public enum Appearance: String, Codable, Sendable, CaseIterable {
    /// Native macOS glass, gentle expansion, subtle fades.
    case calm
    /// Dark rounded surfaces, expressive avatars, Dynamic Island–style elastic expansion.
    case fluid
}

public enum MotionStyle: String, Codable, Sendable, CaseIterable {
    case gentle, elastic, reduced
}

public enum DisplayMode: String, Codable, Sendable, CaseIterable {
    /// Hug the hardware notch (falls back to pill automatically on screens without one).
    case notch
    /// Floating pill under the menu bar, for previewing / using displays without a notch.
    case pill
}

/// Minutes since local midnight, 0..<1440.
public struct ClockTime: Hashable, Codable, Sendable, Comparable {
    public let minutes: Int
    public init(hour: Int, minute: Int) { minutes = ((hour * 60 + minute) % 1440 + 1440) % 1440 }
    public var hour: Int { minutes / 60 }
    public var minute: Int { minutes % 60 }
    public static func < (a: ClockTime, b: ClockTime) -> Bool { a.minutes < b.minutes }
}

public struct QuietHours: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var start: ClockTime
    public var end: ClockTime

    public init(enabled: Bool = true, start: ClockTime = .init(hour: 22, minute: 0), end: ClockTime = .init(hour: 8, minute: 0)) {
        self.enabled = enabled
        self.start = start
        self.end = end
    }

    /// Supports ranges that wrap midnight (22:00–08:00). Equal start and end means "never".
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, start != end else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = ClockTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }
}

/// Bundled arrival sound (rendered by `scripts/generate-sounds.swift`); the raw value names the resource.
public enum ArrivalSound: String, Codable, Sendable, CaseIterable {
    case off, drop, chime, tap

    public var title: String { rawValue.capitalized }
    /// Resource name of the bundled `.caf`, nil for `.off`.
    public var resourceName: String? { self == .off ? nil : rawValue.capitalized }
}

/// How reviews by AI reviewers (Copilot, CodeRabbit, …) appear in conversation timelines.
public enum AIReviewDisplay: String, Codable, Sendable, CaseIterable {
    case show, collapse, hide

    public var title: String { rawValue.capitalized }
}

public struct AppSettings: Hashable, Codable, Sendable {
    public var appearance: Appearance
    public var motion: MotionStyle
    public var display: DisplayMode
    public var quietHours: QuietHours
    public var launchAtLogin: Bool
    public var sound: ArrivalSound
    /// 0…1, relative to the system output volume.
    public var soundVolume: Double
    public var aiReviews: AIReviewDisplay
    /// When false, AI-authored activity never announces an arrival (or sound).
    public var notifyAIReviews: Bool
    /// Nil disables the global shortcut.
    public var hotKey: HotKey?
    public var muteRules: [MuteRule]
    /// Presentation-only filter; excluded threads remain locally tracked without changing GitHub state.
    public var enabledNotificationReasons: Set<NotificationReason>
    public var savedReplies: [String]
    public var customSections: [CustomSection]

    public init(
        appearance: Appearance = .calm, motion: MotionStyle = .gentle, display: DisplayMode = .notch,
        quietHours: QuietHours = .init(), launchAtLogin: Bool = false, sound: ArrivalSound = .drop, soundVolume: Double = 0.35,
        aiReviews: AIReviewDisplay = .collapse, notifyAIReviews: Bool = false,
        hotKey: HotKey? = .openInbox, muteRules: [MuteRule] = [], savedReplies: [String] = SavedReplies.defaults,
        enabledNotificationReasons: Set<NotificationReason> = Set(NotificationReason.allCases),
        customSections: [CustomSection] = []
    ) {
        self.appearance = appearance
        self.motion = motion
        self.display = display
        self.quietHours = quietHours
        self.launchAtLogin = launchAtLogin
        self.sound = sound
        self.soundVolume = soundVolume
        self.aiReviews = aiReviews
        self.notifyAIReviews = notifyAIReviews
        self.hotKey = hotKey
        self.muteRules = muteRules
        self.savedReplies = savedReplies
        self.enabledNotificationReasons = enabledNotificationReasons
        self.customSections = customSections
    }

    private enum CodingKeys: String, CodingKey {
        case appearance, motion, display, quietHours, launchAtLogin, sound, soundVolume, aiReviews, notifyAIReviews
        case hotKey, muteRules, savedReplies, enabledNotificationReasons, customSections
    }

    /// Settings are stored as JSON; keys added after a release fall back to defaults so older rows still load.
    /// `hotKey` distinguishes "absent" (default ⌥⌘G) from an explicit null (user disabled it).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        motion = try c.decodeIfPresent(MotionStyle.self, forKey: .motion) ?? d.motion
        display = try c.decodeIfPresent(DisplayMode.self, forKey: .display) ?? d.display
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? d.quietHours
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        sound = try c.decodeIfPresent(ArrivalSound.self, forKey: .sound) ?? d.sound
        soundVolume = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .soundVolume) ?? d.soundVolume))
        aiReviews = try c.decodeIfPresent(AIReviewDisplay.self, forKey: .aiReviews) ?? d.aiReviews
        notifyAIReviews = try c.decodeIfPresent(Bool.self, forKey: .notifyAIReviews) ?? d.notifyAIReviews
        hotKey = c.contains(.hotKey) ? try c.decodeIfPresent(HotKey.self, forKey: .hotKey) : d.hotKey
        muteRules = try c.decodeIfPresent([MuteRule].self, forKey: .muteRules) ?? d.muteRules
        savedReplies = try c.decodeIfPresent([String].self, forKey: .savedReplies) ?? d.savedReplies
        enabledNotificationReasons = try c.decodeIfPresent(Set<NotificationReason>.self, forKey: .enabledNotificationReasons)
            ?? d.enabledNotificationReasons
        customSections = try c.decodeIfPresent([CustomSection].self, forKey: .customSections) ?? d.customSections
    }

    /// Synthesized encoding would omit a nil `hotKey`; write an explicit null so "disabled" survives a reload.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(motion, forKey: .motion)
        try c.encode(display, forKey: .display)
        try c.encode(quietHours, forKey: .quietHours)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(sound, forKey: .sound)
        try c.encode(soundVolume, forKey: .soundVolume)
        try c.encode(aiReviews, forKey: .aiReviews)
        try c.encode(notifyAIReviews, forKey: .notifyAIReviews)
        if let hotKey { try c.encode(hotKey, forKey: .hotKey) } else { try c.encodeNil(forKey: .hotKey) }
        try c.encode(muteRules, forKey: .muteRules)
        try c.encode(savedReplies, forKey: .savedReplies)
        try c.encode(enabledNotificationReasons, forKey: .enabledNotificationReasons)
        try c.encode(customSections, forKey: .customSections)
    }

    func presents(_ thread: NotificationThread) -> Bool {
        enabledNotificationReasons.contains(thread.reason) && !muteRules.mutes(thread)
    }

    /// Presets set both axes; each axis stays independently editable afterwards.
    public static func preset(_ appearance: Appearance, keeping s: AppSettings) -> AppSettings {
        var out = s
        out.appearance = appearance
        out.motion = appearance == .calm ? .gentle : .elastic
        return out
    }
}

public enum SnoozeOption: String, Codable, Sendable, CaseIterable, Identifiable {
    case thirtyMinutes, oneHour, untilTomorrow
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .untilTomorrow: "Until tomorrow"
        }
    }

    /// "Until tomorrow" means 09:00 local on the next calendar day.
    public func deadline(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .untilTomorrow:
            let startOfToday = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        }
    }
}

/// Why arrival animations are currently suppressed. Activity keeps collecting in every case.
public enum QuietReason: Hashable, Sendable {
    case globalSnooze(until: Date)
    case manual
    case quietHours(until: ClockTime)
}

public enum QuietPolicy {
    /// Precedence: global snooze > manual quiet mode > scheduled quiet hours.
    public static func reason(
        now: Date, globalSnoozeUntil: Date?, manualQuiet: Bool, quietHours: QuietHours, calendar: Calendar = .current
    ) -> QuietReason? {
        if let until = globalSnoozeUntil, until > now { return .globalSnooze(until: until) }
        if manualQuiet { return .manual }
        if quietHours.contains(now, calendar: calendar) { return .quietHours(until: quietHours.end) }
        return nil
    }
}
