import Foundation

/// A single cancellable main-actor loop: optional initial delay, then `body` repeatedly, sleeping for the
/// duration it returns. `body` returning nil ends the loop. Used for the poll loop and the minute timer.
@MainActor
final class RepeatingTask {
    private var task: Task<Void, Never>?
    private var generation = 0

    var isRunning: Bool { task != nil }

    /// Restarts the loop, cancelling any previous run.
    func start(after initialDelay: Duration = .zero, _ body: @escaping @MainActor () async -> Duration?) {
        stop()
        generation += 1
        let generation = generation
        task = Task { [weak self] in
            defer { self?.finished(generation) }
            if initialDelay > .zero {
                guard (try? await Task.sleep(for: initialDelay, tolerance: Self.tolerance(for: initialDelay))) != nil else { return }
            }
            while !Task.isCancelled {
                guard let delay = await body() else { return }
                guard (try? await Task.sleep(for: delay, tolerance: Self.tolerance(for: delay))) != nil else { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func finished(_ generation: Int) {
        if generation == self.generation { task = nil }
    }

    private static func tolerance(for delay: Duration) -> Duration {
        min(.seconds(10), delay / 6)
    }
}
