import SwiftUI
import PikoKit

/// The character. One view, one state enum, four skins — never four views.
/// Used by the app, the keyboard accessory row and the Live Activity, so it must stay cheap:
/// the keyboard renders this inside a ~60 MB ceiling.
public struct PikoFace: View {
    public var phase: SessionPhase
    public var skin: Skin

    public init(phase: SessionPhase, skin: Skin = .cute) {
        self.phase = phase
        self.skin = skin
    }

    public var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / Self.viewBoxSize.width, geo.size.height / Self.viewBoxSize.height)
            Canvas { context, _ in
                context.scaleBy(x: scale, y: scale)
                draw(in: &context)
            }
        }
        .aspectRatio(Self.viewBoxSize.width / Self.viewBoxSize.height, contentMode: .fit)
        .animation(.spring(duration: 0.35), value: phase)
    }

    /// The SVG's own `viewBox="0 0 140 148"` — every `Path` below is authored in this space.
    private static let viewBoxSize = CGSize(width: 140, height: 148)

    private func draw(in context: inout GraphicsContext) {
        let palette = skin.palette
        let faceState = phase.faceState

        // Draw order mirrors web/index.html's document order — later elements paint over earlier.
        if skin == .hero {
            context.fill(Self.heroCapeLeft, with: .color(palette.spark))
            context.fill(Self.heroCapeRight, with: .color(palette.spark))
        }

        if skin == .cute || skin == .cool {
            context.stroke(Self.antennaLine, with: .color(palette.bodyStroke),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
            context.fill(Self.antennaTip, with: .color(palette.spark))
        }

        if skin == .sparkle {
            context.fill(Self.bowLeft, with: .color(palette.blush))
            context.fill(Self.bowRight, with: .color(palette.blush))
            context.fill(Self.bowKnot, with: .color(palette.blush))
        }

        context.fill(Self.bodyPath, with: .color(palette.bodyFill))
        context.stroke(Self.bodyPath, with: .color(palette.bodyStroke), lineWidth: 2.5)

        // Same cool-only suppression rule as eyes — CSS combines .pk-blush into the same selector.
        if skin.showsEyes {
            var blushContext = context
            blushContext.opacity = 0.5
            blushContext.fill(Self.blushLeft, with: .color(palette.blush))
            blushContext.fill(Self.blushRight, with: .color(palette.blush))
        }

        if skin == .hero {
            context.fill(Self.maskPath, with: .color(palette.spark))
        }

        if skin.showsEyes {
            switch faceState.eye {
            case .open:
                context.fill(Self.eyesOpenLeft, with: .color(palette.onPiko))
                context.fill(Self.eyesOpenRight, with: .color(palette.onPiko))
            case .wide:
                context.fill(Self.eyesWideLeft, with: .color(palette.onPiko))
                context.fill(Self.eyesWideRight, with: .color(palette.onPiko))
            case .happy:
                let happyStyle = StrokeStyle(lineWidth: 3.4, lineCap: .round)
                context.stroke(Self.eyesHappyLeft, with: .color(palette.onPiko), style: happyStyle)
                context.stroke(Self.eyesHappyRight, with: .color(palette.onPiko), style: happyStyle)
            }
        }

        if skin == .cool {
            context.fill(Self.shadeLeft, with: .color(palette.onPiko))
            context.fill(Self.shadeBridge, with: .color(palette.onPiko))
            var reflectionContext = context
            reflectionContext.opacity = 0.55
            reflectionContext.fill(Self.shadeReflection, with: .color(palette.spark))
        }

        switch faceState.mouth {
        case .idle:
            context.fill(Self.mouthIdle, with: .color(palette.onPiko))
        case .open:
            context.fill(Self.mouthOpen, with: .color(palette.onPiko))
        case .think:
            context.fill(Self.mouthThinkLeft, with: .color(palette.onPiko))
            context.fill(Self.mouthThinkCenter, with: .color(palette.onPiko))
            context.fill(Self.mouthThinkRight, with: .color(palette.onPiko))
        }

        if skin == .sparkle {
            context.fill(Self.sparkleTipTopRight, with: .color(palette.spark))
            context.fill(Self.sparkleTipBottomLeft, with: .color(palette.spark))
        }
    }

    // MARK: - Path data, translated 1:1 from web/index.html's <svg> primitives.

    private static let heroCapeLeft: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 34, y: 52))
        path.addCurve(to: CGPoint(x: 26, y: 132), control1: CGPoint(x: 10, y: 74), control2: CGPoint(x: 12, y: 116))
        path.addCurve(to: CGPoint(x: 44, y: 84), control1: CGPoint(x: 34, y: 112), control2: CGPoint(x: 40, y: 96))
        path.closeSubpath()
        return path
    }()

    private static let heroCapeRight: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 106, y: 52))
        path.addCurve(to: CGPoint(x: 114, y: 132), control1: CGPoint(x: 130, y: 74), control2: CGPoint(x: 128, y: 116))
        path.addCurve(to: CGPoint(x: 96, y: 84), control1: CGPoint(x: 106, y: 112), control2: CGPoint(x: 100, y: 96))
        path.closeSubpath()
        return path
    }()

    /// `M70 30 q0 -12 6 -18` — shared by cute (own antenna) and cool (its own duplicate group).
    private static let antennaLine: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 70, y: 30))
        path.addQuadCurve(to: CGPoint(x: 76, y: 12), control: CGPoint(x: 70, y: 18))
        return path
    }()

    private static let antennaTip = Path(ellipseIn: CGRect(x: 77 - 5, y: 10 - 5, width: 10, height: 10))

    private static let bowLeft: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 70, y: 30))
        path.addLine(to: CGPoint(x: 52, y: 18))
        path.addLine(to: CGPoint(x: 54, y: 36))
        path.closeSubpath()
        return path
    }()

    private static let bowRight: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 70, y: 30))
        path.addLine(to: CGPoint(x: 88, y: 18))
        path.addLine(to: CGPoint(x: 86, y: 36))
        path.closeSubpath()
        return path
    }()

    private static let bowKnot = Path(ellipseIn: CGRect(x: 70 - 6, y: 29 - 6, width: 12, height: 12))

    private static let bodyPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 70, y: 30))
        path.addCurve(to: CGPoint(x: 118, y: 78), control1: CGPoint(x: 104, y: 30), control2: CGPoint(x: 118, y: 52))
        path.addCurve(to: CGPoint(x: 70, y: 122), control1: CGPoint(x: 118, y: 106), control2: CGPoint(x: 98, y: 122))
        path.addCurve(to: CGPoint(x: 22, y: 78), control1: CGPoint(x: 42, y: 122), control2: CGPoint(x: 22, y: 106))
        path.addCurve(to: CGPoint(x: 70, y: 30), control1: CGPoint(x: 22, y: 52), control2: CGPoint(x: 36, y: 30))
        path.closeSubpath()
        return path
    }()

    private static let blushLeft = Path(ellipseIn: CGRect(x: 41 - 9, y: 88 - 6, width: 18, height: 12))
    private static let blushRight = Path(ellipseIn: CGRect(x: 99 - 9, y: 88 - 6, width: 18, height: 12))

    private static let maskPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 36, y: 62))
        path.addLine(to: CGPoint(x: 104, y: 62))
        path.addLine(to: CGPoint(x: 100, y: 78))
        path.addLine(to: CGPoint(x: 82, y: 80))
        path.addLine(to: CGPoint(x: 70, y: 72))
        path.addLine(to: CGPoint(x: 58, y: 80))
        path.addLine(to: CGPoint(x: 40, y: 78))
        path.closeSubpath()
        return path
    }()

    private static let eyesOpenLeft = Path(ellipseIn: CGRect(x: 55 - 6, y: 74 - 7.5, width: 12, height: 15))
    private static let eyesOpenRight = Path(ellipseIn: CGRect(x: 85 - 6, y: 74 - 7.5, width: 12, height: 15))
    private static let eyesWideLeft = Path(ellipseIn: CGRect(x: 55 - 7.5, y: 73 - 9.5, width: 15, height: 19))
    private static let eyesWideRight = Path(ellipseIn: CGRect(x: 85 - 7.5, y: 73 - 9.5, width: 15, height: 19))

    /// `M48 77 q7 -10 14 0`
    private static let eyesHappyLeft: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 48, y: 77))
        path.addQuadCurve(to: CGPoint(x: 62, y: 77), control: CGPoint(x: 55, y: 67))
        return path
    }()

    /// `M78 77 q7 -10 14 0`
    private static let eyesHappyRight: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 78, y: 77))
        path.addQuadCurve(to: CGPoint(x: 92, y: 77), control: CGPoint(x: 85, y: 67))
        return path
    }()

    private static let shadeLeft = Path(roundedRect: CGRect(x: 36, y: 64, width: 68, height: 17), cornerRadius: 7)
    private static let shadeBridge = Path(CGRect(x: 66, y: 68, width: 8, height: 5))

    private static let shadeReflection: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 42, y: 68))
        path.addLine(to: CGPoint(x: 54, y: 68))
        path.addLine(to: CGPoint(x: 44, y: 78))
        path.closeSubpath()
        return path
    }()

    /// `M62 95 q8 8 16 0 q-8 4 -16 0 Z`
    private static let mouthIdle: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 62, y: 95))
        path.addQuadCurve(to: CGPoint(x: 78, y: 95), control: CGPoint(x: 70, y: 103))
        path.addQuadCurve(to: CGPoint(x: 62, y: 95), control: CGPoint(x: 70, y: 99))
        path.closeSubpath()
        return path
    }()

    private static let mouthOpen = Path(ellipseIn: CGRect(x: 70 - 8, y: 97 - 10, width: 16, height: 20))

    private static let mouthThinkLeft = Path(ellipseIn: CGRect(x: 61 - 2.4, y: 97 - 2.4, width: 4.8, height: 4.8))
    private static let mouthThinkCenter = Path(ellipseIn: CGRect(x: 70 - 2.4, y: 97 - 2.4, width: 4.8, height: 4.8))
    private static let mouthThinkRight = Path(ellipseIn: CGRect(x: 79 - 2.4, y: 97 - 2.4, width: 4.8, height: 4.8))

    private static let sparkleTipTopRight = starPath(
        from: CGPoint(x: 113, y: 46),
        deltas: [(2.6, 6.4), (6.4, 2.6), (-6.4, 2.6), (-2.6, 6.4), (-2.6, -6.4), (-6.4, -2.6), (6.4, -2.6)]
    )

    private static let sparkleTipBottomLeft = starPath(
        from: CGPoint(x: 25, y: 100),
        deltas: [(1.8, 4.4), (4.4, 1.8), (-4.4, 1.8), (-1.8, 4.4), (-1.8, -4.4), (-4.4, -1.8), (4.4, -1.8)]
    )

    /// Builds a closed path from an origin plus a sequence of relative line deltas — mirrors the
    /// SVG's own lowercase `l` (relative lineto) sparkle-tip primitives.
    private static func starPath(from origin: CGPoint, deltas: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        var current = origin
        path.move(to: current)
        for (dx, dy) in deltas {
            current = CGPoint(x: current.x + dx, y: current.y + dy)
            path.addLine(to: current)
        }
        path.closeSubpath()
        return path
    }
}

