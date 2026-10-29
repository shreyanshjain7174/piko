#if DEBUG
import SwiftUI
import PikoUI

/// Lab screen for the SwiftUI Canvas rig: every input on one screen, in both looks.
/// Launch with `-PikoLopLab YES`. Debug builds only; nothing here ships.
/// The Rive comparison that used to sit beside it is recorded in docs/SPIKES.md (Spike 7).
struct LopLab: View {
    @State private var listening = false
    @State private var loudness = 0.4
    @State private var mood: LopMood = .calm
    @State private var flat = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Lop rig lab").font(.largeTitle.bold())

                LopRigView(inputs: LopInputs(listening: listening, loudness: loudness, mood: mood), soft: !flat)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .background(flat ? Color.black : Color(red: 0.98, green: 0.97, blue: 0.95),
                                in: RoundedRectangle(cornerRadius: 24))

                Toggle("Listening", isOn: $listening)
                VStack(alignment: .leading) {
                    Text("Loudness \(loudness, format: .number.precision(.fractionLength(2)))")
                    Slider(value: $loudness, in: 0...1)
                }
                Picker("Mood", selection: $mood) {
                    ForEach(LopMood.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                }
                .pickerStyle(.segmented)
                Toggle("Flat island look", isOn: $flat)
                Text("Stroke Lop to pat it. Slide loudness from low to high quickly while listening to make it thump.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}
#endif
