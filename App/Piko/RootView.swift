import SwiftUI
import UIKit
import PikoKit
import PikoUI

struct RootView: View {
    var body: some View {
        switch AppComposition.shared {
        case .success(let app):
            PikoRootContent(app: app)
        case .failure(let error):
            ContentUnavailableView {
                Label("Piko could not start", systemImage: "exclamationmark.triangle")
            } description: {
                Text((error as? PikoError)?.userMessage
                     ?? PikoError.storageUnavailable.userMessage)
            }
        }
    }
}

private struct PikoRootContent: View {
    let app: AppComposition
    @State private var selection: Screen = .home
    @StateObject private var model: HomeViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(app: AppComposition) {
        self.app = app
        _model = StateObject(wrappedValue: HomeViewModel(app: app))
    }

    enum Screen: Hashable {
        case home, filed, history, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: .home) {
                ArmView(model: model)
            }
            Tab("Filed", systemImage: "tray.full", value: .filed) {
                NavigationStack { FiledView(app: app) }
            }
            Tab("History", systemImage: "clock", value: .history) {
                NavigationStack { HistoryView(app: app) }
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
    @AppStorage(KeyboardPreferences.autoListenKey, store: UserDefaults(suiteName: AppGroup.identifier))
    private var autoListen = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Brain-dumps this week", value: "\(model.weeklyDumps)")
                } header: {
                    Text("Your week")
                } footer: {
                    Text("Talk to Piko from anywhere: add Talk to Piko to the Action Button (Settings › Action Button › Shortcut) or to Control Center.")
                }

                Section {
                    Button { showSetup = true } label: {
                        Label("Set up the Piko keyboard", systemImage: "keyboard")
                    }
                    Toggle("Listen when the Piko keyboard opens", isOn: $autoListen)
                } header: {
                    Text("Optional: type into other apps")
                }

                Section {
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
                    Text("While Piko is ready, the microphone stays active and idle audio is discarded. Piko switches itself off after 5 quiet minutes.")
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
                    Label("Listening and sorting happen on this iPhone", systemImage: "iphone")
                    Label("No account. No cloud.", systemImage: "lock.shield")
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
