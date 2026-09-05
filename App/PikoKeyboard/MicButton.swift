import SwiftUI
import PikoKit
import PikoUI

/// Mic control reflecting the container app's session phase. The keyboard never opens
/// the microphone (CONSTRAINTS C1) — this is a remote control only.
struct MicButton: View {
    let phase: SessionPhase?
    let skin: Skin
    let setupPrompt: KeyboardSetupPrompt?
    let voiceActivity: VoiceActivityModel
    let action: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 72

    var body: some View {
        Button(action: action) {
            if isCapturing {
                HStack(spacing: 14) {
                    VoiceWave(activity: voiceActivity, tint: skin.controlTint)
                        .frame(maxWidth: .infinity)
                        .frame(height: diameter)

                    Image(systemName: "stop.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(skin.controlTint, in: Circle())
                }
                .padding(.horizontal, 16)
                .frame(height: diameter * 1.3)
                .background(Color(.secondarySystemGroupedBackground).opacity(0.75),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                ZStack {
                    Circle()
                        .fill(background)
                        .frame(width: diameter, height: diameter)
                        .overlay(
                            Circle().strokeBorder(Color(.separator), lineWidth: isDisabled ? 1 : 0)
                        )

                    if phase == .tidying {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Color(.secondaryLabel))
                    } else {
                        Image(systemName: symbolName)
                            .font(.system(size: diameter * 0.4, weight: .semibold))
                            .foregroundStyle(foreground)
                    }
                }
                .frame(width: diameter * 1.3, height: diameter * 1.3)
                .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var isCapturing: Bool { phase == .capturing }

    private var isDisabled: Bool {
        setupPrompt != nil || phase == nil || phase == .idle || phase == .tidying
    }

    private var symbolName: String {
        switch phase {
        case .capturing: "stop.fill"
        case .armed:     "mic.fill"
        case .tidying:   "sparkles"
        case .idle, nil: "mic.slash.fill"
        }
    }

    private var foreground: Color {
        switch phase {
        case .armed, .capturing: .white
        default:                 Color(.secondaryLabel)
        }
    }

    private var background: Color {
        (phase ?? .idle).filledControlBackground(skin: skin)
    }

    private var accessibilityLabel: String {
        if let setupPrompt { return setupPrompt.caption }
        return switch phase {
        case .armed:     "Start dictating"
        case .capturing: "Stop dictating"
        case .tidying:   "Tidying up"
        case .idle, nil: "Microphone unavailable"
        }
    }

    private var accessibilityHint: String {
        if let setupPrompt { return setupPrompt.message }
        return switch phase {
        case .armed:     "Piko listens until you tap again."
        case .capturing: "Stops recording and tidies what you said."
        case .tidying:   "Piko is tidying what you said. This takes a moment."
        case .idle, nil: "Open the Piko app and tap Arm first."
        }
    }
}
