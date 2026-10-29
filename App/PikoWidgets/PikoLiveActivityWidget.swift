import ActivityKit
import WidgetKit
import SwiftUI
import PikoKit
import PikoUI

struct PikoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PikoAttributes.self) { context in
            LockScreenView(state: context.state, skin: context.attributes.skin)
                .activityBackgroundTint(context.attributes.skin.theme(for: .dark).ground)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let phase = context.state.phase

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if phase == .armed {
                        Button(intent: StartDictationIntent()) {
                            PikoFace(phase: phase, skin: context.attributes.skin)
                                .frame(width: 44, height: 46)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Talk to Piko")
                        .accessibilityHint("Opens Piko and starts listening.")
                    } else {
                        PikoFace(phase: phase, skin: context.attributes.skin)
                            .frame(width: 44, height: 46)
                            .accessibilityHidden(true)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ListeningWave(phase: phase)
                        .font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(phase.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StopButton()
                }
            } compactLeading: {
                Image(systemName: phase.symbolName)
                    .foregroundStyle(phase == .capturing ? .white : .secondary)
                    .accessibilityLabel(phase.spokenStatus)
            } compactTrailing: {
                ListeningWave(phase: phase)
                    .font(.caption2.weight(.semibold))
            } minimal: {
                ListeningWave(phase: phase)
                    .accessibilityLabel(phase.spokenStatus)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: PikoAttributes.ContentState
    let skin: Skin

    var body: some View {
        HStack(spacing: 14) {
            PikoFace(phase: state.phase, skin: skin)
                .frame(width: 52, height: 55)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.phase.displayName)
                    .font(.headline)
                    .foregroundStyle(.white)
                ListeningWave(phase: state.phase)
                    .font(.subheadline)
            }

            Spacer(minLength: 8)

            StopButton()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Piko")
        .accessibilityValue(state.phase.spokenStatus)
    }
}

/// Animated waveform while Piko listens; a quiet mic glyph otherwise. No word counts.
private struct ListeningWave: View {
    let phase: SessionPhase

    var body: some View {
        Image(systemName: phase == .capturing ? "waveform" : phase.symbolName)
            .foregroundStyle(phase == .capturing ? .white : .secondary)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: phase != .idle)
            .accessibilityHidden(true)
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopSessionIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
                .fontDesign(.rounded)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(.white)
        .accessibilityLabel("Stop the Piko session")
    }
}
