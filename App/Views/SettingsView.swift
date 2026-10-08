import AppKit
import GitokenCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case notifications = "Notifications"
    case sections = "Sections"
}

struct SettingsView: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    var width: CGFloat
    var maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    private var tab: SettingsTab { model.settingsTab }

    private var backTitle: String {
        if let previous = model.navigationState.history.dropLast().last {
            switch previous {
            case .conversation, .searchConversation: return "Conversation"
            default: break
            }
        }
        return "Inbox"
    }

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader(width: width) {
                BackButton(title: backTitle) { model.back() }
            } trailing: {
                Text("Settings").font(.system(size: 13.5, weight: .semibold)).padding(.trailing, 4)
            }
            Picker("Settings tab", selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 })) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Settings tab")
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            ScrollView {
                content
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, max(200, maxHeight - 76)))
        }
        .frame(width: width)
        .onAppear {
            loginStatus = SMAppService.mainApp.status
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLogo(width: 132)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            switch tab {
            case .general: generalSettings
            case .notifications: notificationSettings
            case .sections: CustomSectionsSettings()
            }

            Text(footer)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
        }
    }

    private var generalSettings: some View {
        let store = model.store
        let s = store.settings
        return VStack(alignment: .leading, spacing: 0) {
            section("Preset", first: true) {
                HStack(spacing: 8) {
                    PresetCard(appearance: .calm, title: "Calm", subtitle: "Native glass · gentle fades", selected: s.appearance == .calm) {
                        store.updateSettings { $0 = AppSettings.preset(.calm, keeping: $0) }
                    }
                    PresetCard(appearance: .fluid, title: "Fluid", subtitle: "Dark island · elastic", selected: s.appearance == .fluid) {
                        store.updateSettings { $0 = AppSettings.preset(.fluid, keeping: $0) }
                    }
                }
            }
            card {
                row("Motion", last: true) {
                    segmented(MotionStyle.allCases, selection: s.motion, label: { $0.rawValue.capitalized }) { v in
                        store.updateSettings { $0.motion = v }
                    }
                }
            }
            .padding(.top, 10)
            if model.systemReduceMotion {
                note("Reduce motion is on in System Settings, so animations stay minimal.")
            }

            section("Display") {
                card {
                    row("Shape", last: true) {
                        segmented(DisplayMode.allCases, selection: s.display, label: { $0 == .notch ? "Hardware notch" : "Floating pill" }) { v in
                            store.updateSettings { $0.display = v }
                        }
                    }
                }
                note(model.host.hasNotch ? "Floating pill sits below the menu bar instead of hugging the notch." : "This display has no notch, so Gitoken uses the floating pill.")
            }
            KeyboardSettingsSection()
            SavedRepliesSettingsSection()
            section("General") {
                card {
                    row("Launch at login", detail: loginDetail) {
                        Toggle("Launch at login", isOn: Binding(get: { loginStatus == .enabled }, set: { setLaunchAtLogin($0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    row("Quit Gitoken", last: true) {
                        Button("Quit") { NSApp.terminate(nil) }
                            .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.danger))
                    }
                }
                if loginStatus == .requiresApproval {
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.top, 6)
                        .padding(.horizontal, 4)
                }
            }

            #if DEBUG
            DebugSettingsSection(width: width)
            #endif
        }
    }

    private var notificationSettings: some View {
        let store = model.store
        let s = store.settings
        return VStack(alignment: .leading, spacing: 0) {
            NotificationTypesSettingsSection()
            section("Sound") {
                card {
                    row("Arrival sound") {
                        segmented(ArrivalSound.allCases, selection: s.sound, label: \.title) { v in
                            store.updateSettings { $0.sound = v }
                            if v != .off { model.sounds.play(v, volume: s.soundVolume, reason: "preview") }
                        }
                    }
                    row("Volume", last: true) {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Slider(
                                value: Binding(get: { s.soundVolume }, set: { v in store.updateSettings { $0.soundVolume = v } }),
                                in: 0...1
                            ) { editing in
                                guard !editing else { return }
                                let current = store.settings
                                model.sounds.play(current.sound, volume: current.soundVolume, reason: "preview")
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 150)
                            .accessibilityLabel("Sound volume")
                            Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .disabled(s.sound == .off)
                        .opacity(s.sound == .off ? 0.45 : 1)
                    }
                }
                note("Plays once per new arrival. Quiet mode, quiet hours, snooze and full-screen apps keep it silent.")
            }

            section("AI reviews") {
                card {
                    row("In conversations", detail: "Copilot, CodeRabbit and other review bots") {
                        segmented(AIReviewDisplay.allCases, selection: s.aiReviews, label: \.title) { v in
                            store.updateSettings { $0.aiReviews = v }
                        }
                    }
                    row("Notify for AI reviews", detail: "Arrivals and sounds for AI-only activity", last: true) {
                        Toggle("Notify for AI reviews", isOn: Binding(get: { s.notifyAIReviews }, set: { v in store.updateSettings { $0.notifyAIReviews = v } }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }

            section("Focus") {
                card {
                    row("Quiet mode", detail: "Collect activity without arrival animations") {
                        Toggle("Quiet mode", isOn: Binding(get: { store.manualQuiet }, set: { store.setManualQuiet($0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    row("Quiet hours") {
                        Toggle("Quiet hours", isOn: Binding(get: { s.quietHours.enabled }, set: { v in store.updateSettings { $0.quietHours.enabled = v } }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    HStack(spacing: 8) {
                        Text("From")
                        ClockPicker(label: "Quiet hours start", time: s.quietHours.start) { t in store.updateSettings { $0.quietHours.start = t } }
                        Text("to")
                        ClockPicker(label: "Quiet hours end", time: s.quietHours.end) { t in store.updateSettings { $0.quietHours.end = t } }
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 36)
                    .disabled(!s.quietHours.enabled)
                    .opacity(s.quietHours.enabled ? 1 : 0.45)
                    .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
                    row("Snooze all", last: true) { snoozeAllControls }
                }
                if let status = model.quietStatus {
                    Label(status, systemImage: "moon.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .labelStyle(TintedIconLabelStyle(tint: theme.quiet))
                        .padding(.top, 8)
                        .padding(.horizontal, 4)
                }
            }
            MutedSettingsSection()
        }
    }

    // MARK: Pieces

    private var snoozeAllControls: some View {
        let store = model.store
        let now = store.now.now()
        return Group {
            if let until = store.globalSnoozeUntil, until > now {
                HStack(spacing: 6) {
                    Text("Until \(Format.until(until, now: now))").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Resume") { model.resumeAll() }.buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(SnoozeOption.allCases) { option in
                        Button(short(option)) { model.snoozeAll(option) }
                            .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                            .help("Snooze all notifications for \(option.title.lowercased())")
                    }
                }
            }
        }
    }

    private func short(_ option: SnoozeOption) -> String {
        switch option {
        case .thirtyMinutes: "30m"
        case .oneHour: "1h"
        case .untilTomorrow: "Tomorrow"
        }
    }

    private var loginDetail: String? {
        if let loginError { return loginError }
        switch loginStatus {
        case .requiresApproval: return "Needs approval in System Settings › Login Items"
        default: return nil
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
        let enabled = loginStatus == .enabled
        model.store.updateSettings { $0.launchAtLogin = enabled }
    }

    private var footer: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        var text = "Gitoken \(version)"
        if case .ready(let viewer) = model.store.phase { text += " · @\(viewer.login)" }
        if let synced = model.store.lastSyncAt { text += " · synced \(Format.time(synced))" }
        return text
    }


    private func section<C: View>(_ title: String, first: Bool = false, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.top, first ? 2 : 14)
    }

    private func card<C: View>(@ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.settingsCard))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
    }

    private func row<C: View>(_ title: String, detail: String? = nil, last: Bool = false, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 40)
        .padding(.vertical, detail == nil ? 0 : 6)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(theme.hairline).frame(height: 0.5) }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .padding(.top, 6)
    }

    private func segmented<V: Hashable & Sendable>(
        _ values: [V], selection: V, label: @escaping (V) -> String, set: @escaping @MainActor (V) -> Void
    ) -> some View {
        Picker("", selection: Binding(get: { selection }, set: { set($0) })) {
            ForEach(values, id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

private struct PresetCard: View {
    @Environment(\.theme) private var theme
    var appearance: Appearance
    var title: String
    var subtitle: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                preview
                    .frame(height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title).font(.system(size: 12.5, weight: .semibold)).padding(.top, 4).padding(.horizontal, 4)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
            .padding(6)
            .padding(.bottom, 2)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.settingsCard))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? theme.accent : theme.hairline, lineWidth: selected ? 2 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) preset: \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var preview: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0x2C2F6E), Color(hex: 0x8B5A9E), Color(hex: 0xF2A477)], startPoint: .top, endPoint: .bottom)
            if appearance == .calm {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(white: 0.97, opacity: 0.85))
                    .frame(width: 70, height: 44)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule().fill(Color.black.opacity(0.18)).frame(width: 46, height: 4)
                            Capsule().fill(Color.black.opacity(0.1)).frame(width: 46, height: 4)
                            Capsule().fill(Color.black.opacity(0.1)).frame(width: 46, height: 4)
                        }
                        .padding(7)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 3)
                    .padding(.top, 11)
                UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3).fill(Color.black).frame(width: 34, height: 7)
            } else {
                UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 76, height: 50)
                    .overlay(alignment: .top) {
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.11)).frame(height: 12)
                            RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.11)).frame(height: 12)
                        }
                        .padding(.horizontal, 9)
                        .padding(.top, 14)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 7, y: 3)
            }
        }
    }
}

