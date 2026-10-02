import AppKit
import GitokenCore
import SwiftUI

extension NotchModel {
    // MARK: Global shortcut

    /// ⌥⌘G from any app: opens the inbox ready for the keyboard (J/K, Return, E, S, U) or closes the surface.
    /// Like the notch itself, it stays out of full-screen spaces.
    func toggleFromHotKey() {
        if route.isOpen {
            close()
            return
        }
        guard !hiddenForFullscreen else { return }
        open(.list)
        let rows = Buckets(store: store, now: store.now.now()).visible(showSnoozed: showSnoozed, showDone: showDone)
        if !rows.contains(where: { $0.id == selectedRow }) { selectedRow = rows.first?.id }
    }

    // MARK: Mute

    func mute(_ rule: MuteRule) {
        withAnimation(motion.open) { store.mute(rule) }
        if let id = conversationID, group(id) == nil { open(.list) }
        showToast("Muted \(rule.subject)") { [weak self] in
            guard let self else { return }
            withAnimation(self.motion.open) { self.store.unmute(rule) }
        }
    }

    // MARK: Reactions

    func react(_ content: ReactionContent, to subjectID: String, in id: ThreadID) {
        Task {
            do throws(GitHubError) {
                try await store.addReaction(content, to: subjectID, in: id)
            } catch {
                showToast("Couldn't add \(content.emoji) — \(error.briefDescription)")
            }
        }
    }

    // MARK: Open locally

    func pullRequestRef(_ g: InboxGroup) -> PullRequestRef? {
        guard g.thread.kind == .pullRequest, let number = g.thread.number else { return nil }
        return PullRequestRef(repo: g.thread.repo, number: number)
    }

    func openPullRequestLocally(_ g: InboxGroup) {
        guard let ref = pullRequestRef(g) else { return }
        let headRefName = shelf.status(for: ref)?.headRefName ?? ""
        Task { await openLocally.open(repo: ref.repo, number: ref.number, headRefName: headRefName) }
    }
}

extension MuteRule {
    /// What the rule silences, for menus and toasts: "platform/web", "org platform", "CI notifications".
    var subject: String {
        switch self {
        case .repository(let name): name
        case .organization(let org): "org \(org)"
        case .reason(let reason): "\(reason.muteNoun) notifications"
        }
    }

    var symbol: String {
        switch self {
        case .repository: "book.closed"
        case .organization: "building.2"
        case .reason: "tag"
        }
    }
}

extension NotificationReason {
    /// "Mute review request notifications".
    var muteNoun: String {
        switch self {
        case .reviewRequested: "review request"
        case .mention: "mention"
        case .teamMention: "team mention"
        case .author: "your own"
        case .comment: "participating"
        case .assign: "assignment"
        case .stateChange: "state change"
        case .manual: "subscribed"
        case .ciActivity: "CI"
        case .subscribed: "watching"
        case .securityAlert: "security alert"
        case .invitation: "invitation"
        case .approvalRequested: "approval request"
        case .other: "other"
        }
    }
}

extension GitHubError {
    var briefDescription: String {
        switch self {
        case .auth(let auth): auth.instructions
        case .rateLimited: "rate limited by GitHub"
        case .http(let status, let message): message ?? "HTTP \(status)"
        case .graphQL(let messages): messages.first ?? "GitHub refused"
        case .decoding: "unexpected response"
        case .transport: "couldn't reach GitHub"
        }
    }
}
