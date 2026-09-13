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
            let levels = context.state.levels
            let tint = context.attributes.skin.controlTint

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
                    HStack(spacing: 14) {
                        // Bars only while there is something to hear; armed rests silent.
                        if phase == .capturing {
                            LevelBars(levels: levels, tint: tint, barWidth: 5, spacing: 5)
                                .frame(width: 118, height: 26)
                                .accessibilityLabel("Voice activity")
                        }
                        Spacer()
                        StopButton()
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: phase.symbolName)
                    .foregroundStyle(phase == .capturing ? .white : .secondary)
                    .accessibilityLabel(phase.spokenStatus)
            } compactTrailing: {
                // While capturing the notch dances with the voice; otherwise it stays quiet
                // and reports the words instead.
                if phase == .capturing {
                    LevelBars(levels: Array(levels.suffix(3)), tint: tint, barWidth: 3.5, spacing: 2.5)
                        .frame(width: 17, height: 14)
                } else {
                    WordCount(words: words, phase: phase)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            } minimal: {
                if phase == .capturing {
                    LevelBars(levels: Array(levels.suffix(2)), tint: tint, barWidth: 3, spacing: 2)
                        .frame(width: 9, height: 12)
                } else {
                    Image(systemName: phase.symbolName)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(phase.spokenStatus)
                }
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

            if state.phase == .capturing {
                LevelBars(levels: state.levels, tint: skin.controlTint, barWidth: 4.5, spacing: 4)
                    .frame(width: 66, height: 24)
                    .accessibilityLabel("Voice activity")
            }

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
    var compact = false

    var body: some View {
        Button(intent: StopSessionIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel("Stop the Piko session")
    }
}
