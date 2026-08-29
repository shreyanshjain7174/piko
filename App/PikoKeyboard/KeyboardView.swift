import SwiftUI
import PikoKit

/// Keyboard extension root. Mic is a remote control for the container app's armed
/// session; profile chips are placeholders until v0.2.
struct KeyboardView: View {
    let onMicTap: () -> Void
    let onGlobeTap: () -> Void
    @Binding var sessionPhase: SessionPhase?
    @Binding var showArmPrompt: Bool

    var body: some View {
        VStack(spacing: 12) {
            if showArmPrompt {
                Text("Open Piko to arm")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground))
            }

            HStack(spacing: 8) {
                ForEach(["message", "email", "note", "code"], id: \.self) { label in
                    Text(label)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(.secondarySystemBackground)))
                }
            }

            MicButton(phase: sessionPhase, action: onMicTap)
                .frame(maxWidth: .infinity)

            HStack {
                Button(action: onGlobeTap) {
                    Image(systemName: "globe")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next keyboard")
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .frame(height: 240)
    }
}
