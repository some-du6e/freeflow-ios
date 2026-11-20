import SwiftUI

/// Nine glowing white bars on the lavender mic circle, shaped tallest in the
/// middle with the macOS overlay's multipliers and driven by the level.
struct RecorderWaveformView: View {
    static let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1, 0.9, 0.75, 0.55, 0.35]

    let level: Float
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(FreeFlowStyle.micGradient)
                .shadow(color: FreeFlowStyle.accent.opacity(isActive ? 0.45 : 0.15), radius: isActive ? 24 : 10)
            HStack(spacing: 6) {
                ForEach(Self.multipliers.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 6, height: barHeight(index))
                        .shadow(color: .white.opacity(0.7), radius: 4)
                }
            }
            .animation(.easeOut(duration: 0.12), value: level)
        }
        .frame(width: 180, height: 180)
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let minimum: CGFloat = 6
        let maximum: CGFloat = 84
        let shaped = CGFloat(isActive ? max(0, min(1, level)) : 0) * Self.multipliers[index]
        return minimum + (maximum - minimum) * shaped
    }
}

/// Three dots that light up in turn, like the macOS starting indicator.
struct RecorderPulsingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let lit = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(FreeFlowStyle.accent.opacity(index == lit ? 1 : 0.3))
                        .frame(width: 12, height: 12)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
