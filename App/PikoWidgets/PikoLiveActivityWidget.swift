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
                    if phase == .capturing || phase == .tidying {
                        PikoFace(phase: phase, skin: context.attributes.skin)
                            .frame(width: 44, height: 46)
                            .accessibilityHidden(true)
                    } else if phase == .armed {
                        // At rest the buddy lives in the notch: a locally looping pet
                        // animation keyed by mood, costing zero update budget. Tapping
                        // starts dictation.
                        Button(intent: StartDictationIntent()) {
                            PetImage(mood: context.state.mood)
                                .frame(width: 46, height: 48)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Start dictation")
                        .accessibilityHint("Opens Piko and starts listening.")
                    } else {
                        PetImage(mood: context.state.mood)
                            .frame(width: 46, height: 48)
                            .accessibilityHidden(true)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WordCount(words: words, phase: phase)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(phase.calmStatus)
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
                // The pet rests in the notch when there's nothing to report; the waveform
                // takes over the moment there is something to hear.
                if phase == .capturing || phase == .tidying {
                    Image(systemName: phase.symbolName)
                        .foregroundStyle(.white)
                        .accessibilityLabel(phase.spokenStatus)
                } else {
                    PetImage(mood: context.state.mood)
                        .frame(width: 22, height: 23)
                }
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
                    PetImage(mood: context.state.mood)
                        .frame(width: 16, height: 17)
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
            if state.phase == .capturing || state.phase == .tidying {
                PikoFace(phase: state.phase, skin: skin)
                    .frame(width: 52, height: 55)
                    .accessibilityHidden(true)
            } else {
                PetImage(mood: state.mood)
                    .frame(width: 52, height: 55)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(state.phase.calmStatus)
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

/// The notch pet: numbered PNG frames in the widget bundle, assembled into a looping
/// animated UIImage. Plays locally on the device at zero update budget; one image swap
/// per mood change.
private struct PetImage: View {
    let mood: PikoMood

    var body: some View {
        if let animated = PetFrames.animatedImage(named: "pet-\(mood.rawValue)") {
            Image(uiImage: animated)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Piko is \(mood.rawValue)")
        } else {
            // The frames are generated and committed, so this is a broken-build marker,
            // not a runtime contingency.
            Image(systemName: "circle.fill")
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Piko is \(mood.rawValue)")
        }
    }
}

private enum PetFrames {
    /// `UIImage.animatedImage` loops the frames forever, exactly the pet's idle behavior.
    static func animatedImage(named base: String) -> UIImage? {
        let bundle = Bundle(for: BundleMarker.self)
        var frames: [UIImage] = []
        var index = 0
        while let path = bundle.path(forResource: "\(base)\(index)", ofType: "png"),
              let image = UIImage(contentsOfFile: path) {
            frames.append(image)
            index += 1
        }
        guard frames.count > 1 else { return nil }
        return UIImage.animatedImage(with: frames, duration: Double(frames.count) * 0.12)
    }

    private final class BundleMarker {}
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
