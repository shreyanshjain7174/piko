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
            .onAppear { print("Piko startup failed: \(error)") }
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
        .pikoThemed(model.skin)
        .task(id: scenePhase) {
            model.setCompanionActive(scenePhase == .active && selection == .home)
            guard scenePhase == .active else { return }
            await model.observe()
        }
        .onChange(of: selection) { _, screen in
            model.refresh()
            model.setCompanionActive(scenePhase == .active && screen == .home)
        }
        .onAppear {
            let homeTab = $selection
            app.onTalkRequested = { [weak model] in
                homeTab.wrappedValue = .home
                await model?.talk()
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: HomeViewModel
    @State private var showSetup = false
    @State private var showResetLearning = false
    @Environment(\.pikoTheme) private var theme
    @AppStorage(KeyboardPreferences.autoListenKey, store: UserDefaults(suiteName: AppGroup.identifier))
    private var autoListen = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Personality", selection: Binding(
                        get: { model.companionPreferences.personality },
                        set: { model.setPersonality($0) }
                    )) {
                        ForEach(PikoPersonality.allCases, id: \.self) { personality in
                            Text(personality.displayName).tag(personality)
                        }
                    }
                    Toggle("Quiet mode", isOn: Binding(
                        get: { model.companionPreferences.quietMode },
                        set: { model.setQuietMode($0) }
                    ))
                    Toggle("Spoken replies", isOn: Binding(
                        get: { model.spokenRepliesEnabled },
                        set: { model.setSpokenReplies($0) }
                    ))
                    LabeledContent("Greeting feedback",
                                   value: "\(model.companionPreferences.greetings.engagedCount) accepted / \(model.companionPreferences.greetings.dismissedCount) dismissed")
                    LabeledContent("Result feedback",
                                   value: "\(model.companionPreferences.completions.engagedCount) accepted / \(model.companionPreferences.completions.dismissedCount) dismissed")
                    if let message = model.companionPreferenceError {
                        Text(message).font(.footnote).foregroundStyle(theme.ink2)
                    }
                    Button(model.companionPreferenceError == nil ? "Reset learned attention" : "Reset damaged companion preferences") {
                        showResetLearning = true
                    }
                        .accessibilityIdentifier("companion.resetLearning")
                } header: {
                    Text("Your quiet sidekick")
                } footer: {
                    Text("Piko keeps the last 8 explicit responses to greetings and results on this iPhone. Repeated dismissals quiet routine nudges. Results, approvals and errors stay visible. Piko does not watch other apps or guess your mood.")
                }

                Section {
                    SkinPicker(selection: model.skin, phase: model.phase) { model.selectSkin($0) }
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                } header: {
                    Text("Pick your Piko")
                } footer: {
                    Text("Piko’s look colours the whole app and the Piko keyboard.")
                }

                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(model.weeklyDumps)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.ink)
                            .contentTransition(.numericText())
                        Text(model.weeklyDumps == 1 ? "brain-dump in the last 7 days" : "brain-dumps in the last 7 days")
                            .foregroundStyle(theme.ink2)
                    }
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
                    Text("Type into other apps")
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
                    Text("Permissions")
                } footer: {
                    Text("While Piko is ready, the microphone stays active and idle audio is discarded. Piko switches itself off after 5 quiet minutes.")
                }

                Section {
                    Label("Listening and sorting happen on this iPhone", systemImage: "iphone")
                    Label("No account. No cloud.", systemImage: "lock.fill")
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
            .pikoForm()
            .navigationTitle("Settings")
            .sheet(isPresented: $showSetup) { OnboardingView(isPresented: $showSetup) }
            .alert(model.companionPreferenceError == nil ? "Reset Piko's learned attention?" : "Reset Piko's companion preferences?",
                   isPresented: $showResetLearning) {
                Button(model.companionPreferenceError == nil ? "Reset patterns" : "Reset preferences", role: .destructive) {
                    model.resetCompanionLearning()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(model.companionPreferenceError == nil
                     ? "This clears only companion feedback. Your personality, quiet choice and history stay unchanged."
                     : "This replaces unreadable companion preferences with the choices currently shown. Your history and keyboard settings are unchanged.")
            }
        }
    }
}

/// Four Pikos side by side; the chosen one sits on Piko's own colour. Choosing repaints the app.
private struct SkinPicker: View {
    let selection: Skin
    let phase: SessionPhase
    let onSelect: (Skin) -> Void
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Skin.allCases, id: \.self) { skin in
                let chosen = skin == selection
                Button {
                    withAnimation(.easeInOut(duration: 0.35)) { onSelect(skin) }
                } label: {
                    VStack(spacing: 8) {
                        PikoFace(phase: chosen ? .armed : .idle, skin: skin)
                            .frame(height: 58)
                        Text(skin.displayName)
                            .font(.subheadline.weight(chosen ? .bold : .medium))
                            .foregroundStyle(chosen ? theme.onPiko : theme.ink2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(chosen ? theme.piko : theme.cardRaised,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(skin.displayName): \(skin.tagline)")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension View {
    /// A grouped Form or List set in the skin's room instead of system grey.
    func pikoForm() -> some View {
        modifier(PikoFormStyle())
    }
}

private struct PikoFormStyle: ViewModifier {
    @Environment(\.pikoTheme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.ground)
            .toolbarBackground(theme.ground, for: .navigationBar)
    }
}
