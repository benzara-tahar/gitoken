import Foundation
import Synchronization

/// Runs `gh auth token --hostname github.com` from a known install location and caches the token in memory.
/// GUI apps don't inherit the login shell's PATH, so well-known locations are probed before `$PATH` entries.
public final class GHCLITokenProvider: TokenProvider {
    public static let defaultSearchPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh", "/run/current-system/sw/bin/gh"]

    private let searchPaths: [String]
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let state = Mutex(State())

    private struct State {
        var token: String?
        var inFlight: Task<String, any Error>?
        var generation = 0
    }

    /// - Parameters:
    ///   - searchPaths: candidate `gh` executables, probed in order before `environment["PATH"]` entries.
    ///   - environment: environment for the `gh` process; its `PATH` contributes extra candidates.
    ///   - timeout: seconds before a hung `gh` is terminated.
    public init(
        searchPaths: [String] = GHCLITokenProvider.defaultSearchPaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 10
    ) {
        self.searchPaths = searchPaths
        self.environment = environment
        self.timeout = timeout
    }

    public func token() async throws(AuthError) -> String {
        let lookup: Lookup = state.withLock { state in
            if let token = state.token { return .cached(token) }
            if let inFlight = state.inFlight { return .pending(inFlight, generation: state.generation) }
            let task = Task { [searchPaths, environment, timeout] in
                try await Self.fetchToken(searchPaths: searchPaths, environment: environment, timeout: timeout)
            }
            state.inFlight = task
            return .pending(task, generation: state.generation)
        }
        switch lookup {
        case .cached(let token):
            return token
        case .pending(let task, let generation):
            do {
                let token = try await task.value
                state.withLock { state in
                    guard state.generation == generation else { return }
                    state.token = token
                    state.inFlight = nil
                }
                return token
            } catch {
                state.withLock { state in
                    if state.generation == generation { state.inFlight = nil }
                }
                throw (error as? AuthError) ?? .notLoggedIn(detail: error.localizedDescription)
            }
        }
    }

    private enum Lookup {
        case cached(String)
        case pending(Task<String, any Error>, generation: Int)
    }

    public func invalidate() async {
        state.withLock { state in
            state.token = nil
            state.inFlight = nil
            state.generation += 1
        }
    }

    /// Ordered, de-duplicated candidate paths: explicit search paths, then `gh` in each `PATH` directory.
    static func candidates(searchPaths: [String], environment: [String: String]) -> [String] {
        let fromPATH = (environment["PATH"] ?? "")
            .split(separator: ":")
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("gh").path }
        var seen = Set<String>()
        return (searchPaths + fromPATH).filter { seen.insert($0).inserted }
    }

    private static func fetchToken(searchPaths: [String], environment: [String: String], timeout: TimeInterval)
        async throws(AuthError) -> String
    {
        let candidates = candidates(searchPaths: searchPaths, environment: environment)
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw .ghNotInstalled(searched: candidates)
        }
        var processEnvironment = environment
        processEnvironment["GH_PROMPT_DISABLED"] = "1"
        processEnvironment["GH_NO_UPDATE_NOTIFIER"] = "1"
        let result = await ProcessRunner.run(
            executable: executable,
            arguments: ["auth", "token", "--hostname", "github.com"],
            environment: processEnvironment,
            timeout: timeout
        )
        switch result {
        case .launchFailed(let message):
            throw .notLoggedIn(detail: "Could not run \(executable): \(message)")
        case .timedOut:
            throw .notLoggedIn(detail: "gh auth token did not finish within \(String(format: "%g", timeout)) seconds")
        case .exited(let status, let stdout, let stderr):
            let token = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard status == 0 else {
                let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw .notLoggedIn(detail: message.isEmpty ? "gh auth token exited with status \(status)" : message)
            }
            guard !token.isEmpty, !token.contains(where: \.isWhitespace) else {
                throw .notLoggedIn(detail: "gh auth token printed no token")
            }
            return token
        }
    }
}

enum ProcessResult: Sendable {
    case exited(status: Int32, stdout: String, stderr: String)
    case launchFailed(String)
    case timedOut
}

enum ProcessRunner {
    /// Runs the executable on a background queue so callers on the main actor never block.
    static func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval,
        currentDirectory: URL? = nil
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: runBlocking(
                        executable: executable, arguments: arguments, environment: environment, timeout: timeout,
                        currentDirectory: currentDirectory)
                )
            }
        }
    }

    private static func runBlocking(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval,
        currentDirectory: URL?
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently so a chatty child can't fill a pipe buffer and stall.
        let output = DataBox()
        let errorOutput = DataBox()
        let drained = DispatchGroup()
        for (handle, box) in [(stdout.fileHandleForReading, output), (stderr.fileHandleForReading, errorOutput)] {
            DispatchQueue.global(qos: .userInitiated).async(group: drained) {
                box.set(handle.readDataToEndOfFile())
            }
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            exited.wait()
            _ = drained.wait(timeout: .now() + 1)
            return .timedOut
        }
        _ = drained.wait(timeout: .now() + 2)
        return .exited(
            status: process.terminationStatus,
            stdout: String(decoding: output.get(), as: UTF8.self),
            stderr: String(decoding: errorOutput.get(), as: UTF8.self)
        )
    }

    private final class DataBox: Sendable {
        private let data = Mutex(Data())
        func set(_ value: Data) { data.withLock { $0 = value } }
        func get() -> Data { data.withLock { $0 } }
    }
}
