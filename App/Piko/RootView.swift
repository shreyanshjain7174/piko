import SwiftUI
import UIKit
import PikoKit
import PikoUI

struct RootView: View {
    @State private var selection: Screen = .home
    @StateObject private var model = HomeViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    enum Screen: Hashable {
        case home, history, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "waveform", value: .home) {
                ArmView(model: model)
            }
            Tab("History", systemImage: "clock", value: .history) {
                NavigationStack { HistoryView() }
            }
            Tab("Settings", systemImage: "slider.horizontal.3", value: .settings) {
                SettingsView(model: model)
            }
        }
        .tint(Color(red: 0.24, green: 0.33, blue: 0.92))
        .preferredColorScheme(.dark)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.observe()
        }
        .onChange(of: selection) { _, _ in model.refresh() }
        .onAppear {
            // First run: the setup walkthrough introduces itself once. UI tests can force
            // it (-pikoForceOnboarding) or opt out (-pikoSkipOnboarding).
            if ProcessInfo.processInfo.arguments.contains("-pikoForceOnboarding") {
                showOnboarding = true
            } else if !hasSeenOnboarding,
                      !ProcessInfo.processInfo.arguments.contains("-pikoSkipOnboarding") {
                showOnboarding = true
                hasSeenOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: HomeViewModel
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground(phase: .idle, tint: model.skin.controlTint)
                    .ignoresSafeArea()
                Form {
                    Section {
                        Button { showSetup = true } label: {
                            Label("Set up the Piko keyboard", systemImage: "keyboard")
                                .foregroundStyle(.white)
                        }
                        LabeledContent("Microphone", value: model.microphonePermission)
                            .foregroundStyle(.white.opacity(0.85))
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("App permissions", systemImage: "arrow.up.forward.app")
                                .foregroundStyle(.white)
                        }
                    } header: {
                        Text("Get set up")
                            .foregroundStyle(.white.opacity(0.5))
                    } footer: {
                        Text("Keyboard Full Access is managed in iPhone Settings.")
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    Section("Make it yours") {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 16) {
                                PikoFace(phase: model.phase, skin: model.skin)
                                    .frame(width: 64, height: 70)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.skin.displayName).font(.headline).foregroundStyle(.white)
                                    Text("Your character and keyboard accent")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            }
                            HStack(spacing: 14) {
                                ForEach(Skin.allCases, id: \.self) { skin in
                                    skinOption(skin)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    Section {
                        NavigationLink {
                            MemoryView()
                        } label: {
                            Label("What Piko remembers", systemImage: "memorychip")
                                .foregroundStyle(.white)
                        }
                        Toggle(isOn: Binding(
                            get: { PikoSpeaker.shared.isEnabled },
                            set: { PikoSpeaker.shared.isEnabled = $0 })) {
                            Label("Let Piko speak", systemImage: "waveform.badge.magnifyingglass")
                                .foregroundStyle(.white)
                        }
                        Button {
                            PikoSpeaker.shared.preview()
                        } label: {
                            Label("Preview Piko's voice", systemImage: "person.wave.2")
                                .foregroundStyle(.white)
                        }
                    } header: {
                        Text("Companion")
                            .foregroundStyle(.white.opacity(0.5))
                    } footer: {
                        Text("Piko speaks softly, and never while it is listening. Everything it knows is on this iPhone.")
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    Section {
                        Label("Transcribed on this iPhone", systemImage: "iphone")
                            .foregroundStyle(.white.opacity(0.85))
                        Label("No account. No cloud storage.", systemImage: "lock.shield")
                            .foregroundStyle(.white.opacity(0.85))
                    } header: {
                        Text("Private by design")
                            .foregroundStyle(.white.opacity(0.5))
                    } footer: {
                        Text("Copying or sharing text is always your choice. You can delete individual dictations from History.")
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    if model.sessionActive {
                        Section {
                            Button(role: .destructive) {
                                Task { await model.endSession() }
                            } label: {
                                Label("End voice session", systemImage: "power")
                            }
                            .disabled(model.isBusy || model.phase == .tidying)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showSetup) { OnboardingView(isPresented: $showSetup) }
        }
    }

    private func skinOption(_ skin: Skin) -> some View {
        let selected = model.skin == skin
        return Button { model.selectSkin(skin) } label: {
            VStack(spacing: 6) {
                PikoFace(phase: .idle, skin: skin)
                    .frame(width: 50, height: 53)
                    .padding(8)
                    .background(.white.opacity(selected ? 0.14 : 0.06), in: Circle())
                    .overlay {
                        Circle().strokeBorder(selected ? skin.controlTint : .clear, lineWidth: 2)
                    }
                Text(skin.displayName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(skin.displayName) skin")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
