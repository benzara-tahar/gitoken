import AppKit
import GitokenCore
import SwiftUI

struct MonitorPullRequestButton: View {
    @Environment(NotchModel.self) private var model
    let ref: PullRequestRef
    var body: some View {
        let monitor = model.store.pullRequestMonitor
        let active = monitor.isMonitoring(ref)
        IconButton(symbol: active ? "bell.badge.fill" : "bell.badge", label: active ? "Stop monitoring PR readiness" : "Monitor PR readiness", active: active) {
            if active { monitor.stopMonitoring(ref) } else {
                monitor.monitor(ref)
                Task { await monitor.refresh(announce: model.store.quietReason == nil) }
            }
        }
    }
}

struct PullRequestMonitorSettings: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var url = ""
    @State private var inputError: String?
    var body: some View {
        let monitor = model.store.pullRequestMonitor
        VStack(alignment: .leading, spacing: 10) {
            Text("Monitored pull requests").font(.system(size: 12, weight: .semibold))
            Text("Monitor any PR you can access. A special sound and green glow announce when checks and required approvals are ready. Alerts respect quiet mode and full-screen apps.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                TextField("https://github.com/owner/repo/pull/123", text: $url)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .onSubmit { add() }
                Button("Monitor") { add() }.disabled(monitor.accountLogin == nil)
            }
            if let inputError { Text(inputError).font(.system(size: 11)).foregroundStyle(theme.warn) }
            if monitor.currentRecords.isEmpty {
                Text("No PRs monitored yet").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(monitor.currentRecords) { record in
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        Button("\(record.ref.repo.fullName) #\(record.ref.number)") { NSWorkspace.shared.open(record.ref.htmlURL) }
                            .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium))
                        Text(monitor.errors[record.id]?.briefDescription ?? monitor.statuses[record.id]?.statusText ?? "Waiting for next poll")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Stop") { monitor.stopMonitoring(record.ref) }.font(.system(size: 11))
                }
            }
        }.padding(.vertical, 12)
    }
    private func add() {
        guard let ref = PullRequestRef(urlString: url) else {
            inputError = "Enter a GitHub pull request link (https://github.com/owner/repo/pull/123)."
            return
        }
        model.store.pullRequestMonitor.monitor(ref)
        url = ""; inputError = nil
        Task { await model.store.pullRequestMonitor.refresh(announce: model.store.quietReason == nil) }
    }
}

struct ReadyPullRequestBanner: View {
    @Environment(NotchModel.self) private var model
    let ready: ReadyPullRequest
    let width: CGFloat
    @State private var glowing = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 28)).foregroundStyle(.green)
                .scaleEffect(glowing && !model.motion.isReduced ? 1.12 : 1)
                .shadow(color: .green.opacity(glowing ? 0.6 : 0.2), radius: glowing ? 12 : 4)
            VStack(alignment: .leading, spacing: 3) {
                Text("PR ready to merge").font(.system(size: 13, weight: .bold))
                Text("\(ready.ref.repo.fullName) #\(ready.ref.number)").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(ready.title).font(.system(size: 12)).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { model.store.pullRequestMonitor.dismissNotification() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss ready notification")
        }
        .padding(16).frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(ready.ref.htmlURL)
            model.store.pullRequestMonitor.dismissNotification()
        }
        .task(id: ready.id) {
            if !model.motion.isReduced {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { glowing = true }
            }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, model.store.pullRequestMonitor.notification?.id == ready.id else { return }
            model.store.pullRequestMonitor.dismissNotification()
        }
    }
}
