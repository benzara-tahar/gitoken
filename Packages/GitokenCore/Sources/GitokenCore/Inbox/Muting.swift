import Foundation

extension MuteRule {
    /// Context-menu choices for a group, broadest last: its repository, its organization, its notification reason.
    public static func suggestions(for thread: NotificationThread) -> [MuteRule] {
        [.repository(thread.repo.fullName), .organization(thread.repo.owner), .reason(thread.reason)]
    }
}

extension Sequence<MuteRule> {
    public func mutes(_ thread: NotificationThread) -> Bool { contains { $0.matches(thread) } }
}
