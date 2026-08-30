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
            ScrollView {
                VStack(spacing: 24) {
                    PikoFace(phase: SessionPhase(rawValue: phaseText) ?? .idle, skin: currentSkin)
                        .frame(width: 180, height: 190)
                        .padding(.top, 12)

                    VStack(spacing: 6) {
                        Text("Piko")
                            .font(.largeTitle.bold())
                        statusPill
                    }

                    if showReArmBanner {
                        Label("Session ended — tap Arm to re-arm", systemImage: "arrow.clockwise")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }

                    Button {
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
                    } label: {
                        Label("Arm", systemImage: "mic.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(currentSkin.accent)

                    if let armError {
                        Text(armError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Skin")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Skin.allCases, id: \.self) { skin in
                                    let selected = currentSkin == skin
                                    Button {
                                        currentSkin = skin
                                        SkinSelection.apply(skin, via: AppComposition.shared.channel)
                                    } label: {
                                        Text(skin.rawValue.capitalized)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(
                                                Capsule().fill(
                                                    selected
                                                        ? skin.accent.opacity(0.22)
                                                        : Color(.secondarySystemBackground)
                                                )
                                            )
                                            .overlay(
                                                Capsule().strokeBorder(
                                                    selected ? skin.accent : .clear,
                                                    lineWidth: 1.5
                                                )
                                            )
                                            .foregroundStyle(selected ? skin.accent : .primary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(skin.rawValue)
                                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    NavigationLink {
                        HistoryView()
                    } label: {
                        HStack {
                            Label("History", systemImage: "clock.arrow.circlepath")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
                .padding(20)
            }
            .background(currentSkin.background.ignoresSafeArea())
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

    @ViewBuilder
    private var statusPill: some View {
        let (label, color): (String, Color) = switch SessionPhase(rawValue: phaseText) ?? .idle {
        case .idle: ("Idle", .secondary)
        case .armed: ("Armed", .green)
        case .capturing: ("Recording…", .red)
        case .tidying: ("Processing…", .orange)
        }
        Label(label, systemImage: "circle.fill")
            .labelStyle(.custom(dotColor: color))
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct DotLabelStyle: LabelStyle {
    let dotColor: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            configuration.title
        }
    }
}

private extension LabelStyle where Self == DotLabelStyle {
    static func custom(dotColor: Color) -> DotLabelStyle { DotLabelStyle(dotColor: dotColor) }
}

/// App-UI accent colors, deliberately separate from `PikoUI`'s internal `PikoPalette` (which is
/// scoped `internal` to that module for the character's own SVG rendering, not this screen's chrome).
private extension Skin {
    var accent: Color {
        switch self {
        case .cute: Color(red: 0.93, green: 0.62, blue: 0.20)
        case .cool: Color(red: 0.26, green: 0.35, blue: 0.88)
        case .hero: Color(red: 0.77, green: 0.57, blue: 0.16)
        case .sparkle: Color(red: 0.95, green: 0.42, blue: 0.66)
        }
    }

    var background: Color {
        Color(.systemGroupedBackground)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(result.shipped)
                    .font(.body)
                Text(result.raw)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
        .overlay {
            if results.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No history yet" : "No matches",
                    systemImage: "clock.arrow.circlepath"
                )
            }
        }
        .searchable(text: $searchText)
        .navigationTitle("History")
        .task(id: searchText) {
            results = await AppComposition.shared.memory.search(searchText, limit: 50)
        }
    }
}
