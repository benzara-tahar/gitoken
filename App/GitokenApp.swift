import AppKit
import GitokenCore
import SwiftUI

@main
struct GitokenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: InboxStore?
    private var notch: NotchController?
    private var preview: PreviewController?
    private var power: PowerObserver?
    #if DEBUG
    private var fixtureSettings: FixtureSettingsPersistence?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = Self.makeStore()
        self.store = store
        #if DEBUG
        if store.fixtureService != nil { fixtureSettings = FixtureSettingsPersistence(store: store) }
        #endif
        let notch = NotchController(store: store)
        self.notch = notch
        preview = PreviewController(notch: notch.model, notchWindow: notch.window)
        power = PowerObserver(
            onPause: { store.pause() },
            onResume: { store.resume() }
        )
        store.start()
    }

    private static func makeStore() -> InboxStore {
        #if DEBUG
        let clock = OffsetNow()
        if CommandLine.arguments.contains("--fixtures") {
            return InboxStore.preview(now: clock)
        }
        #else
        let clock = SystemNow()
        #endif
        do {
            return try InboxStore.live(now: clock)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Gitoken can't open its database"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
    }
}

/// Pauses polling while the Mac sleeps, the displays sleep, or the screen is locked; resumes when all clear.
@MainActor
final class PowerObserver {
    private enum Reason: Hashable { case systemSleep, displaySleep, locked }

    private var reasons: Set<Reason> = []
    private let onPause: () -> Void
    private let onResume: () -> Void
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(onPause: @escaping () -> Void, onResume: @escaping () -> Void) {
        self.onPause = onPause
        self.onResume = onResume
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.set(.systemSleep, true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.set(.systemSleep, false) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.set(.displaySleep, true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.set(.displaySleep, false) }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.set(.locked, true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.set(.locked, false) }
    }

    private func set(_ reason: Reason, _ active: Bool) {
        let wasPaused = !reasons.isEmpty
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        let paused = !reasons.isEmpty
        if paused && !wasPaused { onPause() }
        if !paused && wasPaused { onResume() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (PowerObserver) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        tokens.append((center, token))
    }
}
