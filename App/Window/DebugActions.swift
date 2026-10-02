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
