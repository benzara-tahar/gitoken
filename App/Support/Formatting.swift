import Foundation
import GitokenCore
import SwiftUI

enum Format {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Compact relative age for list rows: "now", "5m", "2h", "3d", then a date.
    static func ago(_ date: Date, now: Date) -> String {
        let d = now.timeIntervalSince(date)
        if d < 45 { return "now" }
        if d < 3600 { return "\(max(1, Int((d / 60).rounded())))m" }
        if d < 86400 { return "\(Int((d / 3600).rounded()))h" }
        if d < 7 * 86400 { return "\(Int((d / 86400).rounded()))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Timeline stamp: time today, "Yesterday 2:20 PM", otherwise "Mar 3".
    static func stamp(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return time(date) }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return "Yesterday \(time(date))"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "2:50 PM", "tomorrow 9:00 AM", or "Mon 9:00 AM" relative to `now`.
    static func until(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return time(date) }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: t) {
            return "tomorrow \(time(date))"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time(date))"
    }

    static func clock(_ t: ClockTime, calendar: Calendar = .current) -> String {
        let base = calendar.startOfDay(for: Date())
        return time(calendar.date(byAdding: .minute, value: t.minutes, to: base) ?? base)
    }

    static func firstName(_ actor: Actor, viewer: String?) -> String {
        if actor.login == viewer { return "You" }
        if actor.isBot { return actor.displayName }
        return actor.displayName.split(separator: " ").first.map(String.init) ?? actor.login
    }

    static func plain(_ text: String, limit: Int = 120) -> String {
        var t = text.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if t.count > limit { t = String(t.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" }
        return t
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

extension NotificationReason {
    var shortLabel: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .mention, .teamMention: "Mentioned"
        case .author: "Yours"
        case .comment: "Participating"
        case .assign: "Assigned"
        case .stateChange: "State changed"
        case .manual: "Subscribed"
        case .ciActivity: "CI"
        case .subscribed: "Watching"
        case .securityAlert: "Security"
        case .invitation: "Invitation"
        case .approvalRequested: "Approval requested"
        case .other: "Updated"
        }
    }

    var longLabel: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .mention: "You were mentioned"
        case .teamMention: "Your team was mentioned"
        case .author: "Opened by you"
        case .comment: "Participating"
        case .assign: "Assigned to you"
        default: shortLabel
        }
    }
}

extension ActivityVerb {
    /// Verb phrase after the actor's first name; CI verbs read on their own.
    var phrase: String {
        switch self {
        case .commented: "commented"
        case .mentioned: "mentioned you"
        case .approved: "approved"
        case .requestedChanges: "requested changes"
        case .reviewed: "reviewed"
        case .reviewRequested: "requested your review"
        case .pushed: "pushed commits"
        case .checksFailed: "CI failed"
        case .checksPassed: "All checks passed"
        case .opened: "opened this"
        case .closed: "closed this"
        case .reopened: "reopened this"
        case .merged: "merged this"
        case .updated: "updated"
        }
    }

    var hasActorSubject: Bool { self != .checksFailed && self != .checksPassed }

    var badge: ActivityBadge {
        switch self {
        case .approved, .checksPassed: .init(symbol: "checkmark", tone: .success)
        case .requestedChanges, .checksFailed: .init(symbol: "xmark", tone: .danger)
        case .commented, .reviewed, .updated: .init(symbol: "bubble.left.fill", tone: .accent)
        case .mentioned: .init(symbol: "at", tone: .accent)
        case .reviewRequested: .init(symbol: "eye.fill", tone: .warn)
        case .pushed: .init(symbol: "smallcircle.filled.circle", tone: .neutral)
        case .opened: .init(symbol: "plus", tone: .success)
        case .closed: .init(symbol: "xmark", tone: .merged)
        case .reopened: .init(symbol: "arrow.clockwise", tone: .warn)
        case .merged: .init(symbol: "arrow.triangle.merge", tone: .merged)
        }
    }
}

extension ActivityPreview {
    func sentence(viewer: String?) -> (who: String?, what: String) {
        let who = verb.hasActorSubject ? actor.map { Format.firstName($0, viewer: viewer) } : nil
        return (who, verb.phrase)
    }
}

enum Tone {
    case accent, success, danger, warn, merged, neutral

    func color(_ theme: Theme) -> Color {
        switch self {
        case .accent: theme.accent
        case .success: theme.success
        case .danger: theme.danger
        case .warn: theme.warn
        case .merged: theme.merged
        case .neutral: Color(red: 0.48, green: 0.51, blue: 0.56)
        }
    }
}

struct ActivityBadge {
    var symbol: String
    var tone: Tone
}

/// Kind glyph: PR (open/merged/closed/draft) or issue (open/closed).
struct KindIcon: View {
    @Environment(\.theme) private var theme
    var kind: SubjectKind
    var state: SubjectState
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tone.color(theme))
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch kind {
        case .pullRequest: state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull"
        case .issue: state == .closed ? "checkmark.circle" : "smallcircle.filled.circle"
        case .discussion: "bubble.left.and.bubble.right"
        case .release: "tag"
        case .commit: "smallcircle.filled.circle"
        case .checkSuite: "checkmark.seal"
        case .other: "bell"
        }
    }

    private var tone: Tone {
        switch (kind, state) {
        case (.pullRequest, .merged): .merged
        case (.pullRequest, .closed): .danger
        case (.pullRequest, .draft): .neutral
        case (.issue, .closed): .merged
        case (_, .open), (_, .unknown): .success
        default: .neutral
        }
    }

    private var label: String {
        switch kind {
        case .pullRequest: "\(state.rawValue.capitalized) pull request"
        case .issue: "\(state.rawValue.capitalized) issue"
        default: kind.rawValue
        }
    }
}
