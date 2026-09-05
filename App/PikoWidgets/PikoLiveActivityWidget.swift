import ActivityKit
import WidgetKit
import SwiftUI
import PikoKit
import PikoUI

struct PikoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PikoAttributes.self) { context in
            LockScreenView(state: context.state, skin: context.attributes.skin)
                .activityBackgroundTint(Color(white: 0.09))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let phase = context.state.phase
            let words = context.state.words

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if phase == .armed {
                        Button(intent: StartDictationIntent()) {
                            PikoFace(phase: phase, skin: context.attributes.skin)
                                .frame(width: 44, height: 46)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Start dictation")
                        .accessibilityHint("Opens Piko and starts listening.")
                    } else {
                        PikoFace(phase: phase, skin: context.attributes.skin)
                            .frame(width: 44, height: 46)
                            .accessibilityHidden(true)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WordCount(words: words, phase: phase)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
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
                WordCount(words: words, phase: phase)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: phase.symbolName)
                    .foregroundStyle(phase == .capturing ? .white : .secondary)
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
                WordCount(words: state.words, phase: state.phase)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
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

private struct WordCount: View {
    let words: Int
    let phase: SessionPhase

    var body: some View {
        if phase == .capturing || words > 0 {
            Text("^[\(words) word](inflect: true)")
        } else {
            EmptyView()
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopSessionIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel("Stop the Piko session")
    }
}
