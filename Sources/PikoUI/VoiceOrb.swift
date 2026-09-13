import SwiftUI
import PikoKit

/// A single breathing object made from three coupled contours. Fixed bounds, no
/// textures, shaders, offscreen blur surfaces, or per-frame observable state writes.
public struct VoiceOrb: View {
    @ObservedObject private var activity: VoiceActivityModel
    private let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var origin = ProcessInfo.processInfo.systemUptime

    public init(activity: VoiceActivityModel, tint: Color) {
        self.activity = activity
        self.tint = tint
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : 1.0 / 30,
                                paused: !isVisible || !activity.isActive || scenePhase == .background)) { _ in
            let uptime = ProcessInfo.processInfo.systemUptime
            let level = activity.level(at: uptime)
            let time = reduceMotion ? 0 : uptime - origin
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let side = min(size.width, size.height)
                let motionLevel = reduceMotion ? 0 : level
                let breath = reduceMotion ? 0 : sin(time * 1.7) * 0.012
                let radius = side * (0.34 + motionLevel * 0.065 + breath)

                let halo = Path(ellipseIn: CGRect(x: center.x - side / 2, y: center.y - side / 2,
                                                  width: side, height: side))
                context.fill(halo, with: .radialGradient(
                    Gradient(colors: [tint.opacity(0.12 + level * 0.12), tint.opacity(0)]),
                    center: center, startRadius: radius * 0.7, endRadius: side / 2))

                for layer in (0..<3).reversed() {
                    let offset = Double(layer) * 0.8
                    let path = Self.contour(center: center, radius: radius + CGFloat(layer) * side * 0.022,
                                            time: time, level: motionLevel, offset: offset)
                    if layer == 0 {
                        // A translucent deep-glass ball: lit core, dark limb, one specular
                        // highlight — the character stays the subject, the orb is the room.
                        context.fill(path, with: .radialGradient(
                            Gradient(colors: [tint.opacity(0.30 + motionLevel * 0.22),
                                              Color.cyan.opacity(0.13 + motionLevel * 0.14),
                                              Color(red: 0.03, green: 0.06, blue: 0.14).opacity(0.86)]),
                            center: CGPoint(x: center.x - radius * 0.22, y: center.y - radius * 0.28),
                            startRadius: 0, endRadius: radius * 1.55))
                        let highlight = CGRect(x: center.x - radius * 0.72, y: center.y - radius * 0.88,
                                               width: radius * 0.95, height: radius * 0.75)
                        context.fill(Path(ellipseIn: highlight), with: .radialGradient(
                            Gradient(colors: [.white.opacity(0.22), .white.opacity(0)]),
                            center: CGPoint(x: highlight.midX, y: highlight.midY),
                            startRadius: 0, endRadius: radius * 0.52))
                    } else {
                        context.fill(path, with: .linearGradient(
                            Gradient(colors: [Color.cyan.opacity(0.25), tint.opacity(0.2 + level * 0.15)]),
                            startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
                            endPoint: CGPoint(x: center.x + radius, y: center.y + radius)))
                    }
                    context.stroke(path, with: .color(.white.opacity(layer == 0 ? 0.35 : 0.2)), lineWidth: 0.7)
                }
            }
        }
        .onAppear { isVisible = true; origin = ProcessInfo.processInfo.systemUptime }
        .onDisappear { isVisible = false }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private static func contour(center: CGPoint, radius: CGFloat, time: Double,
                                level: Double, offset: Double) -> Path {
        Path { path in
            // Integer harmonics close seamlessly; every point shares the same energy envelope.
            let envelope = 0.025 + level * 0.1
            for index in 0..<96 {
                let angle = Double(index) * 2 * .pi / 96
                let wave = sin(3 * angle + time * 1.25 + offset) * 0.55
                    + sin(2 * angle - time * 0.85 + offset) * 0.3
                    + sin(5 * angle + time * 0.6) * 0.15
                let r = radius * CGFloat(1 + envelope * wave)
                let point = CGPoint(
                    x: center.x + CGFloat(cos(angle)) * r,
                    y: center.y + CGFloat(sin(angle)) * r
                )
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}
