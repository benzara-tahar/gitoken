import GitokenCore
import SwiftUI

/// The arrival announcement. Merged events keep the same `Arrival.id`: the avatar stack and
/// "N updates" badge update in place and the dismiss timer re-arms, without replaying the entrance.
struct ArrivalBannerView: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    let arrival: Arrival
    var width: CGFloat
    @State private var hoverEnded = false
    /// The arrival whose entrance timer has been armed; later updates to it are merges.
    @State private var armedID: UUID?

    private struct TimerKey: Hashable {
        var id: UUID
        var count: Int
        var hovered: Bool
    }

    var body: some View {
        let banded = theme.isFluid && theme.notchAttached
        VStack(spacing: 0) {
            if banded {
                SurfaceHeader(width: width) {
                    HStack(spacing: 5) {
                        GitokenMark(size: 12, color: .secondary)
                        Text("Gitoken").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.tertiary)
                } trailing: {
                    Text(arrival.updateCount > 1 ? "\(arrival.updateCount) updates" : "now")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText(value: Double(arrival.updateCount)))
                }
            }
            Button { model.openArrival(arrival) } label: { row }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityText)
                .accessibilityHint("Opens the conversation")
                .debugNotchMenu(model)
        }
        .frame(width: width, height: banded ? model.host.topInset + 66 : (theme.isFluid ? 70 : 66))
        .onHover { hovering in
            if !hovering, model.bannerHovered { hoverEnded = true }
            model.bannerHovered = hovering
        }
        .task(id: TimerKey(id: arrival.id, count: arrival.updateCount, hovered: model.bannerHovered)) {
            guard !model.bannerHovered else { return }
            let fresh = armedID != arrival.id
            armedID = arrival.id
            let seconds: Double
            if hoverEnded {
                seconds = 2.4
            } else if arrival.isSummary {
                seconds = 5.6
            } else {
                seconds = fresh ? 4.8 : 3.6
            }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            hoverEnded = false
            withAnimation(motion.close) { model.store.dismissArrival() }
        }
        .onChange(of: arrival.id) { hoverEnded = false }
    }

    private var row: some View {
        HStack(spacing: theme.isFluid ? 14 : 12) {
            AvatarStack(actors: actors, size: theme.bannerAvatar, ring: ringColor, badge: badge)
                .animation(motion.pop, value: actors.map(\.login))
            VStack(alignment: .leading, spacing: 1) {
                lineOne
                    .id(lineOneKey)
                    .transition(.asymmetric(
                        insertion: .offset(y: 6).combined(with: .opacity), removal: .opacity
                    ))
                lineTwo
            }
            .animation(motion.pop, value: lineOneKey)
            .frame(maxWidth: .infinity, alignment: .leading)
            if arrival.updateCount > 1 {
                Text("\(arrival.updateCount) updates")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(arrival.updateCount)))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(theme.accent))
                    .keyframeAnimator(initialValue: 1.0, trigger: arrival.updateCount) { content, s in
                        content.scaleEffect(s)
                    } keyframes: { _ in
                        SpringKeyframe(motion.isReduced ? 1 : 1.22, duration: 0.15)
                        SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
                    }
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(motion.pop, value: arrival.updateCount > 1)
        .padding(.leading, theme.isFluid ? 18 : 14)
        .padding(.trailing, theme.isFluid ? 20 : 16)
        .padding(.bottom, theme.isFluid ? 4 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var ringColor: Color {
        theme.isFluid ? .black : Color(nsColor: .windowBackgroundColor)
    }

    private var group: InboxGroup? { arrival.groupID.flatMap(model.group) }

    private var actors: [Actor] {
        if !arrival.actors.isEmpty { return Array(arrival.actors.suffix(3)) }
        if let last = group?.actors.last { return [last] }
        return []
    }

    private var badge: ActivityBadge? {
        switch arrival.kind {
        case .activity(_, let latest, _): latest.verb.badge
        case .snoozeEnded: ActivityBadge(symbol: "clock", tone: .neutral)
        case .summary: nil
        case .morningSummary: ActivityBadge(symbol: "sun.max.fill", tone: .warn)
        }
    }


    private var lineOneKey: String {
        switch arrival.kind {
        case .activity(_, let latest, let reopened):
            "\(latest.actor?.login ?? "")|\(latest.verb.rawValue)|\(reopened)|\(latest.at.timeIntervalSince1970)"
        case .snoozeEnded(let id): "snooze|\(id)"
        case .summary(let updates, let groups, _, _): "summary|\(updates)|\(groups)"
        case .morningSummary(let summary): "morning|\(summary.updates)|\(summary.conversations)"
        }
    }

    @ViewBuilder
    private var lineOne: some View {
        let font = Font.system(size: theme.isFluid ? 14 : 13)
        switch arrival.kind {
        case .activity(_, let latest, let reopened):
            let s = latest.sentence(viewer: model.viewerLogin)
            HStack(spacing: 6) {
                if reopened { BannerTag(text: "Back in inbox") }
                (Text(s.who.map { "\($0) " } ?? "").fontWeight(.semibold) + Text(s.what + ciDetail(latest)))
                    .font(font)
                    .lineLimit(1)
            }
        case .snoozeEnded:
            let n = group?.unseenCount ?? 0
            (Text("Snooze ended").fontWeight(.semibold) + Text(n > 0 ? " · \(Format.plural(n, "new update"))" : ""))
                .font(font)
                .lineLimit(1)
        case .summary(_, _, _, let reason):
            Text(summaryTitle(reason)).fontWeight(.semibold).font(font).lineLimit(1)
        case .morningSummary(let summary):
            Text(morningTitle(summary)).fontWeight(.semibold).font(font).lineLimit(1)
        }
    }

    @ViewBuilder
    private var lineTwo: some View {
        let font = Font.system(size: 12)
        switch arrival.kind {
        case .summary(let updates, let groups, _, _):
            Text("\(Format.plural(updates, "update")) in \(Format.plural(groups, "conversation")) while you were away")
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .morningSummary(let summary):
            Text(repoLine(summary))
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        default:
            if let g = group {
                (Text("\(g.thread.repo.fullName)\(g.thread.number.map { " #\($0)" } ?? "")")
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.isFluid ? .secondary : .primary)
                    + Text("  ·  ").foregroundStyle(.tertiary)
                    + Text(g.thread.title).foregroundStyle(.secondary))
                    .font(font)
                    .lineLimit(1)
            }
        }
    }

    /// CI arrivals have no actor subject, so the failing check names ride along on the first line.
    private func ciDetail(_ preview: ActivityPreview) -> String {
        guard !preview.verb.hasActorSubject, let snippet = preview.snippet, !snippet.isEmpty else { return "" }
        return " · \(Format.plain(snippet, limit: 60))"
    }

    private func summaryTitle(_ reason: QuietReason) -> String {
        switch reason {
        case .globalSnooze: "Snooze ended"
        case .quietHours: "Quiet hours ended"
        case .manual: "Quiet mode off"
        }
    }

    private func morningTitle(_ summary: MorningSummary) -> String {
        return "Overnight: \(Format.plural(summary.updates, "update")) in \(Format.plural(summary.conversations, "conversation"))"
    }

    /// "platform/web 4 · platform/api 3 · ui-kit 1": the owner is dropped once it repeats the first repo's.
    private func repoLine(_ summary: MorningSummary) -> String {
        guard let firstOwner = summary.topRepos.first?.repo.owner else { return "Nothing new in your inbox" }
        return summary.topRepos.enumerated().map { index, entry in
            let name = index > 0 && entry.repo.owner == firstOwner ? entry.repo.name : entry.repo.fullName
            return "\(name) \(entry.updates)"
        }.joined(separator: "  ·  ")
    }

    private var accessibilityText: String {
        switch arrival.kind {
        case .activity(_, let latest, let reopened):
            let s = latest.sentence(viewer: model.viewerLogin)
            let ref = group.map { "\($0.thread.repo.fullName) \($0.thread.number.map { "#\($0)" } ?? ""): \($0.thread.title)" } ?? ""
            return "\(reopened ? "Back in inbox. " : "")\(s.who ?? "") \(s.what). \(ref). \(arrival.updateCount > 1 ? "\(arrival.updateCount) updates" : "")"
        case .snoozeEnded: return "Snooze ended. \(group?.thread.title ?? "")"
        case .summary(let updates, let groups, _, let reason):
            return "\(summaryTitle(reason)). \(updates) updates in \(groups) conversations"
        case .morningSummary(let summary):
            return [morningTitle(summary), repoLine(summary)].joined(separator: ". ")
        }
    }
}

private struct BannerTag: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(hex: 0xE39A00)))
            .fixedSize()
    }
}

private extension Arrival {
    /// Summaries carry more to read, so they stay up longer.
    var isSummary: Bool {
        switch kind {
        case .summary, .morningSummary: true
        case .activity, .snoozeEnded: false
        }
    }
}
