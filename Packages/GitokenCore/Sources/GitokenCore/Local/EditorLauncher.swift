import Foundation
import Synchronization

public struct EditorCommand: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
}

public enum EditorLauncher {
    public static func command(for editor: EditorChoice, folder: URL) -> EditorCommand {
        switch editor {
        case .vscode: EditorCommand(executable: "/usr/bin/open", arguments: ["-a", "Visual Studio Code", folder.path])
        case .zed: EditorCommand(executable: "/usr/bin/open", arguments: ["-a", "Zed", folder.path])
        case .custom(let template): EditorCommand(executable: "/bin/zsh", arguments: ["-lc", script(template: template, path: folder.path)])
        }
    }

    /// Substitutes the shell-quoted path for `{path}`; a placeholder the user already wrapped in quotes is replaced whole,
    /// and a template without one gets the path appended.
    static func script(template: String, path: String) -> String {
        let quoted = shellQuote(path)
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("{path}") else { return "\(trimmed) \(quoted)" }
        return trimmed
            .replacingOccurrences(of: "\"{path}\"", with: quoted)
            .replacingOccurrences(of: "'{path}'", with: quoted)
            .replacingOccurrences(of: "{path}", with: quoted)
    }

    /// POSIX single-quoting: safe for spaces, `$`, backticks, and embedded single quotes.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs the editor command. Quick failures (app not installed, command not found, non-zero exit) throw;
    /// a command still running after `grace` seconds is assumed to be the editor itself and is left running.
    public static func launch(
        _ editor: EditorChoice, folder: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
        grace: TimeInterval = 8
    ) async throws(LocalOpenError) {
        if case .custom(let template) = editor, template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw .editorFailed(message: "The custom editor command is empty. Set one in Settings › Open locally.")
        }
        let command = command(for: editor, folder: folder)
        let outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(command, environment: environment, grace: grace))
            }
        }
        switch outcome {
        case .stillRunning, .exited(0, _):
            return
        case .exited(let status, let stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw .editorFailed(message: message.isEmpty ? "\(command.executable) exited with status \(status)." : message)
        case .launchFailed(let message):
            throw .editorFailed(message: message)
        }
    }

    private enum Outcome: Sendable {
        case exited(Int32, String)
        case stillRunning
        case launchFailed(String)
    }

    private static func run(_ command: EditorCommand, environment: [String: String], grace: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .launchFailed(error.localizedDescription)
        }
        // Keep draining after a detach so a long-lived editor never blocks on a full pipe.
        let errorText = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errorText.set(stderr.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }
        guard exited.wait(timeout: .now() + grace) == .success else { return .stillRunning }
        _ = drained.wait(timeout: .now() + 1)
        return .exited(process.terminationStatus, String(decoding: errorText.get(), as: UTF8.self))
    }

    private final class OutputBox: Sendable {
        private let data = Mutex(Data())
        func set(_ value: Data) { data.withLock { $0 = value } }
        func get() -> Data { data.withLock { $0 } }
    }
}
