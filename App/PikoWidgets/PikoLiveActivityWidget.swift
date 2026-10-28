import ActivityKit
import WidgetKit
import SwiftUI
import PikoKit
import PikoUI

/// Piko lives in the Dynamic Island for the whole session: the character is the activity.
/// Every presentation leads with Piko's face; words are kept to one short line Piko says.
///
/// A Live Activity ignores SwiftUI animation modifiers. Piko moves because the app steps
/// `ContentState.beat` (blink, glance, smile) and the system cross-fades between frames.
struct PikoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PikoAttributes.self) { context in
            // Required by ActivityKit on every device; kept to Piko and one line.
            LockScreenView(state: context.state, skin: context.attributes.skin)
                .activityBackgroundTint(context.attributes.skin.theme(for: .dark).ground)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let skin = context.attributes.skin

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TalkablePiko(state: state, skin: skin)
                        .frame(width: 58, height: 61)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StopButton()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(state.phase.pikoLine)
                        .font(.title3.weight(.semibold))
                        .fontDesign(.rounded)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                        .contentTransition(.opacity)
                }
            } compactLeading: {
                IslandPiko(state: state, skin: skin)
                    .frame(width: 26, height: 27)
                    .accessibilityLabel("Piko, \(state.phase.spokenStatus)")
            } compactTrailing: {
                PhaseMark(phase: state.phase, skin: skin)
            } minimal: {
                IslandPiko(state: state, skin: skin)
                    .frame(width: 22, height: 23)
                    .accessibilityLabel("Piko, \(state.phase.spokenStatus)")
            }
            .keylineTint(skin.theme(for: .dark).accent)
        }
    }
}

/// Piko on the current frame. A new identity per beat lets the system cross-fade the blink.
private struct IslandPiko: View {
    let state: PikoAttributes.ContentState
    let skin: Skin

    var body: some View {
        ZStack {
            PikoFace(phase: state.phase, skin: skin, beat: state.beat)
                .id(state.beat)
                .transition(.opacity)
        }
    }
}

/// While Piko waits, tapping the character starts listening.
private struct TalkablePiko: View {
    let state: PikoAttributes.ContentState
    let skin: Skin

    var body: some View {
        if state.phase == .armed {
            Button(intent: StartDictationIntent()) {
                IslandPiko(state: state, skin: skin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Talk to Piko")
            .accessibilityHint("Opens Piko and starts listening.")
        } else {
            IslandPiko(state: state, skin: skin)
                .accessibilityHidden(true)
        }
    }
}

/// The trailing half of the pill: a small sign of what Piko is doing, in Piko's colour.
private struct PhaseMark: View {
    let phase: SessionPhase
    let skin: Skin

    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(skin.theme(for: .dark).accent)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: phase == .capturing)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch phase {
        case .capturing: "waveform"
        case .tidying:   "ellipsis"
        case .armed, .idle: "sparkle"
        }
    }
}

private struct LockScreenView: View {
    let state: PikoAttributes.ContentState
    let skin: Skin

    var body: some View {
        HStack(spacing: 14) {
            IslandPiko(state: state, skin: skin)
                .frame(width: 48, height: 50)
            Text(state.phase.pikoLine)
                .font(.headline)
                .fontDesign(.rounded)
                .foregroundStyle(.white)
                .contentTransition(.opacity)
            Spacer(minLength: 8)
            StopButton()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Piko")
        .accessibilityValue(state.phase.spokenStatus)
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopSessionIntent()) {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop the Piko session")
    }
}

private extension SessionPhase {
    /// What Piko says in the island: a few words, never the user's own text.
    var pikoLine: String {
        switch self {
        case .armed, .idle: "Ready when you are"
        case .capturing:    "I’m listening"
        case .tidying:      "Writing it down"
        }
    }
}
