import AppKit
import GitokenCore
import Observation

/// "Open in editor" for a pull request: locate the clone (asked once per repo), check the PR out in a worktree or the
/// main clone, and launch the configured editor. Every failure ends in an alert; callers just `await open(…)`.
@Observable
final class OpenLocallyCoordinator {
    private let store: InboxStore
    private(set) var opening: Set<PullRequestRef> = []
    /// Worktrees opened this session that live outside the conventional `pr-<n>` folder (reused branch worktrees).
    @ObservationIgnored private var sessionWorktrees: [PullRequestRef: URL] = [:]

    init(store: InboxStore) {
        self.store = store
    }

    func isOpening(_ ref: PullRequestRef) -> Bool { opening.contains(ref) }

    /// The worktree folder for this PR when one exists on disk (for drag-out file URLs). Never runs git.
    func knownWorktree(repo: RepoRef, number: Int) -> URL? {
        let ref = PullRequestRef(repo: repo, number: number)
        if let url = sessionWorktrees[ref], Self.isWorktree(url) { return url }
        let conventional = WorktreeManager.path(root: store.settings.worktreeRoot, repo: repo, number: number)
        return Self.isWorktree(conventional) ? conventional : nil
    }

    func open(repo: RepoRef, number: Int, headRefName: String) async {
        let ref = PullRequestRef(repo: repo, number: number)
        guard opening.insert(ref).inserted else { return }
        defer { opening.remove(ref) }
        do throws(LocalOpenError) {
            let runner = LocalCommandRunner(tools: try LocalTools.locate())
            guard let clone = try await resolveClone(for: repo, runner: runner) else { return }
            let conventional = WorktreeManager.path(root: store.settings.worktreeRoot, repo: repo, number: number)
            let existing = try? await WorktreeManager(runner: runner).existing(clone: clone, branch: headRefName, conventionalPath: conventional)
            guard var mode = askMode(ref, headRefName: headRefName, clone: clone, existingWorktree: existing) else { return }
            let checkout = CheckoutService(runner: runner)
            let result: CheckoutResult
            do throws(LocalOpenError) {
                result = try await checkout.checkout(
                    ref, headRefName: headRefName, clone: clone, mode: mode, worktreeRoot: store.settings.worktreeRoot)
            } catch .dirtyWorkingTree(let path, let files) {
                let error = LocalOpenError.dirtyWorkingTree(path: path, files: files)
                guard confirm(error.title, detail: error.detail, action: "Use a Worktree") else { return }
                mode = .worktree
                result = try await checkout.checkout(
                    ref, headRefName: headRefName, clone: clone, mode: mode, worktreeRoot: store.settings.worktreeRoot)
            }
            if mode == .worktree { sessionWorktrees[ref] = result.folder }
            try await EditorLauncher.launch(store.settings.editor, folder: result.folder)
        } catch {
            showError(error)
        }
    }

