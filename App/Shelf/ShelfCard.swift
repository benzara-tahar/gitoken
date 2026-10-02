import GitokenCore
import SwiftUI

/// One pull request on the shelf: identity, status chips, the "Ready to merge" badge, and actions.
/// The whole card drags out as a link (URL, text, rich text, HTML, and the local worktree folder if any).
struct ShelfCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    let model: ShelfModel
    let item: ShelfItem
    @State private var hovering = false
    @State private var sweep: CGFloat = -1

    private var pr: PullRequestStatus { item.status }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            header
            chips
            if let activity = pr.latestHumanActivity { activityLine(activity) }
            actions
            if model.confirmingMerge == pr.ref { mergeConfirmation }
        }
        .padding(.vertical, 12)
        .padding(.leading, 15)
        .padding(.trailing, 12)
        .frame(width: ShelfLayout.cardWidth, alignment: .leading)
        .background(ShelfCardBackground(highlighted: hovering, accent: accent.color(theme), glowing: pr.isReadyToMerge))
        .overlay { highlightSweep(shape) }
        .contentShape(shape)
        .scaleEffect(hovering && !motion.isReduced ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { inside in
            hovering = inside
            guard inside, !motion.isReduced else { return }
            sweep = -1
            withAnimation(.easeOut(duration: 0.75)) { sweep = 1.4 }
        }
        .onDrag {
            ShelfTransfer.itemProvider(for: pr, worktree: model.worktree(for: pr))
        } preview: {
            dragPreview
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pr.ref.repo.fullName) pull request \(pr.ref.number): \(pr.title)")
    }

    /// Status accent along the card's leading edge: what this PR needs next.
    private var accent: Tone {
        if pr.state == .merged { return .merged }
        if pr.state == .closed { return .neutral }
        if pr.isReadyToMerge { return .success }
        if pr.checks?.status == .failure || pr.mergeable == .conflicting { return .danger }
        if pr.reviewDecision == .changesRequested || pr.checks?.status == .pending { return .warn }
        if pr.isDraft { return .neutral }
        return .accent
    }

    /// A soft light band that crosses the card once when the pointer arrives.
    private func highlightSweep(_ shape: RoundedRectangle) -> some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(theme.isFluid ? 0.07 : 0.16), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.45)
                .rotationEffect(.degrees(18))
                .offset(x: sweep * geo.size.width)
                .frame(maxHeight: .infinity)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .opacity(sweep > -1 && sweep < 1.4 ? 1 : 0)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            KindIcon(kind: .pullRequest, state: pr.isDraft ? .draft : pr.state, size: 12)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(pr.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text("\(pr.ref.repo.fullName) #\(pr.ref.number)")
                        .lineLimit(1)
                    Text("·").foregroundStyle(.tertiary)
                    Label(pr.headRefName, systemImage: "arrow.branch")
                        .labelStyle(CompactLabelStyle())
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(pr.headRefName)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(35))
                    .padding(.top, 3)
                    .help("Pinned")
                    .accessibilityLabel("Pinned")
            }
        }
    }

    // MARK: Status

    private var chips: some View {
        ShelfFlow(spacing: 5) {
            if pr.isReadyToMerge {
                ReadyToMergeBadge()
            }
            if pr.state == .merged {
                ShelfChip(text: "Merged", symbol: "arrow.triangle.merge", tone: .merged)
            } else if pr.state == .closed {
                ShelfChip(text: "Closed", symbol: "xmark", tone: .danger)
            }
            if pr.isDraft { ShelfChip(text: "Draft", symbol: "pencil", tone: .neutral) }
            if let ci = ciChip { ShelfChip(text: ci.text, symbol: ci.symbol, tone: ci.tone, shimmer: pr.checks?.status == .pending) }
            if let review = reviewChip { ShelfChip(text: review.text, symbol: review.symbol, tone: review.tone) }
            if pr.mergeable == .conflicting { ShelfChip(text: "Conflicts", symbol: "exclamationmark.triangle.fill", tone: .danger) }
            if pr.unresolvedThreadCount > 0 {
                ShelfChip(text: "\(pr.unresolvedThreadCount) unresolved", symbol: "bubble.left.and.exclamationmark.bubble.right", tone: .warn)
            }
        }
    }

    private var ciChip: (text: String, symbol: String, tone: Tone)? {
        guard let checks = pr.checks else { return nil }
        switch checks.status {
        case .success: return ("CI passed", "checkmark", .success)
        case .failure:
            let n = checks.failedChecks.count
            return (n > 0 ? "\(n) failing" : "CI failed", "xmark", .danger)
        case .pending:
            return (checks.pendingCount > 0 ? "CI running · \(checks.pendingCount)" : "CI running", "clock", .warn)
        case .neutral: return ("CI neutral", "minus", .neutral)
        }
    }

    private var reviewChip: (text: String, symbol: String, tone: Tone)? {
        switch pr.reviewDecision {
        case .approved: ("Approved", "checkmark.seal.fill", .success)
        case .changesRequested: ("Changes requested", "exclamationmark.bubble.fill", .danger)
        case .reviewRequired: ("Review required", "eye", .neutral)
        case .none: nil
        }
    }

    private func activityLine(_ activity: ActivityPreview) -> some View {
        let sentence = activity.sentence(viewer: model.notch.viewerLogin)
        let lead = [sentence.who, sentence.what].compactMap { $0 }.joined(separator: " ")
        return HStack(spacing: 6) {
            AvatarView(actor: activity.actor, size: 18, badge: activity.verb.badge, badgeRing: theme.isFluid ? .black : Color(nsColor: .windowBackgroundColor))
            (Text(lead).fontWeight(.medium) + Text(activity.snippet.map { ": \(Format.plain($0, limit: 90))" } ?? ""))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(Format.ago(activity.at, now: model.notch.store.now.now()))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 2) {
            if pr.isReadyToMerge, pr.viewerCanMerge, !pr.allowedMergeMethods.isEmpty {
                ShelfMergeButton { model.requestMerge(pr) }
                    .padding(.trailing, 4)
                    .accessibilityHint("Asks for confirmation before merging")
            }
            CardIconButton(symbol: "chevron.left.forwardslash.chevron.right", label: "Open in editor", busy: model.isOpening(pr)) {
                model.openInEditor(pr)
            }
            CardIconButton(symbol: "safari", label: "Open on GitHub") { model.openOnGitHub(pr) }
            CardIconButton(symbol: "arrow.branch", label: "Copy branch name") { model.copyBranch(pr) }
            CardIconButton(symbol: "sparkles", label: "Copy agent context", busy: model.work.contains(.agentContext(pr.ref))) {
                model.copyAgentContext(pr)
            }
            Spacer(minLength: 0)
            if item.isPinned {
                CardIconButton(symbol: "pin.slash", label: "Unpin") { model.unpin(pr) }
            }
        }
    }

    private var mergeConfirmation: some View {
        let method = model.mergeMethod(for: pr)
        let merging = model.work.contains(.merge(pr.ref))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Merge \(pr.headRefName) into \(pr.baseRefName)?")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if pr.allowedMergeMethods.count > 1 {
                Picker("Merge method", selection: Binding(
                    get: { method ?? .merge },
                    set: { model.mergeMethods[pr.ref] = $0 }
                )) {
                    ForEach(pr.allowedMergeMethods, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            HStack(spacing: 6) {
                Spacer()
                PillButton(title: "Cancel", kind: .ghost) { model.requestMerge(pr) }
                PillButton(title: merging ? "Merging…" : "Confirm \((method ?? .merge).title.lowercased())", symbol: merging ? nil : "checkmark", kind: .primary) {
                    model.merge(pr)
                }
                .disabled(merging || method == nil)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.success.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.success.opacity(0.25), lineWidth: 0.5))
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    private var dragPreview: some View {
        HStack(spacing: 6) {
            KindIcon(kind: .pullRequest, state: pr.state, size: 11)
            Text(ShelfTransfer.linkTitle(pr)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: 300)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
    }
}

/// Green "Ready to merge" badge (approved, green CI, no conflicts, not a draft).
struct ReadyToMergeBadge: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 10, weight: .bold))
            Text("Ready to merge").font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(LinearGradient(colors: [theme.success.opacity(0.95), theme.success.opacity(0.75)], startPoint: .top, endPoint: .bottom)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
        .shadow(color: theme.success.opacity(0.6), radius: 6)
        .fixedSize()
        .accessibilityLabel("Ready to merge")
    }
}

