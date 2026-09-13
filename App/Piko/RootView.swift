import SwiftUI
import UIKit
import PikoKit
import PikoUI

struct RootView: View {
    @State private var selection: Screen = .home
    @StateObject private var model = HomeViewModel()
    @Environment(\.scenePhase) private var scenePhase

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
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.observe()
        }
        .onChange(of: selection) { _, _ in model.refresh() }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: HomeViewModel
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showSetup = true } label: {
                        Label("Set up the Piko keyboard", systemImage: "keyboard")
                    }
                    LabeledContent("Microphone", value: model.microphonePermission)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("App permissions", systemImage: "arrow.up.forward.app")
                    }
                } header: {
                    Text("Get connected")
                } footer: {
                    Text("Keyboard Full Access is managed in iPhone Settings.")
                }

                Section("Make it yours") {
                    HStack(spacing: 16) {
                        PikoFace(phase: model.phase, skin: model.skin)
                            .frame(width: 64, height: 70)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.skin.displayName).font(.headline)
                            Text("Your character and keyboard accent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    Picker("Appearance", selection: Binding(get: { model.skin }, set: { model.selectSkin($0) })) {
                        ForEach(Skin.allCases, id: \.self) { skin in
                            Text(skin.displayName).tag(skin)
                        }
                    }
                }

                Section {
                    Label("Transcribed on this iPhone", systemImage: "iphone")
                    Label("No account. No cloud storage.", systemImage: "lock.shield")
                } header: {
                    Text("Private by design")
                } footer: {
                    Text("Copying or sharing text is always your choice. You can delete individual dictations from History.")
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
            .navigationTitle("Settings")
            .sheet(isPresented: $showSetup) { OnboardingView(isPresented: $showSetup) }
        }
    }
}
