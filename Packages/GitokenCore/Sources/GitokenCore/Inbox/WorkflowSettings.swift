import Foundation

/// Global shortcut. `keyCode` is the macOS virtual key code (kVK_*), modifiers are Gitoken's own flags.
public struct HotKey: Hashable, Codable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌥⌘G (kVK_ANSI_G = 5).
    public static let openInbox = HotKey(keyCode: 5, modifiers: [.command, .option])
}

/// Local-only mute: matching groups stay out of the inbox, counts, arrivals, and sounds.
public enum MuteRule: Hashable, Codable, Sendable {
    /// "owner/name"
    case repository(String)
    case organization(String)
    case reason(NotificationReason)

    public func matches(_ thread: NotificationThread) -> Bool {
        switch self {
        case .repository(let full): thread.repo.fullName.caseInsensitiveCompare(full) == .orderedSame
        case .organization(let org): thread.repo.owner.caseInsensitiveCompare(org) == .orderedSame
        case .reason(let reason): thread.reason == reason
        }
    }
}

public enum SavedReplies {
    public static let defaults = ["Looking now 👀", "LGTM once CI is green ✅", "Thanks! Addressed in the latest push."]
}
