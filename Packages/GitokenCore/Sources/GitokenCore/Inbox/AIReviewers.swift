import Foundation

/// Known AI code-review accounts (Copilot, CodeRabbit, …), matched by login.
public enum AIReviewers {
    /// Logins that only ever belong to AI reviewers, whatever the account type.
    private static let logins: Set<String> = [
        "copilot-pull-request-reviewer", "copilot-swe-agent", "coderabbitai", "gemini-code-assist",
        "chatgpt-codex-connector", "sourcery-ai", "greptile-apps", "ellipsis-dev", "qodo-merge-pro", "codeant-ai",
        "korbit-ai", "graphite-app",
    ]
    /// Generic names that are also plausible human logins: AI only when the actor is a bot.
    private static let botOnlyLogins: Set<String> = ["copilot", "cursor"]

    public static func isAI(_ actor: Actor) -> Bool {
        var login = actor.login.lowercased()
        let hadBotSuffix = login.hasSuffix("[bot]")
        if hadBotSuffix { login.removeLast("[bot]".count) }
        if logins.contains(login) { return true }
        return botOnlyLogins.contains(login) && (actor.isBot || hadBotSuffix)
    }

    /// Reviews, review comments, and comments written by an AI reviewer.
    public static func isAIActivity(_ item: TimelineItem) -> Bool {
        guard isAI(item.actor) else { return false }
        switch item.payload {
        case .review, .comment: return true
        case .opened, .commits, .checks, .event: return false
        }
    }
}
