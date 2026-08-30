import SwiftUI
import PikoKit
import PikoUI

@main
struct PikoApp: App {
    var body: some Scene {
        WindowGroup { ArmView() }
    }
}

/// Its whole job is to be on screen long enough to legally open the microphone and start the
/// Live Activity — then get out of the way. History lives on its own separate screen; see
/// `HistoryView` below.
struct ArmView: View {
    @State private var phaseText: String = "idle"
    @State private var armError: String?
    @State private var hasArmedThisLaunch = false
    @State private var staleAtLaunch = false
    @State private var currentSkin: Skin = .cute

    private var showReArmBanner: Bool {
        (hasArmedThisLaunch && phaseText == "idle") || staleAtLaunch
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                PikoFace(phase: SessionPhase(rawValue: phaseText) ?? .idle, skin: currentSkin)
                    .frame(width: 140, height: 148)
                Text("Piko")
                Text("Session: \(phaseText)")
                if phaseText == SessionPhase.capturing.rawValue {
                    Text("Recording...")
                } else if phaseText == SessionPhase.tidying.rawValue {
                    Text("Processing...")
                }
                if showReArmBanner {
                    Text("Session ended — tap Arm to re-arm")
                }
                Button("Arm") {
                    Task {
                        do {
                            try await AppComposition.shared.armSession()
                            hasArmedThisLaunch = true
                            staleAtLaunch = false
                            armError = nil
                        } catch {
                            armError = "\(error)"
                        }
                    }
                }
                if let armError {
                    Text(armError)
                }
                HStack(spacing: 8) {
                    ForEach(Skin.allCases, id: \.self) { skin in
                        let selected = currentSkin == skin
                        Button {
                            currentSkin = skin
                            SkinSelection.apply(skin, via: AppComposition.shared.channel)
                        } label: {
                            Text(skin.rawValue.capitalized)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(
                                        selected
                                            ? Color.accentColor.opacity(0.25)
                                            : Color(.secondarySystemBackground)
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(skin.rawValue)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                NavigationLink("History") {
                    HistoryView()
                }
            }
            .padding()
        }
        .task {
            // Process-kill sub-case: reuse Phase 1's existing staleness rule, no new heuristic.
            if let state = AppComposition.shared.channel.readState(), !state.isLive() {
                staleAtLaunch = true
            }
        }
        .task {
            for await phase in AppComposition.shared.session.phase {
                phaseText = phase.rawValue
                currentSkin = AppComposition.shared.channel.readState()?.skin ?? .cute
            }
        }
    }
}

/// Kept off `ArmView` entirely — a searchable List has no business sharing a screen with
/// controls that must always be reliably tappable (see the phase-8 history-overlap
/// incident: a `.searchable` List intercepted taps meant for `ArmView`'s own buttons).
struct HistoryView: View {
    @State private var searchText = ""
    @State private var results: [CaptureResult] = []

    var body: some View {
        List(results, id: \.id) { result in
            VStack(alignment: .leading) {
                Text(result.shipped)
                Text(result.raw)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $searchText)
        .navigationTitle("History")
        .task(id: searchText) {
            results = await AppComposition.shared.memory.search(searchText, limit: 50)
        }
    }
}
