import SwiftUI
import PikoKit
import PikoUI

/// A quiet control surface; setup guidance is available on demand, never a banner.
struct KeyboardView: View {
    let onMicTap: () -> Void
    let onGlobeTap: () -> Void
    let onRevertTap: () -> Void
    let onSuggestionTap: () -> Void
    let onSuggestionConfirm: () -> Void
    let onSuggestionDismiss: () -> Void
    let onToggleSuggestions: () -> Void
    let suggestionEntry: SuggestionSnapshot.Entry?
    let isConfirmingSuggestion: Bool
    let suggestionsEnabled: Bool
    @Binding var sessionPhase: SessionPhase?
    let setupPrompt: KeyboardSetupPrompt?
    @Binding var selectedProfile: Profile
    @Binding var skin: Skin
    @Binding var canRevert: Bool
    let voiceActivity: VoiceActivityModel

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var scheme
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
                    .accessibilityHidden(true)

                Spacer()

                Menu {
                    Picker("Tone", selection: $selectedProfile) {
                        ForEach(Profile.allCases, id: \.self) { profile in
                            Text(profile.keyboardTitle).tag(profile)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Tone")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(skin.theme(for: scheme).cardRaised, in: Capsule())
                }
                .accessibilityLabel("Tone")
                .accessibilityValue(selectedProfile.keyboardTitle)

                Menu {
                    Button(suggestionsEnabled ? "Turn suggestions off" : "Turn suggestions on",
                           action: onToggleSuggestions)
                } label: {
                    Image(systemName: suggestionsEnabled ? "lightbulb" : "lightbulb.slash")
                        .font(.system(size: 17))
                        .frame(width: 36, height: 44)
                }
                .accessibilityLabel("Suggestions")
                .accessibilityValue(suggestionsEnabled ? "On" : "Off")

                if setupPrompt != nil {
                    Button { showingHelp = true } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 19))
                            .frame(width: 36, height: 44)
                    }
                    .accessibilityLabel("Keyboard setup")
                }
            }
            .foregroundStyle(skin.theme(for: scheme).ink2)

            if let suggestionEntry {
                HStack(spacing: 8) {
                    Button(action: isConfirmingSuggestion ? onSuggestionConfirm : onSuggestionTap) {
                        HStack(spacing: 6) {
                            Text(isConfirmingSuggestion ? "Insert \(suggestionEntry.value)?"
                                                      : "\(suggestionEntry.label): \(suggestionEntry.value)")
                                .lineLimit(1)
                            if isConfirmingSuggestion { Image(systemName: "checkmark.circle") }
                        }
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .padding(.horizontal, 10)
                        .background(skin.theme(for: scheme).cardRaised, in: Capsule())
                    }
                    .accessibilityLabel(isConfirmingSuggestion ? "Confirm insert \(suggestionEntry.value)"
                                                               : "Suggest \(suggestionEntry.label)")
                    Button(action: onSuggestionDismiss) {
                        Image(systemName: "xmark.circle").frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Dismiss suggestion for this document")
                }
                .foregroundStyle(skin.theme(for: scheme).ink2)
            }

            MicButton(phase: sessionPhase, skin: skin, setupPrompt: setupPrompt,
                      voiceActivity: voiceActivity, action: onMicTap)

            if canRevert {
                Button(action: onRevertTap) {
                    Label("Use original", systemImage: "arrow.uturn.backward")
                        .font(.footnote.weight(.medium))
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
        .background(skin.theme(for: scheme).ground)
        .fontDesign(.rounded)
        .alert(setupPrompt?.caption ?? "Keyboard setup", isPresented: $showingHelp) {
            Button("Done", role: .cancel) {}
        } message: {
            Text(setupPrompt?.message ?? "Your keyboard is ready.")
        }
    }
}

extension Profile {
    var keyboardTitle: String {
        switch self {
        case .message: "Casual"
        case .email: "Email"
        case .note: "Notes"
        case .code: "Code"
        case .agent: "Prompt"
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
            "Press Arm Piko in Control Center, on the Lock Screen or with the Action Button, then tap the mic again."
        }
    }

    var caption: String {
        switch self {
        case .fullAccess: "Full Access required"
        case .armSession: "Arm Piko once to dictate"
        }
    }
}