    /// Settings › "Change…": pick (and validate) a new folder for a remembered repository.
    func changeClone(for fullName: String) async {
        let parts = fullName.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return }
        do throws(LocalOpenError) {
            let runner = LocalCommandRunner(tools: try LocalTools.locate())
            _ = try await chooseClone(for: RepoRef(owner: parts[0], name: parts[1]), runner: runner)
        } catch {
            showError(error)
        }
    }

    func forgetClone(for fullName: String) {
        store.updateSettings { $0.repoPaths[fullName] = nil }
    }

    func chooseWorktreeRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose where Gitoken creates pull request worktrees"
        panel.prompt = "Use Folder"
        let current = URL(fileURLWithPath: (store.settings.worktreeRoot as NSString).expandingTildeInPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: current.path) { panel.directoryURL = current }
        raise(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.updateSettings { $0.worktreeRoot = Self.abbreviate(url) }
    }

    // MARK: Clone location

    private func resolveClone(for repo: RepoRef, runner: LocalCommandRunner) async throws(LocalOpenError) -> URL? {
        if let saved = savedPath(for: repo) {
            do throws(LocalOpenError) {
                let clone = try await RepoLocator(runner: runner).validate(URL(fileURLWithPath: saved, isDirectory: true), for: repo)
                remember(clone, for: repo)
                return clone
            } catch .toolNotFound(let tool, let searched) {
                throw .toolNotFound(tool: tool, searched: searched)
            } catch {
                let retry = confirm(
                    "Can’t use your clone of \(repo.fullName)", detail: "\(error.detail)\n\nChoose its folder again?",
                    action: "Choose Folder…")
                guard retry else { return nil }
            }
        }
        return try await chooseClone(for: repo, runner: runner)
    }

    /// Folder picker until the user picks a valid clone or cancels.
    private func chooseClone(for repo: RepoRef, runner: LocalCommandRunner) async throws(LocalOpenError) -> URL? {
        var startAt = savedPath(for: repo).map { URL(fileURLWithPath: $0, isDirectory: true).deletingLastPathComponent() }
        while true {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.message = "Choose your local clone of github.com/\(repo.fullName)"
            panel.prompt = "Use This Clone"
            if let startAt { panel.directoryURL = startAt }
            raise(panel)
            guard panel.runModal() == .OK, let folder = panel.url else { return nil }
            do throws(LocalOpenError) {
                let clone = try await RepoLocator(runner: runner).validate(folder, for: repo)
                remember(clone, for: repo)
                return clone
            } catch .toolNotFound(let tool, let searched) {
                throw .toolNotFound(tool: tool, searched: searched)
            } catch {
                guard confirm(error.title, detail: error.detail, action: "Choose Another Folder…") else { return nil }
                startAt = folder.deletingLastPathComponent()
            }
        }
    }

    private func savedPath(for repo: RepoRef) -> String? {
        store.settings.repoPaths.first { $0.key.caseInsensitiveCompare(repo.fullName) == .orderedSame }?.value
    }

    private func remember(_ clone: URL, for repo: RepoRef) {
        store.updateSettings { settings in
            for key in settings.repoPaths.keys where key.caseInsensitiveCompare(repo.fullName) == .orderedSame {
                settings.repoPaths[key] = nil
            }
            settings.repoPaths[repo.fullName] = clone.path
        }
    }

    // MARK: Prompts

    private func askMode(_ ref: PullRequestRef, headRefName: String, clone: URL, existingWorktree: URL?) -> CheckoutMode? {
        let alert = NSAlert()
        alert.messageText = "Open \(ref.repo.fullName) #\(ref.number) locally"
        let branch = headRefName.isEmpty ? "the pull request" : "“\(headRefName)”"
        if let existingWorktree, existingWorktree.standardizedFileURL != clone.standardizedFileURL {
            alert.informativeText = "Worktree reopens \(Self.abbreviate(existingWorktree)) as it is. "
                + "Main clone switches \(Self.abbreviate(clone)) to \(branch)."
        } else {
            alert.informativeText = "Worktree checks out \(branch) in a separate folder under \(store.settings.worktreeRoot). "
                + "Main clone switches \(Self.abbreviate(clone)) to it."
        }
        alert.addButton(withTitle: "Worktree")
        alert.addButton(withTitle: "Main Clone")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        raise(alert.window)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .worktree
        case .alertSecondButtonReturn: return .mainClone
        default: return nil
        }
    }

    private func confirm(_ title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        raise(alert.window)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ error: LocalOpenError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error.title
        alert.informativeText = error.detail
        alert.addButton(withTitle: "OK")
        raise(alert.window)
        alert.runModal()
    }

    /// Gitoken is an agent app whose panels float at status-bar level and never activate it. The user just asked for
    /// this prompt, so take activation outright (cooperative `activate()` can leave it without keyboard focus)
    /// and lift the prompt above the panels.
    private func raise(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    }

    private static func isWorktree(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    static func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
