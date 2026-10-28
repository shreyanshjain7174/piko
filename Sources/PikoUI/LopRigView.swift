import SwiftUI

/// Lop drawn every display frame from `LopPhysics`: the in-app, fluid version of the island
/// character. Pure SwiftUI (`TimelineView` + `Canvas`), no dependency, so it is light enough for
/// any target that links PikoUI.
///
/// The island cannot run this: Live Activities show held frames only. This view is for the app
/// and anywhere else SwiftUI is allowed to tick.
public struct LopRigView: View {
    private let inputs: LopInputs
    private let fur: Color
    private let soft: Bool

    @State private var sim = LopSimulation()
    @State private var touch: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - soft: the shaded app render. `false` draws the flat island look.
    public init(inputs: LopInputs, fur: Color = LopRigView.cream, soft: Bool = true) {
        self.inputs = inputs
        self.fur = fur
        self.soft = soft
    }

    public static let cream = Color(red: 1, green: 0.957, blue: 0.875)

    public var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { context, size in
                var live = inputs
                if let touch {
                    live.patting = true
                    live.lookAt = CGPoint(x: touch.x / size.width * 120, y: touch.y / size.height * 120)
                }
                let pose = sim.pose(at: timeline.date, inputs: live)
                LopPainter(fur: fur, soft: soft).draw(pose, in: &context, size: size)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { touch = $0.location }
                .onEnded { _ in touch = nil }
        )
        .accessibilityElement()
        .accessibilityLabel("Lop")
        .accessibilityHint("Stroke to pat")
    }
}

/// Holds the physics between frames. A reference type so stepping it from the Canvas closure
/// does not invalidate the view; the TimelineView already redraws every frame.
@MainActor
final class LopSimulation {
    private var physics = LopPhysics(seed: UInt64.random(in: 0...UInt64.max))
    private var last: Date?

    func pose(at date: Date, inputs: LopInputs) -> LopPose {
        let dt = last.map { date.timeIntervalSince($0) } ?? 0
        last = date
        return physics.step(dt: max(0, dt), inputs: inputs)
    }
}

/// Turns a pose into strokes. The geometry is the sketch canvas's, in a 120-unit square.
struct LopPainter {
    let fur: Color
    let soft: Bool

    private static let ink = Color(red: 0.12, green: 0.10, blue: 0.09)
    private static let pink = Color(red: 0.97, green: 0.73, blue: 0.64)
    private static let coral = Color(red: 0.91, green: 0.57, blue: 0.48)
    private static let earWidth = 13.0
    private static let earLength = 44.0

