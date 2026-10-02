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

public struct AppSettings: Hashable, Codable, Sendable {
    public var appearance: Appearance
    public var motion: MotionStyle
    public var display: DisplayMode
    public var quietHours: QuietHours
    public var launchAtLogin: Bool

    public init(
        appearance: Appearance = .calm, motion: MotionStyle = .gentle, display: DisplayMode = .notch,
        quietHours: QuietHours = .init(), launchAtLogin: Bool = false
    ) {
        self.appearance = appearance
        self.motion = motion
        self.display = display
        self.quietHours = quietHours
        self.launchAtLogin = launchAtLogin
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
