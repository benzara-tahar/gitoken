import Foundation

public enum GitRemote {
    /// The github.com repository a remote URL points at, for https/http/git/ssh URLs and scp-style `git@github.com:owner/repo.git`.
    /// Nil for other hosts (including SSH host aliases, which can't be resolved without the user's SSH config).
    public static func gitHubRepo(fromRemoteURL raw: String) -> RepoRef? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let path: String
        if url.contains("://") {
            guard let parsed = URLComponents(string: url),
                  let scheme = parsed.scheme?.lowercased(), ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme),
                  let parsedHost = parsed.host
            else { return nil }
            host = parsedHost
            path = parsed.path
        } else {
            // scp-like: [user@]host:path — the colon must come before any slash.
            guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
            let userHost = url[..<colon]
            host = String(userHost.split(separator: "@", omittingEmptySubsequences: false).last ?? userHost)
            path = String(url[url.index(after: colon)...])
        }
        guard ["github.com", "www.github.com"].contains(host.lowercased()) else { return nil }
        var parts = path.split(separator: "/").map(String.init)
        if let last = parts.last, last.lowercased().hasSuffix(".git") { parts[parts.count - 1] = String(last.dropLast(4)) }
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return RepoRef(owner: parts[0], name: parts[1])
    }

    /// GitHub owner and repository names are case-insensitive.
    public static func remote(_ url: String, matches repo: RepoRef) -> Bool {
        guard let found = gitHubRepo(fromRemoteURL: url) else { return false }
        return found.owner.caseInsensitiveCompare(repo.owner) == .orderedSame
            && found.name.caseInsensitiveCompare(repo.name) == .orderedSame
    }
}

/// Validates the folder a user picked as their local clone of a repository.
public struct RepoLocator: Sendable {
    let runner: LocalCommandRunner

    public init(runner: LocalCommandRunner) {
        self.runner = runner
    }

    /// Returns the main working tree of the clone containing `folder` when its `origin` is github.com/`repo`.
    /// Picking a subfolder or a linked worktree resolves to the main clone.
    public func validate(_ folder: URL, for repo: RepoRef) async throws(LocalOpenError) -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .notAGitRepository(path: folder.path)
        }
        let topLevel: URL
        let commonDir: String
        do throws(LocalOpenError) {
            topLevel = URL(fileURLWithPath: try await runner.git(["rev-parse", "--show-toplevel"], in: folder).trimmedOutput, isDirectory: true)
            commonDir = try await runner.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: folder).trimmedOutput
        } catch .commandFailed {
            throw .notAGitRepository(path: folder.path)
        }
        let commonURL = URL(fileURLWithPath: commonDir, isDirectory: true)
        let clone = commonURL.lastPathComponent == ".git" ? commonURL.deletingLastPathComponent() : topLevel

        let origin: String
        do throws(LocalOpenError) {
            origin = try await runner.git(["remote", "get-url", "origin"], in: clone).trimmedOutput
        } catch .commandFailed {
            throw .noOrigin(path: clone.path)
        }
        guard GitRemote.remote(origin, matches: repo) else {
            throw .originMismatch(expected: repo.fullName, found: origin)
        }
        return clone.standardizedFileURL
    }
}

extension String {
    var trimmedOutput: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
