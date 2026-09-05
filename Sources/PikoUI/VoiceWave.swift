import SwiftUI

/// Connected ribbons share one smoothed voice envelope and taper into a quiet baseline.
/// Drawing stays local to this view, so audio updates never change the keyboard's layout.
public struct VoiceWave: View {
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
                let energy = reduceMotion ? 0.2 : level
                let amplitude = size.height * (0.055 + energy * 0.32)
                let gradient = Gradient(colors: [
                    .cyan.opacity(0), .cyan, tint, .indigo, .indigo.opacity(0)
                ])
                let shading = GraphicsContext.Shading.linearGradient(
                    gradient, startPoint: CGPoint(x: 0, y: size.height / 2),
                    endPoint: CGPoint(x: size.width, y: size.height / 2))

                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height / 2))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.opacity = 0.16
                context.stroke(baseline, with: shading, lineWidth: 1)

                for layer in (0..<3).reversed() {
                    let offset = Double(layer) * 0.85
                    let strength = 1 - Double(layer) * 0.18
                    var ribbon = Path()
                    var line = Path()
                    let thickness = size.height * (0.015 + energy * 0.06) * strength

                    for index in 0...120 {
                        let point = Self.point(index: index, size: size, time: time, offset: offset,
                                               amplitude: amplitude * strength, thickness: -thickness)
                        let middle = Self.point(index: index, size: size, time: time, offset: offset,
                                                amplitude: amplitude * strength, thickness: 0)
                        if index == 0 {
                            ribbon.move(to: point)
                            line.move(to: middle)
                        } else {
                            ribbon.addLine(to: point)
                            line.addLine(to: middle)
                        }
                    }
                    for index in stride(from: 120, through: 0, by: -1) {
                        ribbon.addLine(to: Self.point(index: index, size: size, time: time, offset: offset,
                                                      amplitude: amplitude * strength, thickness: thickness))
                    }
                    ribbon.closeSubpath()
                    context.opacity = (0.15 + level * 0.2) * strength
                    context.fill(ribbon, with: shading)
                    context.opacity = (0.55 + level * 0.4) * strength
                    context.stroke(line, with: shading, style: StrokeStyle(lineWidth: layer == 0 ? 2.5 : 1.5,
                                                                           lineCap: .round, lineJoin: .round))
                }
            }
        }
        .onAppear { isVisible = true; origin = ProcessInfo.processInfo.systemUptime }
        .onDisappear { isVisible = false }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private static func point(index: Int, size: CGSize, time: Double, offset: Double,
                              amplitude: Double, thickness: Double) -> CGPoint {
        let x = Double(index) / 120
        let taper = pow(max(0, sin(.pi * x)), 1.5)
        let wave = sin(x * .pi * 3 - time * 2.4 + offset) * 0.8
            + sin(x * .pi * 5 + time * 1.1 + offset) * 0.2
        return CGPoint(x: x * size.width, y: size.height / 2 + taper * (wave * amplitude + thickness))
    }
}
