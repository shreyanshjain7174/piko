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
    @Environment(\.colorScheme) private var scheme

    private var theme: PikoTheme { skin.theme(for: scheme) }

    var body: some View {
        Button(action: action) {
            if isCapturing {
                HStack(spacing: 14) {
                    VoiceWave(activity: voiceActivity, tint: theme.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: diameter)

                    Image(systemName: "stop.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.onPiko)
                        .frame(width: 48, height: 48)
                        .background(theme.piko, in: Circle())
                }
                .padding(.horizontal, 16)
                .frame(height: diameter * 1.3)
                .background(theme.card,
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                ZStack {
                    Circle()
                        .fill(background)
                        .frame(width: diameter, height: diameter)

                    if phase == .tidying {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(theme.ink2)
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
        phase == .armed && setupPrompt == nil ? theme.onPiko : theme.ink3
    }

    /// Ready is Piko's own colour; anything else is a quiet step up from the keyboard's ground.
    private var background: Color {
        phase == .armed && setupPrompt == nil ? theme.piko : theme.cardRaised
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
        case .armed:     "Dictates into this text field without opening Siri. Tap again to stop."
        case .capturing: "Stops recording and tidies what you said."
        case .tidying:   "Piko is tidying what you said. This takes a moment."
        case .idle, nil: "Arm Piko from Control Center or the Action Button first."
        }
    }
}