/// The five fill/stroke colors the SVG's CSS custom properties resolve to, per skin.
public struct PikoPalette {
    public let bodyFill: Color
    public let bodyStroke: Color
    public let blush: Color
    public let spark: Color
    public let onPiko: Color
}

extension Skin {
    /// Exact hex values from `web/index.html`'s per-skin CSS custom properties — do not approximate.
    var palette: PikoPalette {
        switch self {
        case .cute:
            PikoPalette(bodyFill: Color(red: 0xFF / 255.0, green: 0xCF / 255.0, blue: 0x5C / 255.0),
                        bodyStroke: Color(red: 0xF0 / 255.0, green: 0xAE / 255.0, blue: 0x33 / 255.0),
                        blush: Color(red: 0xFF / 255.0, green: 0x8D / 255.0, blue: 0x6B / 255.0),
                        spark: Color(red: 0x7C / 255.0, green: 0xCB / 255.0, blue: 0xE2 / 255.0),
                        onPiko: Color(red: 0x2A / 255.0, green: 0x1F / 255.0, blue: 0x00 / 255.0))
        case .cool:
            PikoPalette(bodyFill: Color(red: 0x6B / 255.0, green: 0x8C / 255.0, blue: 0xFF / 255.0),
                        bodyStroke: Color(red: 0x3D / 255.0, green: 0x5F / 255.0, blue: 0xE0 / 255.0),
                        blush: Color(red: 0x22 / 255.0, green: 0xD3 / 255.0, blue: 0xEE / 255.0),
                        spark: Color(red: 0x22 / 255.0, green: 0xD3 / 255.0, blue: 0xEE / 255.0),
                        onPiko: Color(red: 0x08 / 255.0, green: 0x12 / 255.0, blue: 0x2E / 255.0))
        case .hero:
            PikoPalette(bodyFill: Color(red: 0xF5 / 255.0, green: 0xC5 / 255.0, blue: 0x42 / 255.0),
                        bodyStroke: Color(red: 0xC9 / 255.0, green: 0x92 / 255.0, blue: 0x2A / 255.0),
                        blush: Color(red: 0xE4 / 255.0, green: 0x52 / 255.0, blue: 0x3E / 255.0),
                        spark: Color(red: 0x5B / 255.0, green: 0x4B / 255.0, blue: 0xD6 / 255.0),
                        onPiko: Color(red: 0x2A / 255.0, green: 0x1C / 255.0, blue: 0x00 / 255.0))
        case .sparkle:
            PikoPalette(bodyFill: Color(red: 0xFF / 255.0, green: 0xB4 / 255.0, blue: 0xD4 / 255.0),
                        bodyStroke: Color(red: 0xF1 / 255.0, green: 0x77 / 255.0, blue: 0xAC / 255.0),
                        blush: Color(red: 0xFF / 255.0, green: 0x6F / 255.0, blue: 0xA8 / 255.0),
                        spark: Color(red: 0xC6 / 255.0, green: 0xA6 / 255.0, blue: 0xFF / 255.0),
                        onPiko: Color(red: 0x3A / 255.0, green: 0x0A / 255.0, blue: 0x22 / 255.0))
        }
    }

    /// The one hard rule from `web/index.html`: `[data-skin="cool"]` hides all eye groups and blush.
    var showsEyes: Bool {
        self != .cool
    }
}

/// The SVG's three `eyes-*` groups.
public enum PikoEyeState: Equatable {
    case open, wide, happy
}

/// The SVG's three `m-*` mouth groups.
public enum PikoMouthState: Equatable {
    case idle, open, think
}

extension SessionPhase {
    /// A new but visually-consistent combination for `.armed`, built only from the SVG's existing
    /// eye/mouth primitives — see 08-03-PLAN.md's mapping table for the full rationale.
    var faceState: (eye: PikoEyeState, mouth: PikoMouthState) {
        switch self {
        case .idle:      (.open, .idle)
        case .armed:     (.wide, .idle)
        case .capturing: (.wide, .open)
        case .tidying:   (.open, .think)
        }
    }
}
