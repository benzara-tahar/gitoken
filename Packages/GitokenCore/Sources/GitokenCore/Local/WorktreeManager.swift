import Foundation

/// One entry of `git worktree list --porcelain`.
public struct Worktree: Hashable, Sendable {
    public var path: URL
    public var head: String?
    /// Short branch name (`refs/heads/` stripped); nil when detached.
    public var branch: String?
    public var isBare = false
    /// Registered but its folder is gone.
    public var isPrunable = false
}

public struct WorktreeManager: Sendable {
    let runner: LocalCommandRunner

    public init(runner: LocalCommandRunner) {
        self.runner = runner
    }

    /// `<root>/<owner>/<repo>/pr-<n>`, with a leading `~` in `root` expanded against `home`.
    public static func path(root: String, repo: RepoRef, number: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let expanded: URL
        if root == "~" {
            expanded = home
        } else if root.hasPrefix("~/") {
            expanded = home.appendingPathComponent(String(root.dropFirst(2)), isDirectory: true)
        } else {
            expanded = URL(fileURLWithPath: root, isDirectory: true)
        }
        return expanded
            .appendingPathComponent(repo.owner, isDirectory: true)
            .appendingPathComponent(repo.name, isDirectory: true)
            .appendingPathComponent("pr-\(number)", isDirectory: true)
            .standardizedFileURL
    }

    static func parsePorcelain(_ text: String) -> [Worktree] {
        var result: [Worktree] = []
        var current: Worktree?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current { result.append(current) }
                current = Worktree(path: URL(fileURLWithPath: String(line.dropFirst("worktree ".count)), isDirectory: true).standardizedFileURL)
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = line.dropFirst("branch ".count)
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
            } else if line == "bare" {
                current?.isBare = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.isPrunable = true
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// Worktrees of the clone whose folders still exist. The first entry is the main working tree.
    public func list(clone: URL) async throws(LocalOpenError) -> [Worktree] {
        Self.parsePorcelain(try await runner.git(["worktree", "list", "--porcelain"], in: clone))
            .filter { !$0.isBare && !$0.isPrunable }
    }

    /// A worktree already holding this PR: a linked worktree on `branch` (preferred), the conventional `pr-<n>` folder,
    /// or the main clone when it is the one on `branch` (git refuses to check a branch out twice).
    public func existing(clone: URL, branch: String, conventionalPath: URL) async throws(LocalOpenError) -> URL? {
        let worktrees = try await list(clone: clone)
        let linked = worktrees.dropFirst()
        if !branch.isEmpty, let match = linked.first(where: { $0.branch == branch }) { return match.path }
        let target = Self.canonicalPath(conventionalPath)
        if let match = linked.first(where: { Self.canonicalPath($0.path) == target }) { return match.path }
        if !branch.isEmpty, let main = worktrees.first, main.branch == branch { return main.path }
        return nil
    }

    /// `git worktree add --detach <path>`, then `gh pr checkout <n>` inside it so forks get their remote and tracking branch.
    /// A worktree whose checkout fails is removed again so the next attempt starts clean.
    public func create(clone: URL, pullRequest: PullRequestRef, at path: URL) async throws(LocalOpenError) -> URL {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: path.path), !contents.isEmpty {
            throw .worktreePathOccupied(path: path.path)
        }
        do {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .commandFailed(command: "Create worktree folder", status: -1, message: error.localizedDescription)
        }
        try await runner.git(["worktree", "prune"], in: clone)
        try await runner.git(["worktree", "add", "--detach", path.path], in: clone)
        do throws(LocalOpenError) {
            try await runner.gh(["pr", "checkout", String(pullRequest.number), "--repo", pullRequest.repo.fullName], in: path)
        } catch {
            _ = try? await runner.git(["worktree", "remove", "--force", path.path], in: clone)
            throw error
        }
        return path
    }

    /// realpath(3): unlike `resolvingSymlinksInPath`, keeps `/private`, so it compares equal to the paths git prints.
    static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
