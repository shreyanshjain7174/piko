import SwiftUI
import PikoKit
import PikoUI

@main
struct PikoApp: App {
    var body: some Scene {
        WindowGroup { ArmView() }
    }
}

/// The only screen in v0.1. Its whole job is to be on screen long enough to legally open the
/// microphone and start the Live Activity — then get out of the way.
struct ArmView: View {
    @State private var phaseText: String = "idle"
    @State private var armError: String?
    @State private var hasArmedThisLaunch = false
    @State private var staleAtLaunch = false
    @State private var searchText = ""
    @State private var results: [CaptureResult] = []
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
                Picker("Skin", selection: $currentSkin) {
                    ForEach(Skin.allCases, id: \.self) { skin in
                        Text(skin.rawValue.capitalized).tag(skin)
                    }
                }
                .onChange(of: currentSkin) { _, newSkin in
                    SkinSelection.apply(newSkin, via: AppComposition.shared.channel)
                }
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
            }
            .searchable(text: $searchText)
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
        .task(id: searchText) {
            results = await AppComposition.shared.memory.search(searchText, limit: 50)
        }
    }
}
