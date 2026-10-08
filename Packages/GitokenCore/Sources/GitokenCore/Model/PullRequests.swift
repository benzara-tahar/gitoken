import Foundation

public struct PullRequestRef: Hashable, Codable, Sendable {
    public let repo: RepoRef
    public let number: Int

    public init(repo: RepoRef, number: Int) {
        self.repo = repo
        self.number = number
    }


    public var htmlURL: URL { URL(string: "https://github.com/\(repo.fullName)/pull/\(number)")! }
}

/// Emoji reactions supported by GitHub's `addReaction` mutation.
public enum ReactionContent: String, Codable, Sendable, CaseIterable {
    case thumbsUp = "THUMBS_UP", hooray = "HOORAY", eyes = "EYES", heart = "HEART", rocket = "ROCKET", confused = "CONFUSED"

    public var emoji: String {
        switch self {
        case .thumbsUp: "👍"
        case .hooray: "🎉"
        case .eyes: "👀"
        case .heart: "❤️"
        case .rocket: "🚀"
        case .confused: "😕"
        }
    }
}

/// One emoji's tally on a PR/issue body, comment, review, or review comment.
public struct ReactionCount: Hashable, Codable, Sendable {
    public let content: ReactionContent
    public let count: Int
    public let viewerHasReacted: Bool

    public init(content: ReactionContent, count: Int, viewerHasReacted: Bool) {
        self.content = content
        self.count = count
        self.viewerHasReacted = viewerHasReacted
    }
}

extension [ReactionCount] {
    /// The viewer's reaction added once: the tally grows unless the viewer already reacted with `content`.
    /// Order follows `ReactionContent.allCases` so chips don't jump around.
    public func adding(_ content: ReactionContent) -> [ReactionCount] {
        var byContent = Dictionary(map { ($0.content, $0) }, uniquingKeysWith: { first, _ in first })
        if let existing = byContent[content] {
            guard !existing.viewerHasReacted else { return self }
            byContent[content] = ReactionCount(content: content, count: existing.count + 1, viewerHasReacted: true)
        } else {
            byContent[content] = ReactionCount(content: content, count: 1, viewerHasReacted: true)
        }
        return ReactionContent.allCases.compactMap { byContent[$0] }
    }
}
