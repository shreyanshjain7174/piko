import SwiftUI

/// The two finishes of the shared Lop rig. Fur stays cream in both.
public enum LopFrameStyle: Equatable, Sendable {
    case flat
    case soft
}

/// A held Lop pose, suitable for surfaces that cannot run the fluid rig.
/// Draws only the supplied value: no simulation, clock or interaction state.
public struct LopFrameView: View {
    private let pose: LopPose
    private let style: LopFrameStyle
    private let ink: Color

    public init(pose: LopPose, style: LopFrameStyle, ink: Color) {
        self.pose = pose
        self.style = style
        self.ink = ink
    }

    public var body: some View {
        Canvas { context, size in
            LopPainter(fur: LopRigView.cream, soft: style == .soft, ink: ink)
                .draw(pose, in: &context, size: size)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Lop")
    }
}
