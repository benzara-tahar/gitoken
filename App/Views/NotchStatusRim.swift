import GitokenCore
import SwiftUI

struct NotchStatusRim<S: Shape>: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.motion) private var motion
    let shape: S
    @State private var progress: CGFloat = -1
    @State private var beamOpacity: Double = 0

    private enum Status: Hashable { case starting, ready, unseen, quiet, blocked }
    private struct Pulse: Hashable {
        let status: Status
        let arrival: UUID?
        let updates: Int
        let reduced: Bool
    }

    private var status: Status {
        if case .blocked = model.store.phase { return .blocked }
        if model.store.lastSyncError != nil { return .blocked }
        if model.store.quietReason != nil { return .quiet }
        if model.store.unseenCount > 0 { return .unseen }
        if case .starting = model.store.phase { return .starting }
        return .ready
    }

    private var tint: Color {
        switch status {
        case .starting: Color(hex: 0x85BFFF)
        case .ready: Color(hex: 0x6BD9B0)
        case .unseen: Color(hex: 0x4AA3FF)
        case .quiet: Color(hex: 0xB4A1FF)
        case .blocked: Color(hex: 0xFFB35C)
        }
    }

    var body: some View {
        let arrival = model.visibleArrival
        let pulse = Pulse(status: status, arrival: arrival?.id, updates: arrival?.updateCount ?? 0, reduced: motion.isReduced)
        shape.stroke(
            LinearGradient(colors: [tint.opacity(0.25), tint.opacity(status == .ready ? 0.55 : 0.95)], startPoint: .top, endPoint: .bottom),
            lineWidth: 1.5
        )
        .overlay {
            GeometryReader { geometry in
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, tint, .white, tint, .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 72, height: geometry.size.height + 40)
                    .rotationEffect(.degrees(18))
                    .offset(x: (geometry.size.width + 100) * progress, y: -20)
                    .opacity(beamOpacity)
            }
            .mask(shape.stroke(lineWidth: 2.5))
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: pulse) {
            progress = -1
            beamOpacity = 0
            guard !motion.isReduced else { return }
            beamOpacity = 1
            do {
                try await Task.sleep(for: .milliseconds(50))
                withAnimation(.easeInOut(duration: 1.2)) { progress = 1 }
                try await Task.sleep(for: .milliseconds(1250))
                beamOpacity = 0
            } catch {
                beamOpacity = 0
            }
        }
    }
}