/// Card surface with depth: glass (Calm) or near-black (Fluid), a luminous top edge, a glowing status accent along the
/// leading edge, and a soft green halo when the PR is ready to merge.
struct ShelfCardBackground: View {
    @Environment(\.theme) private var theme
    var highlighted = false
    var accent: Color?
    var glowing = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let fluid = theme.isFluid
        surface(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(fluid ? 0.28 : 0.6), location: 0),
                            .init(color: .white.opacity(fluid ? 0.06 : 0.12), location: 0.25),
                            .init(color: .white.opacity(fluid ? 0.04 : 0.08), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .overlay(alignment: .leading) {
                if let accent {
                    Capsule()
                        .fill(LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3)
                        .padding(.vertical, 12)
                        .padding(.leading, 5)
                        .shadow(color: accent.opacity(fluid ? 0.9 : 0.6), radius: 4)
                }
            }
            .shadow(color: glowing ? theme.success.opacity(fluid ? 0.45 : 0.3) : .clear, radius: 16)
            .shadow(color: .black.opacity((fluid ? 0.45 : 0.18) + (highlighted ? 0.12 : 0)), radius: highlighted ? 20 : 14, y: highlighted ? 12 : 8)
    }

    @ViewBuilder
    private func surface(_ shape: RoundedRectangle) -> some View {
        if theme.isFluid {
            shape.fill(LinearGradient(colors: [Color(white: highlighted ? 0.13 : 0.1), Color(white: 0.045)], startPoint: .top, endPoint: .bottom))
        } else {
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(highlighted ? 0.55 : 0.45))
                .background(GlassBackground(shape: shape))
                .clipShape(shape)
        }
    }
}