    func draw(_ pose: LopPose, in context: inout GraphicsContext, size: CGSize) {
        context.scaleBy(x: size.width / 120, y: size.height / 120)

        let rx = 27 * pose.squashX, ry = 23 * pose.squashY
        let cy = 106 - ry
        let top = cy - ry
        let body = CGRect(x: 60 - rx, y: cy - ry, width: rx * 2, height: ry * 2)

        if soft {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 2.4))
                layer.fill(Path(ellipseIn: CGRect(x: 60 - 26 * pose.squashX, y: 103, width: 52 * pose.squashX, height: 8)),
                           with: .color(Color(red: 0.54, green: 0.44, blue: 0.32).opacity(0.35)))
            }
        }

        drawEar(at: CGPoint(x: 51, y: top + 10), angle: pose.earLeft, fold: pose.foldLeft, in: &context)
        drawEar(at: CGPoint(x: 69, y: top + 10), angle: pose.earRight, fold: pose.foldRight, in: &context)
        context.fill(Path(ellipseIn: body), with: furShading(in: body))

        var face = context
        face.translateBy(x: 0, y: (1 - pose.squashY) * 18)
        drawFace(pose, in: &face)
    }

    private func furShading(in rect: CGRect) -> GraphicsContext.Shading {
        guard soft else { return .color(fur) }
        let center = CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.28)
        return .radialGradient(
            Gradient(colors: [fur.mix(with: .white, by: 0.6), fur, fur.mix(with: Color(red: 0.6, green: 0.45, blue: 0.3), by: 0.28)]),
            center: center, startRadius: 0, endRadius: max(rect.width, rect.height) * 0.85)
    }

    private func drawEar(at anchor: CGPoint, angle: Double, fold: Double, in context: inout GraphicsContext) {
        let w = Self.earWidth, base = Self.earLength * 0.62, tip = Self.earLength * 0.42
        var ear = context
        ear.translateBy(x: anchor.x, y: anchor.y)
        ear.rotate(by: .degrees(angle))

        let baseRect = CGRect(x: -w / 2, y: -base, width: w, height: base)
        // One gradient along the ear's length, split at the fold: shaded at the root, lit at the
        // tip, and the same colour on both sides of the joint so the fold never shows a seam.
        let root = soft ? fur.mix(with: Color(red: 0.6, green: 0.45, blue: 0.3), by: 0.22) : fur
        let joint = fur
        let end = soft ? fur.mix(with: .white, by: 0.45) : fur
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [root, joint]), startPoint: .zero, endPoint: CGPoint(x: 0, y: -base))
        let innerShading: GraphicsContext.Shading = soft
            ? .linearGradient(Gradient(colors: [Self.pink, Self.coral]), startPoint: CGPoint(x: 0, y: -base - tip), endPoint: .zero)
            : .color(Self.pink)

        ear.fill(Path(baseRect), with: shading)
        ear.fill(Path(ellipseIn: CGRect(x: -w / 2, y: -base + 1 - w / 2, width: w, height: w)), with: shading)
        ear.fill(Path(CGRect(x: -w * 0.22, y: -base, width: w * 0.44, height: base)), with: innerShading)
        ear.fill(Path(ellipseIn: CGRect(x: -w * 0.22, y: -base + 1 - w * 0.22, width: w * 0.44, height: w * 0.44)), with: innerShading)

        var tipContext = ear
        tipContext.translateBy(x: 0, y: -base + 1)
        tipContext.rotate(by: .degrees(fold))
        let tipShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [joint, end]), startPoint: .zero, endPoint: CGPoint(x: 0, y: -tip))
        let tipInner: GraphicsContext.Shading = soft
            ? .linearGradient(Gradient(colors: [Self.pink, Self.coral]), startPoint: CGPoint(x: 0, y: -tip), endPoint: CGPoint(x: 0, y: base))
            : .color(Self.pink)
        tipContext.fill(Self.leaf(length: tip + 3, width: w), with: tipShading)
        tipContext.fill(Self.leaf(length: tip * 0.75, width: w * 0.44), with: tipInner)
    }

    private static func leaf(length: Double, width: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: -width / 2, y: 0))
        p.addCurve(to: CGPoint(x: 0, y: -length),
                   control1: CGPoint(x: -width / 2, y: -length * 0.55),
                   control2: CGPoint(x: -width * 0.45, y: -length))
        p.addCurve(to: CGPoint(x: width / 2, y: 0),
                   control1: CGPoint(x: width * 0.45, y: -length),
                   control2: CGPoint(x: width / 2, y: -length * 0.55))
        p.closeSubpath()
        return p
    }

    private func drawFace(_ pose: LopPose, in context: inout GraphicsContext) {
        let ink = GraphicsContext.Shading.color(Self.ink)
        for x in [52.0, 68.0] {
            let eye = CGPoint(x: x + pose.gaze.x, y: 82 + pose.gaze.y)
            if pose.happyEyes {
                var arc = Path()
                arc.move(to: CGPoint(x: x - 4.5, y: 83))
                arc.addQuadCurve(to: CGPoint(x: x + 4.5, y: 83), control: CGPoint(x: x, y: 78))
                context.stroke(arc, with: ink, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            } else if pose.eyelid > 0.85 {
                var line = Path()
                line.move(to: CGPoint(x: x - 4.5, y: 83))
                line.addLine(to: CGPoint(x: x + 4.5, y: 83))
                context.stroke(line, with: ink, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            } else {
                let ry = 4.8 * (1 - pose.eyelid)
                context.fill(Path(ellipseIn: CGRect(x: eye.x - 4.2, y: eye.y - ry + 1.5 * pose.eyelid, width: 8.4, height: ry * 2)), with: ink)
                if soft {
                    context.fill(Path(ellipseIn: CGRect(x: eye.x + 0.2, y: eye.y - 2.9, width: 2.6, height: 2.6)), with: .color(.white))
                }
            }
        }
        if soft {
            context.fill(Path(ellipseIn: CGRect(x: 57.8, y: 87.4 + pose.nose, width: 4.4, height: 3.2)), with: ink)
            var mouth = Path()
            mouth.move(to: CGPoint(x: 56.5, y: 93))
            mouth.addQuadCurve(to: CGPoint(x: 60, y: 93), control: CGPoint(x: 58.25, y: 95.5))
            mouth.addQuadCurve(to: CGPoint(x: 63.5, y: 93), control: CGPoint(x: 61.75, y: 95.5))
            context.stroke(mouth, with: ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for x in [44.0, 76.0] {
                context.fill(Path(ellipseIn: CGRect(x: x - 4.6, y: 87.2, width: 9.2, height: 5.6)), with: .color(Self.pink.opacity(0.75)))
            }
        }
    }
}

#Preview("Lop rig") {
    VStack(spacing: 24) {
        LopRigView(inputs: LopInputs()).frame(width: 220)
        LopRigView(inputs: LopInputs(listening: true, loudness: 0.6), soft: false)
            .frame(width: 120).background(.black)
    }
    .padding()
}
