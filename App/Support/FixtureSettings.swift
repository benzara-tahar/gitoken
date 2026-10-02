#if DEBUG
import Foundation
import GitokenCore
import os

/// `--fixtures` launches use an in-memory database so fixture threads start fresh every time; this keeps their
/// Settings (appearance, PR Shelf corner, …) across relaunches in a separate JSON file instead.
@MainActor
final class FixtureSettingsPersistence {
    private let store: InboxStore
    private let url: URL

    init(store: InboxStore, fileManager: FileManager = .default) {
        self.store = store
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        url = support.appending(path: "Gitoken/fixture-settings.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            store.updateSettings { $0 = saved }
        }
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = store.settings
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.save()
                self?.observe()
            }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(store.settings).write(to: url, options: .atomic)
        } catch {
            Logger(subsystem: "io.github.benzara-tahar.Gitoken", category: "fixtures")
                .error("Couldn't save fixture settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
