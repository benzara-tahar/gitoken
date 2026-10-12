#if DEBUG
import GitokenCore
import SwiftUI

/// Debug-only demo hooks: advance the offset clock, and script fixture activity (`--fixtures` launches).
extension NotchModel {
    func debugAdvanceClock(by seconds: TimeInterval) {
        guard let clock = store.now as? OffsetNow else { return }
        clock.advance(by: seconds)
        store.tick()
        if route.isOpen { showToast("Clock advanced to \(Format.time(clock.now()))") }
    }

    /// Fixture activity lands on the next poll. Arrivals only announce while the panel is closed.
    func debugFixture(closePanel: Bool, _ action: @escaping @Sendable (FixtureGitHubService) async -> Void) {
        guard let fixtures = store.fixtureService else { return }
        if closePanel { close() }
        let store = store
        Task {
            await action(fixtures)
            await store.refresh()
        }
    }

    /// `--fixtures --scene <inbox|conversation|preview|review|settings> [owner/repo#number]` opens a fixed view once
    /// fixture data has loaded, so README screenshots can be reproduced without clicking through the UI.
    func debugOpenScene(_ scene: String, subject: String?) {
        guard store.fixtureService != nil else { return }
        Task {
            while store.groups.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            let fallback = ["conversation": "platform/api#87"][scene] ?? "platform/web#142"
            let id = debugGroup(subject ?? fallback)?.id
            switch scene {
            case "inbox": open(.list)
            case "settings": open(.list); open(.settings)
            case "conversation", "preview", "review":
                guard let id else { return }
                open(.list); open(.conversation(id))
                guard scene != "conversation" else { return }
                while store.detail(for: id) == nil { try? await Task.sleep(for: .milliseconds(100)) }
                if scene == "review" {
                    previewController?.showFiles(for: id)
                } else if let target = newestPreviewTarget(for: id) {
                    previewController?.show(target)
                    previewController?.debugPlaceBesideSurface(width: surfaceWidth(.conversation(id)))
                }
            default: return
            }
        }
    }

    private func debugGroup(_ subject: String) -> InboxGroup? {
        let parts = subject.split(separator: "#")
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        return store.groups.first {
            "\($0.thread.repo.owner)/\($0.thread.repo.name)" == parts[0] && $0.thread.number == number
        }
    }
}

/// Screenshot scenes: an opaque full-screen gradient just below Gitoken's panels, so their glass samples it instead of
/// the desktop and other apps. `scripts/compose-screenshot.swift` paints the same gradient and skips this window by title.
@MainActor
enum ScreenshotBackdrop {
    static let title = "Gitoken Screenshot Backdrop"
    private static var window: NSWindow?

    static func show(below panel: NSWindow) {
        guard window == nil, let screen = panel.screen ?? NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.title = title
        window.level = NSWindow.Level(panel.level.rawValue - 1)
        window.isOpaque = true
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = GradientView()
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window
    }

    private final class GradientView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSGradient(colors: [NSColor(srgbRed: 0.11, green: 0.10, blue: 0.20, alpha: 1),
                                NSColor(srgbRed: 0.33, green: 0.22, blue: 0.45, alpha: 1),
                                NSColor(srgbRed: 0.78, green: 0.47, blue: 0.47, alpha: 1)])!
                .draw(in: bounds, angle: -70)
        }
    }
}

/// Right-click menu on the notch in debug builds; works while a banner is showing, so merges can be demoed.
struct DebugNotchMenu: View {
    let model: NotchModel

    var body: some View {
        if model.store.fixtureService != nil {
            Button("Send Notification") { model.debugFixture(closePanel: false) { await $0.enqueueNotification() } }
            Button("Burst on Pull Request") { model.debugFixture(closePanel: false) { await $0.enqueueBurst() } }
            Button("Activity on Done Thread") { model.debugFixture(closePanel: false) { await $0.enqueueActivityOnDoneThread() } }
            Divider()
        }
        Button("Advance Clock 30 Minutes") { model.debugAdvanceClock(by: 30 * 60) }
        Button("Advance Clock 1 Hour") { model.debugAdvanceClock(by: 3600) }
        Button("Advance Clock 1 Day") { model.debugAdvanceClock(by: 86400) }
    }
}

#endif

import SwiftUI

extension View {
    /// Attaches the debug right-click menu in debug builds; a no-op in release.
    @ViewBuilder
    func debugNotchMenu(_ model: NotchModel) -> some View {
        #if DEBUG
        contextMenu { DebugNotchMenu(model: model) }
        #else
        self
        #endif
    }

}
