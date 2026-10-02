import Foundation

/// Absolute paths of the `git` and `gh` executables used by "open locally".
/// GUI apps don't inherit the login shell's PATH, so well-known install locations are probed before `$PATH` entries.
public struct LocalTools: Hashable, Sendable {
    public static let defaultDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/run/current-system/sw/bin"]

    public var git: String
    public var gh: String

    public init(git: String, gh: String) {
        self.git = git
        self.gh = gh
    }

    public static func locate(
        directories: [String] = defaultDirectories,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(LocalOpenError) -> LocalTools {
        LocalTools(
            git: try find("git", directories: directories, environment: environment),
            gh: try find("gh", directories: directories, environment: environment))
    }

    static func find(_ name: String, directories: [String], environment: [String: String]) throws(LocalOpenError) -> String {
        let fromPATH = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let ordered = (directories + fromPATH)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .filter { seen.insert($0).inserted }
        guard let found = ordered.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw .toolNotFound(tool: name, searched: ordered)
        }
        return found
    }
}

/// Runs `git` / `gh` non-interactively in a given folder.
public struct LocalCommandRunner: Sendable {
    public let tools: LocalTools
    let environment: [String: String]
    let timeout: TimeInterval

    /// - Parameters:
    ///   - baseEnvironment: inherited by every command; the tools' folders are prepended to its `PATH` so `gh` finds the same `git`.
    ///   - timeout: seconds before a hung command is terminated (fetches of large repositories can be slow).
    public init(tools: LocalTools, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = 300) {
        self.tools = tools
        self.timeout = timeout
        var env = baseEnvironment
        let toolDirs = [tools.git, tools.gh].map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        let inherited = (baseEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (toolDirs + inherited + ["/usr/bin", "/bin"]).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_SPINNER_DISABLED"] = "1"
        environment = env
    }

    @discardableResult
    public func git(_ arguments: [String], in directory: URL) async throws(LocalOpenError) -> String {
        try await run(tools.git, display: "git \(arguments.first ?? "")", arguments, in: directory)
    }

    @discardableResult
    public func gh(_ arguments: [String], in directory: URL) async throws(LocalOpenError) -> String {
        try await run(tools.gh, display: "gh \(arguments.prefix(2).joined(separator: " "))", arguments, in: directory)
    }

    private func run(_ executable: String, display: String, _ arguments: [String], in directory: URL)
        async throws(LocalOpenError) -> String
    {
        let result = await ProcessRunner.run(
            executable: executable, arguments: arguments, environment: environment, timeout: timeout, currentDirectory: directory)
        switch result {
        case .launchFailed(let message):
            throw .commandFailed(command: display, status: -1, message: message)
        case .timedOut:
            throw .timedOut(command: display)
        case .exited(let status, let stdout, let stderr):
            guard status == 0 else {
                let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw .commandFailed(
                    command: display, status: status,
                    message: message.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : message)
            }
            return stdout
        }
    }
}
