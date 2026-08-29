import SwiftUI
import PikoKit

/// Mic control reflecting the container app's session phase. The keyboard never opens
/// the microphone (CONSTRAINTS C1) — this is a remote control only.
struct MicButton: View {
    let phase: SessionPhase?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 64, height: 64)
                .background(Circle().fill(background))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var isDisabled: Bool {
        phase == nil || phase == .idle || phase == .tidying
    }

    private var symbolName: String {
        switch phase {
        case .armed: return "mic.fill"
        case .capturing: return "stop.fill"
        case .tidying: return "clock.fill"
        case .idle, nil: return "mic.fill"
        }
    }

    private var foreground: Color {
        switch phase {
        case .armed, .capturing: return .white
        default: return .secondary
        }
    }

    private var background: Color {
        switch phase {
        case .armed: return .accentColor
        case .capturing: return .red
        default: return Color(.systemGray4)
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .armed: return "Start capture"
        case .capturing: return "Stop capture"
        case .tidying: return "Processing"
        case .idle, nil: return "Microphone unavailable"
        }
    }
}
