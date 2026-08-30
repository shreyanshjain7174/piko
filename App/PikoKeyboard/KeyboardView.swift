import SwiftUI
import PikoKit

/// Keyboard extension root. Mic is a remote control for the container app's armed
/// session; profile chips write `SessionState.profile` through the App Group.
struct KeyboardView: View {
    let onMicTap: () -> Void
    let onGlobeTap: () -> Void
    @Binding var sessionPhase: SessionPhase?
    @Binding var showArmPrompt: Bool
    @Binding var selectedProfile: Profile

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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Profile.allCases, id: \.rawValue) { profile in
                        let selected = selectedProfile == profile
                        Button {
                            selectedProfile = profile
                        } label: {
                            Text(profile.rawValue)
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(minWidth: 64)
                                .background(
                                    Capsule().fill(
                                        selected
                                            ? Color.accentColor.opacity(0.25)
                                            : Color(.secondarySystemBackground)
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(profile.rawValue)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
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
