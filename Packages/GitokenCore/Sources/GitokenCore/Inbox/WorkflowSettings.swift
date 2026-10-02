import Foundation

/// Editor used by "Open in editor". Known apps launch via `open -a`, so no shell PATH is needed.
public enum EditorChoice: Hashable, Codable, Sendable {
    case vscode
    case zed
    /// Run through the user's login shell; `{path}` is replaced with the shell-quoted folder path.
    case custom(template: String)
}

/// Where the PR Shelf circle rests; it snaps to the nearest corner after a drag.
public enum ShelfCorner: String, Codable, Sendable, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight
}

/// Changes on a shelved PR that can bounce the circle and play a sound.
public enum ShelfEventKind: String, Codable, Sendable, CaseIterable {
    case ciFailed, ciPassed, approved, changesRequested, newComment, readyToMerge, mergeConflict, merged
}

public struct ShelfSettings: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var corner: ShelfCorner
    public var events: Set<ShelfEventKind>

    public static let defaultEvents: Set<ShelfEventKind> = [.ciFailed, .ciPassed, .approved, .changesRequested, .newComment, .readyToMerge]

    public init(enabled: Bool = true, corner: ShelfCorner = .bottomLeft, events: Set<ShelfEventKind> = ShelfSettings.defaultEvents) {
        self.enabled = enabled
        self.corner = corner
        self.events = events
    }

    private enum CodingKeys: String, CodingKey { case enabled, corner, events }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShelfSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        corner = try c.decodeIfPresent(ShelfCorner.self, forKey: .corner) ?? d.corner
        events = try c.decodeIfPresent(Set<ShelfEventKind>.self, forKey: .events) ?? d.events
    }
}

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
