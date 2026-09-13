import SwiftUI
import PikoKit
import PikoUI

/// A quiet control surface; setup guidance is available on demand, never a banner.
struct KeyboardView: View {
    let onMicTap: () -> Void
    let onGlobeTap: () -> Void
    let onRevertTap: () -> Void
    @Binding var sessionPhase: SessionPhase?
    let setupPrompt: KeyboardSetupPrompt?
    @Binding var selectedProfile: Profile
    @Binding var skin: Skin
    @Binding var canRevert: Bool
    let voiceActivity: VoiceActivityModel

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showingHelp = false

    var body: some View {
        VStack(spacing: verticalSizeClass == .compact ? 6 : 12) {
            HStack(spacing: 8) {
                Button(action: onGlobeTap) {
                    Image(systemName: "globe")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next keyboard")

                Text("piko")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)

                Spacer()

                Menu {
                    Picker("Tone", selection: $selectedProfile) {
                        ForEach(Profile.allCases, id: \.self) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Tone")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(.white.opacity(0.1), in: Capsule())
                }
                .accessibilityLabel("Tone")
                .accessibilityValue(selectedProfile.displayName)

                if setupPrompt != nil {
                    Button { showingHelp = true } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 19))
                            .frame(width: 36, height: 44)
                    }
                    .accessibilityLabel("Keyboard setup")
                }
            }
            .foregroundStyle(.white.opacity(0.55))

            MicButton(phase: sessionPhase, skin: skin, setupPrompt: setupPrompt,
                      voiceActivity: voiceActivity, action: onMicTap)

            if canRevert {
                Button(action: onRevertTap) {
                    Label("Use original", systemImage: "arrow.uturn.backward")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(minHeight: 32)
                }
                .accessibilityHint("Restores exactly what you said.")
            }

            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.04, green: 0.07, blue: 0.14))
        .alert(setupPrompt?.caption ?? "Keyboard setup", isPresented: $showingHelp) {
            Button("Done", role: .cancel) {}
        } message: {
            Text(setupPrompt?.message ?? "Your keyboard is ready.")
        }
    }
}


/// The unmet prerequisite remains available to accessibility and the optional help control.
enum KeyboardSetupPrompt: Equatable {
    case fullAccess
    case armSession

    static func resolve(hasFullAccess: Bool, isLive: Bool) -> Self? {
        if !hasFullAccess { return .fullAccess }
        return isLive ? nil : .armSession
    }

    var message: String {
        switch self {
        case .fullAccess:
            "In Settings › General › Keyboard › Keyboards › Piko, turn on Allow Full Access."
        case .armSession:
            "Open Piko and start a keyboard session from Home."
        }
    }

    var caption: String {
        switch self {
        case .fullAccess: "Full Access required"
        case .armSession: "Set up your session"
        }
    }
}