private struct ClockPicker: View {
    var label: String
    var time: ClockTime
    var set: (ClockTime) -> Void

    var body: some View {
        DatePicker(
            label,
            selection: Binding(
                get: { Calendar.current.date(byAdding: .minute, value: time.minutes, to: Calendar.current.startOfDay(for: Date())) ?? Date() },
                set: { date in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                    set(ClockTime(hour: c.hour ?? 0, minute: c.minute ?? 0))
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .datePickerStyle(.field)
        .controlSize(.small)
        .fixedSize()
    }
}

struct SmallButtonStyle: ButtonStyle {
    var theme: Theme
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : theme.isFluid ? 0.09 : 0.06))
            )
            .contentShape(Rectangle())
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint).font(.system(size: 11))
            configuration.title
        }
    }
}

#if DEBUG
/// Hidden in release builds: drives the fixture service and the offset clock to demo arrivals and snooze expiry.
private struct DebugSettingsSection: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    var width: CGFloat

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: 6) {
            Text("Debug")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("Clock").font(.system(size: 12.5))
                    Spacer()
                    Button("+30 min") { model.debugAdvanceClock(by: 30 * 60) }
                    Button("+1 hour") { model.debugAdvanceClock(by: 3600) }
                    Button("+1 day") { model.debugAdvanceClock(by: 86400) }
                }
                .buttonStyle(SmallButtonStyle(theme: theme, tint: nil))
                Text("Now: \(store.now.now().formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                if store.fixtureService != nil {
                    HStack(spacing: 4) {
                        Button("Send notification") { model.debugFixture(closePanel: true) { await $0.enqueueNotification() } }
                        Button("Burst") { model.debugFixture(closePanel: true) { await $0.enqueueBurst() } }
                        Button("Activity on done") { model.debugFixture(closePanel: true) { await $0.enqueueActivityOnDoneThread() } }
                    }
                    .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.settingsCard))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
        }
        .padding(.top, 14)
    }
}
#endif
