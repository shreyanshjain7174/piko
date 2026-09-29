import SwiftUI
import PikoKit

/// The home stage. A deep gradient with two soft glows that breathe with the session phase —
/// no materials, no blur surfaces, cheap enough for every surface that links PikoUI.
public struct AuroraBackground: View {
    public var phase: SessionPhase
    public var tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(phase: SessionPhase, tint: Color) {
        self.phase = phase
        self.tint = tint
    }

    public var body: some View {
        let glow = phase == .capturing ? 0.30 : phase == .armed ? 0.20 : 0.12
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.04, blue: 0.09),
                         Color(red: 0.04, green: 0.07, blue: 0.16),
                         Color(red: 0.03, green: 0.05, blue: 0.12)],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [tint.opacity(glow), .clear],
                           center: UnitPoint(x: 0.2, y: 0.12), startRadius: 10, endRadius: 460)
            RadialGradient(colors: [Color.cyan.opacity(glow * 0.7), .clear],
                           center: UnitPoint(x: 0.85, y: 0.9), startRadius: 10, endRadius: 420)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.9), value: glow)
        .accessibilityHidden(true)
    }
}

/// Discrete speech bars — the Live Activity's level history. WidgetKit redraws these roughly
/// once a second, so they read as scrolling speech rather than a twitching meter.
public struct LevelBars: View {
    public var levels: [Int]
    public var tint: Color
    public var barWidth: CGFloat
    public var spacing: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(levels: [Int], tint: Color, barWidth: CGFloat = 5, spacing: CGFloat = 4) {
        self.levels = levels
        self.tint = tint
        self.barWidth = barWidth
        self.spacing = spacing
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 0.25)) { context in
            let wave = reduceMotion ? 0.0 : sin(context.date.timeIntervalSinceReferenceDate * 2.2) * 0.06
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, bucket in
                    let fraction = Double(min(max(bucket, 0), 10)) / 10
                    Capsule()
                        .fill(tint.opacity(0.42 + 0.58 * fraction))
                        .frame(width: barWidth)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: max(0.1, fraction + (index == levels.count - 1 ? wave : 0)),
                                     anchor: .bottom)
                        .animation(reduceMotion ? nil : .spring(duration: 0.4), value: bucket)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
