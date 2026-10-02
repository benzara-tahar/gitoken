import AppKit
import GitokenCore
import Observation
import SwiftUI

/// UI state and intents for the PR Shelf. PR data, polling, events, pins, merge and agent context live in `ShelfStore`;
/// presentation preferences (appearance, motion, sound) come from the notch model's settings.
@MainActor
@Observable
final class ShelfModel {
    struct Feedback: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var tone: Tone

        static func == (a: Feedback, b: Feedback) -> Bool { a.id == b.id }
    }

    enum Work: Hashable {
        case merge(PullRequestRef)
        case agentContext(PullRequestRef)
    }

    let notch: NotchModel
    var shelf: ShelfStore { notch.shelf }

    private(set) var expanded = false
    var dragging = false
    var dropTargeted = false
    /// Bumped once per accepted pulse; the orb's bounce, flare and ripple key off it.
    private(set) var bounceToken = 0
    /// Set by a pulse while the stack is closed; the orb breathes until the user opens the shelf.
    private(set) var hasUnseenEvents = false
    /// How many stack rows are revealed, counted outward from the orb (cards nearest-first, then the header).
    private(set) var revealed = 0
    private(set) var feedback: Feedback?
    var confirmingMerge: PullRequestRef?
    var mergeMethods: [PullRequestRef: MergeMethod] = [:]
    private(set) var work: Set<Work> = []

    @ObservationIgnored private var feedbackTask: Task<Void, Never>?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var closing = false

    static let revealStagger: Duration = .milliseconds(40)
    /// Once the opening stagger finishes, rows added later appear immediately.
    private static let revealAll = Int.max

    init(notch: NotchModel) {
        self.notch = notch
    }

    // MARK: Presentation

    var corner: ShelfCorner { notch.settings.shelf.corner }
    var theme: Theme { Theme(appearance: notch.settings.appearance, notchAttached: false) }
    var motion: Motion { notch.motion }
    var items: [ShelfItem] { shelf.items }
    var readyCount: Int { items.count { $0.status.isReadyToMerge } }
    var failingCount: Int { items.count { $0.status.state == .open && $0.status.checks?.status == .failure } }

    /// Aggregate state for the orb's glow: failing CI needs attention first, then mergeable PRs, then work in
    /// progress (changes requested / CI running); calm accent otherwise.
    var mood: Tone {
        if failingCount > 0 { return .danger }
        if readyCount > 0 { return .success }
        let busy = items.contains {
            $0.status.state == .open && ($0.status.reviewDecision == .changesRequested || $0.status.checks?.status == .pending)
        }
        return busy ? .warn : .accent
    }

    /// Index of a row counted from the orb: cards by recency (nearest first), the header last.
    func revealIndex(of item: ShelfItem) -> Int { items.firstIndex { $0.id == item.id } ?? 0 }
    var headerRevealIndex: Int { items.count }
    func isRevealed(_ index: Int) -> Bool { index < revealed }

    // MARK: Expansion

    func toggle() {
        if expanded, !closing { collapse() } else { expand() }
    }

    /// Rows spring out of the orb one after another; reduced motion fades them in together.
    func expand() {
        revealTask?.cancel()
        closing = false
        hasUnseenEvents = false
        if !expanded { Task { await shelf.refresh() } }
        expanded = true
        let rows = items.count + 1
        if motion.isReduced {
            withAnimation(motion.fade) { revealed = Self.revealAll }
            return
        }
        revealTask = Task { [weak self] in
            guard let self else { return }
            for row in min(revealed, rows)..<rows {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { self.revealed = row + 1 }
                try? await Task.sleep(for: Self.revealStagger)
                if Task.isCancelled { return }
            }
            self.revealed = Self.revealAll
        }
    }

    /// Reverse of `expand()`: the farthest row folds back first. `animated: false` closes at once (dragging, fullscreen).
    func collapse(animated: Bool = true) {
        guard expanded else { return }
        confirmingMerge = nil
        revealTask?.cancel()
        closing = true
        guard animated, !motion.isReduced else {
            if animated {
                withAnimation(motion.fade) { revealed = 0 }
                revealTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    self?.expanded = false
                }
            } else {
                revealed = 0
                expanded = false
            }
            return
        }
        revealTask = Task { [weak self] in
            guard let self else { return }
            var row = min(revealed, items.count + 1)
            while row > 0 {
                row -= 1
                withAnimation(.easeIn(duration: 0.16)) { self.revealed = row }
                try? await Task.sleep(for: .milliseconds(28))
                if Task.isCancelled { return }
            }
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            self.expanded = false
        }
    }

    // MARK: Pulse

    func bounce() {
        bounceToken += 1
        if !expanded { hasUnseenEvents = true }
    }

    // MARK: Card actions

    func isOpening(_ pr: PullRequestStatus) -> Bool { notch.openLocally.isOpening(pr.ref) }

    /// Collapses first: the folder picker and Worktree/Main clone prompt must not sit under the floating stack.
    func openInEditor(_ pr: PullRequestStatus) {
        let opener = notch.openLocally
        collapse()
        Task { await opener.open(repo: pr.ref.repo, number: pr.ref.number, headRefName: pr.headRefName) }
    }

    func worktree(for pr: PullRequestStatus) -> URL? {
        notch.openLocally.knownWorktree(repo: pr.ref.repo, number: pr.ref.number)
    }

    func openOnGitHub(_ pr: PullRequestStatus) {
        NSWorkspace.shared.open(pr.ref.htmlURL)
        collapse()
    }

    func copyBranch(_ pr: PullRequestStatus) {
        ShelfTransfer.copy(pr.headRefName)
        show("Copied \(pr.headRefName)", tone: .success)
    }

    func copyAgentContext(_ pr: PullRequestStatus) {
        let ref = pr.ref
        guard !work.contains(.agentContext(ref)) else { return }
        work.insert(.agentContext(ref))
        Task {
            defer { work.remove(.agentContext(ref)) }
            do throws(GitHubError) {
                let markdown = try await shelf.agentContext(for: ref)
                ShelfTransfer.copy(markdown)
                show("Agent context for #\(ref.number) copied", tone: .success)
            } catch {
                show("Couldn't build context: \(Self.describe(error))", tone: .danger)
            }
        }
    }

    func mergeMethod(for pr: PullRequestStatus) -> MergeMethod? {
        if let chosen = mergeMethods[pr.ref], pr.allowedMergeMethods.contains(chosen) { return chosen }
        return pr.allowedMergeMethods.first
    }

    func requestMerge(_ pr: PullRequestStatus) {
        withAnimation(motion.pop) { confirmingMerge = confirmingMerge == pr.ref ? nil : pr.ref }
    }

    func merge(_ pr: PullRequestStatus) {
        let ref = pr.ref
        guard let method = mergeMethod(for: pr), !work.contains(.merge(ref)) else { return }
        work.insert(.merge(ref))
        Task {
            defer { work.remove(.merge(ref)) }
            do throws(GitHubError) {
                try await shelf.merge(ref, method: method)
                withAnimation(motion.pop) { confirmingMerge = nil }
                show("Merged #\(ref.number) (\(method.title.lowercased()))", tone: .merged)
            } catch {
                show("Merge failed: \(Self.describe(error))", tone: .danger)
            }
        }
    }

    func unpin(_ pr: PullRequestStatus) {
        withAnimation(motion.open) { shelf.unpin(pr.ref) }
        show("Unpinned #\(pr.ref.number)", tone: .neutral)
    }

    // MARK: Drop to pin

    func pin(from providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            guard let url = await ShelfTransfer.pullRequestURL(from: providers), let ref = PullRequestRef(url: url) else {
                show("Drop a GitHub pull request link to pin it", tone: .warn)
                return
            }
            if items.contains(where: { $0.id == ref && $0.isPinned }) {
                show("\(ref.repo.fullName)#\(ref.number) is already pinned", tone: .neutral)
                return
            }
            do throws(ShelfError) {
                try await shelf.pin(ref)
                bounce()
                show("Pinned \(ref.repo.fullName)#\(ref.number)", tone: .success)
            } catch {
                show(Self.describe(error), tone: .danger)
            }
        }
        return true
    }

    // MARK: Feedback

    func show(_ message: String, tone: Tone) {
        feedbackTask?.cancel()
        withAnimation(motion.pop) { feedback = Feedback(message: message, tone: tone) }
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            withAnimation(self.motion.fade) { self.feedback = nil }
        }
    }

    static func describe(_ error: GitHubError) -> String {
        switch error {
        case .auth(let auth): auth.instructions
        case .rateLimited(let reset?): "rate limited until \(Format.time(reset))"
        case .rateLimited: "rate limited by GitHub"
        case .http(let status, let message): message.map { "\($0) (\(status))" } ?? "GitHub returned \(status)"
        case .graphQL(let messages): messages.first ?? "GitHub rejected the request"
        case .decoding: "unexpected response from GitHub"
        case .transport(let message): message
        }
    }

    static func describe(_ error: ShelfError) -> String {
        switch error {
        case .notAPullRequestURL: "Drop a GitHub pull request link to pin it"
        case .notFound: "That pull request doesn't exist or isn't visible to you"
        case .github(let error): "Couldn't pin: \(describe(error))"
        }
    }
}

extension MergeMethod {
    var title: String {
        switch self {
        case .merge: "Merge commit"
        case .squash: "Squash"
        case .rebase: "Rebase"
        }
    }
}

extension ShelfEventKind {
    var title: String {
        switch self {
        case .ciFailed: "CI failed"
        case .ciPassed: "CI passed"
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .newComment: "New comment"
        case .readyToMerge: "Ready to merge"
        case .mergeConflict: "Merge conflict"
        case .merged: "Merged"
        }
    }
}
