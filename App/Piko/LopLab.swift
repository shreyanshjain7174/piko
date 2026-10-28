#if DEBUG
import SwiftUI
import PikoUI
import RiveRuntime

/// Spike screen: the SwiftUI Canvas rig next to the Rive runtime, driven by the same controls.
/// Launch with `-PikoLopLab YES`. Debug builds only; nothing here ships.
///
/// The Rive panel plays `mascot.riv` from rive-app/rive-ios (MIT) as a stand-in. A Lop .riv has
/// to be authored in the Rive editor; this screen only proves the runtime renders in Piko and
/// gives us something to measure.
struct LopLab: View {
    @State private var listening = false
    @State private var loudness = 0.4
    @State private var mood: LopMood = .calm
    @State private var flat = false

    // loadCdn: false — the runtime otherwise fetches CDN-hosted assets from public.rive.app,
    // which would break "nothing leaves the device".
    @State private var rive = RiveViewModel(fileName: "mascot", stateMachineName: nil, loadCdn: false)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Lop rig lab").font(.largeTitle.bold())

                HStack(spacing: 16) {
                    panel("SwiftUI Canvas") {
                        LopRigView(inputs: LopInputs(listening: listening, loudness: loudness, mood: mood), soft: !flat)
                    }
                    panel("Rive runtime (sample file)") {
                        rive.view()
                    }
                }

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

    private func panel(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) {
            content()
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(flat ? Color.black : Color(red: 0.98, green: 0.97, blue: 0.95),
                            in: RoundedRectangle(cornerRadius: 20))
            Text(title).font(.caption.bold())
        }
    }
}
#endif
