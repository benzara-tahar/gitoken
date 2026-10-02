import Foundation

/// Failures of "open locally": every case carries enough to explain itself in an alert.
public enum LocalOpenError: Error, Hashable, Sendable {
    case toolNotFound(tool: String, searched: [String])
    case notAGitRepository(path: String)
    case noOrigin(path: String)
    case originMismatch(expected: String, found: String)
    case dirtyWorkingTree(path: String, files: [String])
    case worktreePathOccupied(path: String)
    case commandFailed(command: String, status: Int32, message: String)
    case timedOut(command: String)
    case editorFailed(message: String)

    public var title: String {
        switch self {
        case .toolNotFound(let tool, _): "\(tool) is not installed"
        case .notAGitRepository: "Not a Git repository"
        case .noOrigin: "No “origin” remote"
        case .originMismatch(let expected, _): "Not a clone of \(expected)"
        case .dirtyWorkingTree: "Main clone has uncommitted changes"
        case .worktreePathOccupied: "Worktree folder already exists"
        case .commandFailed(let command, _, _): "\(command) failed"
        case .timedOut(let command): "\(command) took too long"
        case .editorFailed: "Couldn’t open the editor"
        }
    }

    public var detail: String {
        switch self {
        case .toolNotFound(let tool, let searched):
            return "Gitoken looked in \(searched.joined(separator: ", ")). Install \(tool) (for example with Homebrew) and try again."
        case .notAGitRepository(let path):
            return "\(path) is not inside a Git working tree. Choose the folder of your clone."
        case .noOrigin(let path):
            return "The clone at \(path) has no remote named “origin”."
        case .originMismatch(let expected, let found):
            return "Its origin is \(found), but this pull request belongs to github.com/\(expected)."
        case .dirtyWorkingTree(let path, let files):
            let shown = files.prefix(5).joined(separator: "\n")
            let more = files.count > 5 ? "\n…and \(files.count - 5) more" : ""
            return "Commit or stash the changes in \(path) first, or open the pull request in a worktree.\n\n\(shown)\(more)"
        case .worktreePathOccupied(let path):
            return "\(path) exists but is not a worktree of this clone. Move or delete it, then try again."
        case .commandFailed(_, let status, let message):
            return message.isEmpty ? "It exited with status \(status)." : message
        case .timedOut(let command):
            return "\(command) was stopped after waiting too long. Check your network connection and try again."
        case .editorFailed(let message):
            return message
        }
    }
}

extension LocalOpenError: LocalizedError {
    public var errorDescription: String? { title }
    public var failureReason: String? { detail }
}
