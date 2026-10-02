import Foundation

extension FixtureGitHubService: PullRequestService {
    /// Scripted PR Shelf changes for the debug menu. Apply one, then call `ShelfStore.refresh()`.
    public enum ShelfTransition: String, CaseIterable, Sendable {
        case ciPasses102, requestChanges102, ciFails150, comment150, approve142, ciPasses142, resolveConflict309
        case conflict305, merged305

        public var title: String {
            switch self {
            case .ciPasses102: "Shelf: CI passes on #102"
            case .requestChanges102: "Shelf: request changes on #102"
            case .ciFails150: "Shelf: CI fails on #150"
            case .comment150: "Shelf: new comment on #150"
            case .approve142: "Shelf: approve #142"
            case .ciPasses142: "Shelf: CI passes on #142"
            case .resolveConflict309: "Shelf: resolve conflict on #309"
            case .conflict305: "Shelf: conflict on #305"
            case .merged305: "Shelf: #305 merged on GitHub"
            }
        }
    }

    public func applyShelfTransition(_ transition: ShelfTransition) async {
        let at = now.now()
        state.withLock { state in
            func update(_ repo: String, _ number: Int, _ change: (inout FixtureShelfPR) -> Void) {
                guard let index = state.shelf.firstIndex(where: { $0.ref.repo.name == repo && $0.ref.number == number }) else {
                    return
                }
                change(&state.shelf[index])
                state.shelf[index].updatedAt = at
            }
            func activity(_ login: String, _ verb: ActivityVerb, _ snippet: String?) -> ActivityPreview {
                ActivityPreview(actor: FixtureSeed.person(login), verb: verb, snippet: snippet, at: at)
            }
            switch transition {
            case .ciPasses102:
                update("api", 102) { $0.checks = FixtureSeed.ci($0.headSHA) }
            case .requestChanges102:
                update("api", 102) {
                    $0.reviewDecision = .changesRequested
                    $0.latestHumanActivity = activity("mokafor", .requestedChanges, "Flush on context cancellation too, or a client disconnect leaves the writer blocked.")
                }
            case .ciFails150:
                update("web", 150) {
                    $0.headSHA = "8a2e1f9"
                    $0.checks = FixtureSeed.ci("8a2e1f9", failed: ["typecheck"])
                    $0.logs["typecheck"] = FixtureSeed.typecheckLog
                }
            case .comment150:
                update("web", 150) {
                    $0.latestHumanActivity = activity("schen", .commented, "Pairing on the schema change after standup works for me.")
                }
            case .approve142:
                update("web", 142) {
                    $0.reviewDecision = .approved
                    $0.latestHumanActivity = activity("schen", .approved, "Ref approach looks good. Approving once CI is green.")
                }
            case .ciPasses142:
                update("web", 142) {
                    $0.headSHA = "e41b7c9"
                    $0.checks = FixtureSeed.ci("e41b7c9")
                    $0.logs = [:]
                }
            case .resolveConflict309:
                update("ui-kit", 309) {
                    $0.headSHA = "c92d4a1"
                    $0.mergeable = .mergeable
                    $0.checks = FixtureSeed.ci("c92d4a1")
                }
            case .conflict305:
                update("ui-kit", 305) { $0.mergeable = .conflicting }
            case .merged305:
                update("ui-kit", 305) { $0.state = .merged }
            }
        }
    }

    // MARK: PullRequestService

    public func myOpenPullRequests() async throws(GitHubError) -> [PullRequestStatus] {
        state.withLock { state in
            state.shelf
                .filter { $0.author == FixtureSeed.viewerLogin && $0.state == .open }
                .sorted { $0.updatedAt > $1.updatedAt }
                .map(\.status)
        }
    }

    public func pullRequests(_ refs: [PullRequestRef]) async throws(GitHubError) -> [PullRequestStatus] {
        state.withLock { state in
            refs.compactMap { ref in state.shelf.first { $0.ref == ref }?.status }
        }
    }

    public func merge(_ pr: PullRequestStatus, method: MergeMethod) async throws(GitHubError) {
        let at = now.now()
        let failure: GitHubError? = state.withLock { state in
            guard let index = state.shelf.firstIndex(where: { $0.ref == pr.ref }) else {
                return .http(status: 404, message: "Not Found")
            }
            let current = state.shelf[index]
            guard current.allowedMergeMethods.contains(method) else {
                return .http(status: 405, message: "\(method.rawValue) merges are not allowed on this repository")
            }
            guard current.state == .open, current.status.isReadyToMerge else {
                return .http(status: 405, message: "Pull Request is not mergeable")
            }
            guard current.headSHA == pr.headRefOID else {
                return .http(status: 409, message: "Head branch was modified. Review and try the merge again.")
            }
            state.shelf[index].state = .merged
            state.shelf[index].updatedAt = at
            return nil
        }
        if let failure { throw failure }
    }

    public func agentContext(for ref: PullRequestRef) async throws(GitHubError) -> String {
        let context = state.withLock { state in state.shelf.first { $0.ref == ref }?.agentContext }
        guard let context else { throw .http(status: 404, message: "Not Found") }
        return context.markdown
    }
}