/// Status chip on tinted glass; `shimmer` sweeps a light band across it (CI running).
struct ShelfChip: View {
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    var text: String
    var symbol: String
    var tone: Tone
    var shimmer = false
    @State private var phase: CGFloat = -1

    var body: some View {
        let color = tone.color(theme)
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(color.opacity(theme.isFluid ? 0.17 : 0.13)))
        .overlay(Capsule().strokeBorder(color.opacity(theme.isFluid ? 0.35 : 0.28), lineWidth: 0.5))
        .overlay {
            if shimmer, !motion.isReduced {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, color.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width)
                }
                .clipShape(Capsule())
                .allowsHitTesting(false)
                .onAppear {
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.5 }
                }
            }
        }
        .fixedSize()
    }
}

/// Prominent green Merge button with a soft glow.
struct ShelfMergeButton: View {
    @Environment(\.theme) private var theme
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 11.5, weight: .bold))
                Text("Merge").font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [Color(red: 0.25, green: 0.8, blue: 0.45), Color(red: 0.1, green: 0.6, blue: 0.3)],
                    startPoint: .top, endPoint: .bottom
                ))
            )
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .shadow(color: theme.success.opacity(hovering ? 0.75 : 0.5), radius: hovering ? 10 : 6, y: 2)
            .brightness(hovering ? 0.05 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel("Merge")
    }
}

private struct CardIconButton: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var label: String
    var busy = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(width: 28, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Left-to-right wrapping layout for status chips.
struct ShelfFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
