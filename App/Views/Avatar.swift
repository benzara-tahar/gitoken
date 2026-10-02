import GitokenCore
import SwiftUI

/// GitHub avatar with an initials + deterministic gradient fallback; bots get a rounded-square glyph.
struct AvatarView: View {
    @Environment(\.theme) private var theme
    var actor: Actor?
    var size: CGFloat
    var badge: ActivityBadge?
    var badgeRing: Color = .clear

    var body: some View {
        face
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    BadgeDot(badge: badge, ring: badgeRing, size: max(13, size * 0.42))
                        .offset(x: 3, y: 3)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .accessibilityLabel(actor?.displayName ?? "Gitoken")
    }

    @ViewBuilder
    private var face: some View {
        if let actor, actor.isBot {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.23, green: 0.25, blue: 0.29), Color(red: 0.09, green: 0.09, blue: 0.11)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay {
                    if let url = actor.avatarURL {
                        RemoteImage(url: url).clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
                    } else {
                        Image(systemName: actor.login.contains("actions") ? "play.fill" : "gearshape.fill")
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(Color(white: 0.85))
                    }
                }
        } else if let actor {
            Circle()
                .fill(gradient(for: actor.login))
                .overlay {
                    if theme.isFluid {
                        Circle().fill(RadialGradient(
                            colors: [.white.opacity(0.32), .clear], center: UnitPoint(x: 0.3, y: 0.15),
                            startRadius: 0, endRadius: size * 0.6
                        ))
                    }
                }
                .overlay {
                    Text(actor.initials)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.18), radius: 0.5, y: 1)
                        .minimumScaleFactor(0.5)
                }
                .overlay {
                    if let url = actor.avatarURL { RemoteImage(url: url).clipShape(Circle()) }
                }
                .overlay { Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5) }
        } else {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Color(white: 0.16))
                .overlay { GitokenGlyph().stroke(Color.white.opacity(0.85), lineWidth: 1.6).padding(size * 0.26) }
        }
    }

    private func gradient(for login: String) -> LinearGradient {
        let pair = Self.palette[Int(Self.hash(login) % UInt64(Self.palette.count))]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// FNV-1a: stable across launches (unlike `hashValue`).
    private static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return h
    }

    private static let palette: [(Color, Color)] = [
        (Color(hex: 0x5B8CFF), Color(hex: 0xA16BFF)),
        (Color(hex: 0xFF6B8B), Color(hex: 0xFF9A5C)),
        (Color(hex: 0x1FC8A9), Color(hex: 0x3A8DFF)),
        (Color(hex: 0xF7B733), Color(hex: 0xFC5A2A)),
        (Color(hex: 0x8E7DFF), Color(hex: 0x4FC6FF)),
        (Color(hex: 0xFF8FD1), Color(hex: 0xA96BFF)),
        (Color(hex: 0x4ADE80), Color(hex: 0x0E9FA4)),
        (Color(hex: 0xFFA07A), Color(hex: 0xE8C23A)),
        (Color(hex: 0x7C8AA5), Color(hex: 0x38BDF8)),
    ]
}

/// Loaded avatar image that stays transparent (showing the initials underneath) until it arrives.
private struct RemoteImage: View {
    var url: URL

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.15))) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
    }
}

struct BadgeDot: View {
    @Environment(\.theme) private var theme
    var badge: ActivityBadge
    var ring: Color
    var size: CGFloat

    var body: some View {
        Circle()
            .fill(badge.tone.color(theme))
            .overlay {
                Image(systemName: badge.symbol)
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .background(Circle().fill(ring).padding(-2))
            .accessibilityHidden(true)
    }
}

/// Overlapping avatars, newest last (on top).
struct AvatarStack: View {
    var actors: [Actor]
    var size: CGFloat
    var ring: Color
    var badge: ActivityBadge?

    var body: some View {
        HStack(spacing: -size * 0.5) {
            ForEach(Array(actors.enumerated()), id: \.element.login) { index, actor in
                AvatarView(
                    actor: actor, size: size, badge: index == actors.count - 1 ? badge : nil, badgeRing: ring
                )
                .background(Circle().fill(ring).padding(-2))
                .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            if actors.isEmpty {
                AvatarView(actor: nil, size: size, badge: badge, badgeRing: ring)
            }
        }
    }
}

/// The Gitoken mark from the prototype (16-unit grid): a bar, a cup, and a dot.
struct GitokenGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        let o = CGPoint(x: rect.midX - 8 * s, y: rect.midY - 8 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var path = Path()
        path.move(to: p(2.5, 2.75))
        path.addLine(to: p(13.5, 2.75))
        path.move(to: p(5, 2.75))
        path.addLine(to: p(5, 5.75))
        path.addArc(center: p(8, 5.75), radius: 3 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: p(11, 2.75))
        path.addEllipse(in: CGRect(x: o.x + 6.65 * s, y: o.y + 11.4 * s, width: 2.7 * s, height: 2.7 * s))
        return path
    }
}

struct GitokenMark: View {
    var size: CGFloat = 15
    var color: Color = .white

    var body: some View {
        GitokenGlyph()
            .stroke(color, style: StrokeStyle(lineWidth: size / 16 * 1.7, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255
        )
    }
}
