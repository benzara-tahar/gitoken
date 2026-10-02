import Foundation

public enum CheckoutMode: String, Sendable, CaseIterable {
    /// A dedicated worktree under `settings.worktreeRoot`, leaving the main clone untouched.
    case worktree
    /// `gh pr checkout` in the main clone; refused when it has uncommitted changes.
    case mainClone
}

public struct CheckoutResult: Hashable, Sendable {
    public var folder: URL
    /// True when an existing worktree was opened as-is instead of checking the PR out again.
    public var reusedWorktree: Bool
}

public struct CheckoutService: Sendable {
    let runner: LocalCommandRunner
    let worktrees: WorktreeManager

    public init(runner: LocalCommandRunner) {
        self.runner = runner
        worktrees = WorktreeManager(runner: runner)
    }

    public func checkout(
        _ pullRequest: PullRequestRef, headRefName: String, clone: URL, mode: CheckoutMode, worktreeRoot: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws(LocalOpenError) -> CheckoutResult {
        switch mode {
        case .worktree:
            let path = WorktreeManager.path(root: worktreeRoot, repo: pullRequest.repo, number: pullRequest.number, home: home)
            if let existing = try await worktrees.existing(clone: clone, branch: headRefName, conventionalPath: path) {
                return CheckoutResult(folder: existing, reusedWorktree: true)
            }
            return CheckoutResult(folder: try await worktrees.create(clone: clone, pullRequest: pullRequest, at: path), reusedWorktree: false)
        case .mainClone:
            let dirty = try await changedFiles(in: clone)
            guard dirty.isEmpty else { throw .dirtyWorkingTree(path: clone.path, files: dirty) }
            try await runner.gh(["pr", "checkout", String(pullRequest.number), "--repo", pullRequest.repo.fullName], in: clone)
            return CheckoutResult(folder: clone, reusedWorktree: false)
        }
    }

    /// Staged or unstaged changes to tracked files. Untracked files don't block a checkout unless they collide,
    /// in which case git itself refuses with a precise message.
    public func changedFiles(in clone: URL) async throws(LocalOpenError) -> [String] {
        try await runner.git(["status", "--porcelain", "--untracked-files=no"], in: clone)
            .split(separator: "\n")
            .map { String($0.dropFirst(3)) }
            .filter { !$0.isEmpty }
    }
}
