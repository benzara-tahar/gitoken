import Foundation

/// One PR on the shelf: the viewer's own open PRs plus explicitly pinned ones.
public struct ShelfItem: Hashable, Sendable, Identifiable {
    public var id: PullRequestRef { status.ref }
    public let status: PullRequestStatus
    public let isPinned: Bool
    /// Returned by the "my open PRs" search (authored by the viewer).
    public let isMine: Bool

    public init(status: PullRequestStatus, isPinned: Bool, isMine: Bool) {
        self.status = status
        self.isPinned = isPinned
        self.isMine = isMine
    }
}

/// A change on a shelved PR worth a bounce/sound (and a line in the morning summary).
public struct ShelfEvent: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let kind: ShelfEventKind
    public let ref: PullRequestRef
    public let title: String
    /// Who caused it, when known (the commenter for `.newComment`, the reviewer for review events).
    public let actor: Actor?
    public let at: Date

    public init(kind: ShelfEventKind, ref: PullRequestRef, title: String, actor: Actor? = nil, at: Date) {
        self.id = "\(ref.repo.fullName)#\(ref.number)-\(kind.rawValue)-\(at.timeIntervalSinceReferenceDate)"
        self.kind = kind
        self.ref = ref
        self.title = title
        self.actor = actor
        self.at = at
    }

    /// "CI failed on #305", "#142 is ready to merge".
    public var summary: String {
        let n = "#\(ref.number)"
        switch kind {
        case .ciFailed: return "CI failed on \(n)"
        case .ciPassed: return "CI passed on \(n)"
        case .approved: return actor.map { "\($0.displayName) approved \(n)" } ?? "\(n) was approved"
        case .changesRequested: return actor.map { "\($0.displayName) requested changes on \(n)" } ?? "Changes requested on \(n)"
        case .newComment: return actor.map { "\($0.displayName) commented on \(n)" } ?? "New comment on \(n)"
        case .readyToMerge: return "\(n) is ready to merge"
        case .mergeConflict: return "\(n) has merge conflicts"
        case .merged: return "\(n) was merged"
        }
    }

    /// Morning-summary lines, oldest first: one line per PR and kind (latest wins). A later CI result supersedes an
    /// earlier opposite one, and "ready to merge" absorbs the approval / green CI that produced it.
    public static func overnightLines(_ events: [ShelfEvent]) -> [String] {
        var latest: [String: ShelfEvent] = [:]
        for event in events.sorted(by: { $0.at < $1.at }) {
            latest[key(event.ref, event.kind)] = event
        }
        let kept = latest.values.filter { event in
            func later(_ kind: ShelfEventKind) -> Bool {
                latest[key(event.ref, kind)].map { $0.at >= event.at } ?? false
            }
            switch event.kind {
            case .ciFailed: return !later(.ciPassed) && !later(.merged)
            case .ciPassed: return !later(.ciFailed) && !later(.readyToMerge) && !later(.merged)
            case .approved: return !later(.changesRequested) && !later(.readyToMerge) && !later(.merged)
            case .changesRequested: return !later(.approved) && !later(.merged)
            case .readyToMerge, .mergeConflict, .newComment: return !later(.merged)
            case .merged: return true
            }
        }
        return kept.sorted { ($0.at, $0.id) < ($1.at, $1.id) }.map(\.summary)
    }

    private static func key(_ ref: PullRequestRef, _ kind: ShelfEventKind) -> String {
        "\(ref.repo.fullName)#\(ref.number)|\(kind.rawValue)"
    }
}

/// Published when enabled events happen outside quiet time. The UI bounces + plays a sound once per new `id`.
public struct ShelfPulse: Equatable, Sendable {
    public let id: Int
    public let events: [ShelfEvent]
}

public enum ShelfError: Error, Equatable, Sendable {
    case notAPullRequestURL
    /// GitHub has no such PR, or the viewer cannot see it.
    case notFound
    case github(GitHubError)
}

/// Diffs two snapshots of the same PR into shelf events (unfiltered by settings).
enum ShelfEventDetector {
    static func events(from old: PullRequestStatus, to new: PullRequestStatus, at: Date) -> [ShelfEvent] {
        func event(_ kind: ShelfEventKind, actor: Actor? = nil) -> ShelfEvent {
            ShelfEvent(kind: kind, ref: new.ref, title: new.title, actor: actor, at: at)
        }
        if new.state == .merged { return old.state == .merged ? [] : [event(.merged)] }
        guard new.state == .open else { return [] }

        var events: [ShelfEvent] = []
        if let checks = new.checks, checks.status == .failure || checks.status == .success {
            let sameResult = old.checks?.status == checks.status && old.checks?.commitSHA == checks.commitSHA
            if !sameResult { events.append(event(checks.status == .failure ? .ciFailed : .ciPassed)) }
        }

        let reviewer = new.latestHumanActivity.flatMap { activity -> Actor? in
            guard activity.at > (old.latestHumanActivity?.at ?? .distantPast) else { return nil }
            return activity.actor
        }
        if new.reviewDecision == .approved, old.reviewDecision != .approved {
            events.append(event(.approved, actor: new.latestHumanActivity?.verb == .approved ? reviewer : nil))
        }
        if new.reviewDecision == .changesRequested, old.reviewDecision != .changesRequested {
            events.append(event(.changesRequested, actor: new.latestHumanActivity?.verb == .requestedChanges ? reviewer : nil))
        }
        if let activity = new.latestHumanActivity, activity.at > (old.latestHumanActivity?.at ?? .distantPast),
           activity.verb != .approved, activity.verb != .requestedChanges
        {
            events.append(event(.newComment, actor: activity.actor))
        }
        if new.mergeable == .conflicting, old.mergeable != .conflicting {
            events.append(event(.mergeConflict))
        }
        if new.isReadyToMerge, !old.isReadyToMerge {
            events.append(event(.readyToMerge))
        }
        return events
    }
}
