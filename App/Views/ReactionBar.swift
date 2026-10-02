import GitokenCore
import SwiftUI

/// Reaction chips under a description, comment, review, or review comment, plus a picker to add one.
/// GitHub's `addReaction` only adds, so a chip the viewer already reacted with is shown highlighted and inert.
struct ReactionBar: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    let subjectID: String
    let reactions: [ReactionCount]
    let groupID: ThreadID
    @State private var picking = false

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(reactions, id: \.content) { reaction in
                Button {
                    if !reaction.viewerHasReacted { model.react(reaction.content, to: subjectID, in: groupID) }
                } label: {
                    HStack(spacing: 3) {
                        Text(reaction.content.emoji)
                        Text("\(reaction.count)").monospacedDigit()
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(reaction.viewerHasReacted ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Capsule().fill(reaction.viewerHasReacted ? theme.accent.opacity(0.16) : theme.chipBackground))
                    .overlay(Capsule().strokeBorder(reaction.viewerHasReacted ? theme.accent.opacity(0.55) : .clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(reaction.viewerHasReacted ? "You reacted \(reaction.content.emoji)" : "React \(reaction.content.emoji)")
                .accessibilityLabel("\(reaction.content.accessibilityName), \(reaction.count)\(reaction.viewerHasReacted ? ", including you" : "")")
            }
            if picking {
                HStack(spacing: 0) {
                    ForEach(ReactionContent.allCases, id: \.self) { content in
                        Button {
                            picking = false
                            model.react(content, to: subjectID, in: groupID)
                        } label: {
                            Text(content.emoji)
                                .font(.system(size: 14))
                                .frame(width: 26, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("React \(content.accessibilityName)")
                    }
                    Button { picking = false } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Close reactions")
                }
                .padding(.horizontal, 3)
                .background(Capsule().fill(theme.chipBackground))
                .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
            } else {
                Button { picking = true } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 12))
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "plus").font(.system(size: 7, weight: .heavy)).offset(x: 4, y: -3)
                        }
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add reaction")
                .accessibilityLabel("Add reaction")
            }
        }
        .animation(.easeOut(duration: 0.15), value: picking)
        .animation(.easeOut(duration: 0.15), value: reactions)
    }
}

extension ReactionContent {
    var accessibilityName: String {
        switch self {
        case .thumbsUp: "thumbs up"
        case .hooray: "hooray"
        case .eyes: "eyes"
        case .heart: "heart"
        case .rocket: "rocket"
        case .confused: "confused"
        }
    }
}
