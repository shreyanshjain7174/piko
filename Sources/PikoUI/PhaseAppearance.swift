import SwiftUI
import PikoKit

public enum PikoColor {
    public static let badgeFill = Color("BadgeFill", bundle: .module)
}

extension SessionPhase {
    /// Engineering name, for logs and debug UI only — never user-visible. The shippable
    /// vocabulary is `calmStatus`; keep it that way (UX review 2026-09-13).
    public var debugName: String {
        switch self {
        case .idle:      "Idle"
        case .armed:     "Armed"
        case .capturing: "Recording…"
        case .tidying:   "Tidying…"
        }
    }

    /// The human status, in the same words Home uses — the notch and the app speak one
    /// language. Short by design: these surface in the compact Island too.
    public var calmStatus: String {
        switch self {
        case .idle:      "Ready"
        case .armed:     "Session live"
        case .capturing: "Listening"
        case .tidying:   "Tidying…"
        }
    }

    public var spokenStatus: String {
        switch self {
        case .idle:      "Not armed"
        case .armed:     "Armed and ready"
        case .capturing: "Recording"
        case .tidying:   "Tidying up what you said"
        }
    }

    public var symbolName: String {
        switch self {
        case .idle:      "mic.slash.fill"
        case .armed:     "mic.fill"
        case .capturing: "waveform"
        case .tidying:   "sparkles"
        }
    }

    public var statusColor: Color {
        switch self {
        case .idle:      Color("StatusIdle", bundle: .module)
        case .armed:     Color("StatusArmed", bundle: .module)
        case .capturing: Color("StatusCapturing", bundle: .module)
        case .tidying:   Color("StatusTidying", bundle: .module)
        }
    }

    public func filledControlBackground(skin: Skin) -> Color {
        switch self {
        case .armed:          skin.controlTint
        case .capturing:      Color("FillCapturing", bundle: .module)
        case .idle, .tidying: PikoColor.badgeFill
        }
    }
}

extension Skin {
    public var displayName: String {
        switch self {
        case .cute:    "Cute"
        case .cool:    "Cool"
        case .hero:    "Hero"
        case .sparkle: "Sparkle"
        }
    }

    public var controlTint: Color {
        switch self {
        case .cute:    Color("SkinCuteTint", bundle: .module)
        case .cool:    Color("SkinCoolTint", bundle: .module)
        case .hero:    Color("SkinHeroTint", bundle: .module)
        case .sparkle: Color("SkinSparkleTint", bundle: .module)
        }
    }
}


public struct PhaseBadge: View {
    public var phase: SessionPhase

    public init(phase: SessionPhase) {
        self.phase = phase
    }

    public var body: some View {
        Label {
            Text(phase.calmStatus)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: phase.symbolName)
                .foregroundStyle(phase.statusColor)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(PikoColor.badgeFill, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status")
        .accessibilityValue(phase.spokenStatus)
    }
}
