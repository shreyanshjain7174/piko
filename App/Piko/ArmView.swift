import AVFAudio
import Combine
import SwiftUI
import UIKit
import PikoKit
import PikoUI
import PikoBrain

/// App-only presentation state. All capture and persistence still use the existing coordinators.
@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var isBusy = false
    @Published var text = ""
    @Published var error: String?
    @Published private(set) var needsMicrophoneSettings = false
    @Published private(set) var skin: Skin = .cute
    @Published private(set) var microphonePermission = "Not requested"
    @Published private(set) var memoryLine: String?
    @Published private(set) var suggestion: Suggestion?
    @Published var askInput: String = ""
    @Published private(set) var askAnswer: AgentTurn?
    @Published private(set) var isAsking = false
    let activity = VoiceActivityModel()
    let agent = PikoAgent(memory: AppComposition.shared.memory)
    private var suggestionSpoken = false
    private var lastResultID: UUID?

    init() {
        lastResultID = AppComposition.shared.channel.readResult()?.id
        refresh()
    }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canEdit: Bool { !isBusy && phase != .capturing && phase != .tidying }
    var sessionActive: Bool { phase != .idle }

    func refresh() {
        let app = AppComposition.shared
        let nextPhase = app.captureCoordinator.isTidying ? SessionPhase.tidying : app.session.currentPhase
        if phase != nextPhase { phase = nextPhase }
        let nextSkin = app.channel.readState()?.skin ?? .cute
        if skin != nextSkin { skin = nextSkin }
        // Armed counts as active so the orb idles with a gentle breath, not frozen.
        activity.setActive(phase == .capturing || phase == .armed)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphonePermission = "Allowed"
        case .denied: microphonePermission = "Off"
        default: microphonePermission = "Not requested"
        }
    }

    func observe() async {
        refresh()
        await loadMemoryLine()
        await loadSuggestion()
        let channel = AppComposition.shared.channel
        for await signal in channel.signals {
            guard !Task.isCancelled else { return }
            if signal == .audioLevelUpdated {
                if let sample = (channel as? any AudioLevelChannel)?.readAudioLevel() {
                    activity.receive(sample)
                }
                continue
            }
            refresh()
            if signal == .draftUpdated, phase == .capturing, let draft = channel.readDraft() {
                text = draft.text
            }
            if signal == .resultReady, let result = channel.readResult(), result.id != lastResultID {
                lastResultID = result.id
                text = result.shipped
                await loadMemoryLine()
                await loadSuggestion()
                suggestionSpoken = false
            }
        }
    }

    /// The harness's suggest route, surfaced once per launch — quiet by default, never
    /// during capture. Tapping the card speaks it (if the voice is on) with a soft
    /// double-tap haptic.
    func loadSuggestion() async {
        let packet = await AppComposition.shared.memory.recall(query: "")
        let hour = Calendar.current.component(.hour, from: .now)
        suggestion = SuggestionEngine.suggestion(for: packet?.entities ?? [], hour: hour)
    }

    func suggestionTapped() {
        guard let suggestion else { return }
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred(intensity: 0.7)
        haptic.impactOccurred()
        PikoSpeaker.shared.speak(suggestion.text, phase: phase)
        suggestionSpoken = true
    }

    func toggleCapture() async {
        guard !isBusy, !AppComposition.shared.captureCoordinator.isTidying else { return }
        if AppComposition.shared.session.currentPhase == .capturing {
            await endDictation()
        } else {
            await beginDictation()
        }
    }

    /// Touch-down of the hold-to-talk gesture. Arms on demand, then starts capture.
    func beginDictation() async {
        guard !isBusy, !AppComposition.shared.captureCoordinator.isTidying else { return }
        guard AppComposition.shared.session.currentPhase != .capturing else { return }
        isBusy = true
        error = nil
        defer { isBusy = false; refresh() }
        do {
            try await prepareSession()
            text = ""
            try await AppComposition.shared.captureCoordinator.startCapture()
        } catch {
            present(error)
        }
    }

    /// Release of the hold-to-talk gesture.
    func endDictation() async {
        guard !AppComposition.shared.captureCoordinator.isTidying else { return }
        guard AppComposition.shared.session.currentPhase == .capturing else { return }
        await AppComposition.shared.captureCoordinator.stopCapture()
        refresh()
    }

    func startSession() async {
        guard !isBusy, !sessionActive else { return }
        isBusy = true
        error = nil
        defer { isBusy = false; refresh() }
        do { try await prepareSession() } catch { present(error) }
    }

    func endSession() async {
        guard !isBusy, !AppComposition.shared.captureCoordinator.isTidying else { return }
        isBusy = true
        defer { isBusy = false; refresh() }
        let app = AppComposition.shared
        if app.session.currentPhase == .capturing { await app.captureCoordinator.stopCapture() }
        await app.session.disarm()
        await app.liveActivityController.end()
    }

    func selectSkin(_ skin: Skin) {
        SkinSelection.apply(skin, via: AppComposition.shared.channel)
        self.skin = skin
    }

    /// Submit a typed ask through the same harness the microphone would hit.
    /// Recall and suggest come back inline as an `AgentTurn` under the field;
    /// write-route input becomes a real dictation result and lands in the
    /// transcript card, so the two entry points share one destination.
    func submitAsk() async {
        let query = askInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isAsking else { return }
        isAsking = true
        defer { isAsking = false }
        let turn = await AppComposition.shared.askCoordinator.handle(query)
        if turn != nil { askAnswer = turn }
        askInput = ""
    }

    func tapAskChip(_ label: String) async {
        let turn = await AppComposition.shared.askCoordinator.chip(label)
        if let turn { askAnswer = turn }
    }

    func dismissAskAnswer() {
        askAnswer = nil
    }

    /// One personal line, straight from the on-device index. Empty history gets the promise
    /// instead — never a fake memory.
    func loadMemoryLine() async {
        let recent = await AppComposition.shared.memory.search("", limit: 1)
        if let last = recent.first {
            var said = last.shipped.trimmingCharacters(in: .whitespacesAndNewlines)
            if said.count > 72 { said = said.prefix(72) + "…" }
            memoryLine = said.isEmpty ? nil : "Last time you said “\(said)”"
        } else {
            memoryLine = nil
        }
    }

    private func prepareSession() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw PikoError.microphoneDenied }
        if AppComposition.shared.session.currentPhase == .idle {
            try await AppComposition.shared.armSession()
        }
    }

    private func present(_ failure: any Error) {
        needsMicrophoneSettings = (failure as? PikoError).map {
            if case .microphoneDenied = $0 { return true }
            return false
        } ?? false
        error = PikoError.userMessage(for: failure)
    }
}

struct ArmView: View {
    @ObservedObject var model: HomeViewModel
    @State private var showSetup = false
    @State private var copiedText: String?
    @State private var isPressing = false
    @State private var pressBegan = Date.distantPast
    @State private var quickTapMode = false
    @FocusState private var isEditing: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground(phase: model.phase, tint: model.skin.controlTint)
                    .ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        greeting
                        hero
                        statusLine
                        if let suggestion = model.suggestion, model.phase != .capturing {
                            suggestionCard(suggestion)
                        }
                        if model.phase == .capturing {
                            waveStrip
                        }
                        if let error = model.error { errorCard(error) }
                        if model.hasText || model.phase == .capturing || model.phase == .tidying {
                            transcriptCard
                        }
                        askBar
                        sessionStrip
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) {
                    // A fixed footer, not scroll content: the privacy promise is always
                    // fully visible, never half-swallowed by the floating tab bar.
                    // Copy reflects the currently selected engine — silence would be
                    // less honest than saying "on this iPhone" when it's true.
                    Label(privacyFooterText, systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                }
            }
            .navigationTitle("piko")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSetup = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Keyboard setup")
                    .accessibilityIdentifier("home.setup")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditing = false }
                }
            }
            .sheet(isPresented: $showSetup) { OnboardingView(isPresented: $showSetup) }
            .onChange(of: model.text) { _, _ in copiedText = nil }
            .preferredColorScheme(.dark)
        }
    }

    /// The typed side of the harness: recall, suggest, and write questions go through
    /// the same router the microphone hits. Quiet by default — a single-line field
    /// with a soft glass background. An answer unfolds inline; write-route input has
    /// no answer here, because its answer is the transcript that just landed.
    private var askBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.55))
                    .accessibilityHidden(true)
                TextField("Ask Piko, or write instead", text: $model.askInput)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .tint(.cyan)
                    .submitLabel(.send)
                    .onSubmit { Task { await model.submitAsk() } }
                    .accessibilityIdentifier("home.ask.input")
                    .accessibilityLabel("Ask Piko")
                if !model.askInput.isEmpty {
                    Button {
                        Task { await model.submitAsk() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(model.isAsking ? .white.opacity(0.3) : .cyan)
                    }
                    .disabled(model.isAsking)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))

            if let turn = model.askAnswer {
                askAnswerCard(turn)
            }
        }
    }

    private func askAnswerCard(_ turn: AgentTurn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                PikoFace(phase: .idle, skin: model.skin)
                    .frame(width: 38, height: 40)
                    .accessibilityHidden(true)
                Text(turn.line)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    model.dismissAskAnswer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.35))
                }
                .accessibilityLabel("Dismiss answer")
            }
            if !turn.chips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(turn.chips, id: \.self) { chip in
                        Button {
                            Task { await model.tapAskChip(chip) }
                        } label: {
                            Text(chip)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.white.opacity(0.09), in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.ask.chip")
                    }
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var privacyFooterText: String {
        switch CaptureModeStore.readBackend() {
        case .onDevice: "On-device. Nothing ever leaves this iPhone."
        case .sarvamCloud: "Cloud voice engine is on. Audio goes to Sarvam."
        }
    }

    // MARK: - Scene pieces

    private var greetingWord: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning."
        case 12..<18: "Good afternoon."
        default: "Good evening."
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greetingWord)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .tracking(-0.8)
                .foregroundStyle(.white)
            Text(model.memoryLine ?? "A little less typing. A little more you.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
        }
    }

    /// The character lives inside the orb. Hold to talk, release to finish; a quick tap
    /// toggles instead, so both gestures keep their promise.
    private var hero: some View {
        ZStack {
            VoiceOrb(activity: model.activity, tint: model.skin.controlTint)
                .frame(width: 264, height: 264)
            PikoFace(phase: model.phase, skin: model.skin)
                .frame(width: 146, height: 154)
                .offset(y: 6)
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(isPressing && model.phase != .tidying ? 1.05 : 1)
        .animation(.spring(duration: 0.35), value: isPressing)
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 90,
                            perform: {}) { pressing in
            handlePressing(pressing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.phase == .capturing ? "Listening. Tap to stop dictation" : "Start dictation")
        .accessibilityHint("Hold to talk, release to finish. Double-tap toggles.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Task { await model.toggleCapture() } }
        .accessibilityIdentifier("home.dictate")
    }

    private func handlePressing(_ pressing: Bool) {
        isPressing = pressing
        if pressing {
            pressBegan = .now
            if quickTapMode {
                quickTapMode = false
                Task { await model.endDictation() }
            } else {
                Task { await model.beginDictation() }
            }
        } else {
            let elapsed = Date.now.timeIntervalSince(pressBegan)
            if elapsed < 0.35, model.phase == .capturing {
                quickTapMode = true
            } else {
                quickTapMode = false
                Task { await model.endDictation() }
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.phase.statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.subheadline.weight(.semibold))
            if !hintText.isEmpty {
                Text(hintText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.08), in: Capsule())
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.35), value: model.phase)
    }

    private var statusText: String {
        switch model.phase {
        case .idle: "Ready when you are"
        case .armed: "Session live"
        case .capturing: "Listening"
        case .tidying: "Tidying your words…"
        }
    }

    private var hintText: String {
        switch model.phase {
        case .capturing: "Release to finish"
        case .tidying: ""
        default: "Hold to talk"
        }
    }

    /// The visible stop affordance the moment listening starts — the whole strip ends capture.
    private var waveStrip: some View {
        Button {
            isEditing = false
            Task { await model.endDictation() }
        } label: {
            HStack(spacing: 14) {
                VoiceWave(activity: model.activity, tint: model.skin.controlTint)
                    .frame(height: 40)
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Finish dictation")
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.canEdit ? "Your words" : "Live transcript")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if model.canEdit && model.hasText {
                    Button {
                        model.text = ""
                        isEditing = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .accessibilityLabel("Clear text from Home")
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(.white)
                    .tint(.cyan)
                    .frame(minHeight: 92, maxHeight: 170)
                    .focused($isEditing)
                    .disabled(!model.canEdit)
                    .accessibilityLabel("Dictation text")
                    .accessibilityIdentifier("home.transcript")
                if !model.hasText {
                    Text(model.phase == .capturing ? "Go ahead — I'm listening." : "Your words land here.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = model.text
                        copiedText = model.text
                    } label: {
                        Label(copiedText == model.text ? "Copied" : "Copy",
                              systemImage: copiedText == model.text ? "checkmark" : "doc.on.doc")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                    }
                    ShareLink(item: model.text) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Share text")
                }
                .foregroundStyle(.white)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .disabled(!model.canEdit || !model.hasText)
        }
        .padding(18)
        .glassEffect(.regular.tint(Color(red: 0.04, green: 0.07, blue: 0.15).opacity(0.5)),
                     in: RoundedRectangle(cornerRadius: 26))
    }

    private var sessionStrip: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(model.skin.controlTint.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your voice, in any conversation")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Piko keyboard")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }

            Text(model.sessionActive
                 ? "Session live — Piko is listening in every text field."
                 : "After a one-time setup, arm a session and Piko follows you into any text field.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    Task {
                        if model.sessionActive { await model.endSession() }
                        else { await model.startSession() }
                    }
                } label: {
                    Label(model.sessionActive ? "End session" : "Start session",
                          systemImage: model.sessionActive ? "power" : "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 42)
                }
                .disabled(model.isBusy || model.phase == .tidying)
                .accessibilityIdentifier("home.session")
                Spacer()
                Button("Set up keyboard") { showSetup = true }
                    .font(.caption.weight(.medium))
                    .frame(minHeight: 42)
            }
            .foregroundStyle(.white)
        }
        .padding(18)
        .glassEffect(.regular.tint(Color(red: 0.04, green: 0.07, blue: 0.15).opacity(0.35)),
                     in: RoundedRectangle(cornerRadius: 26))
    }

    /// The harness's suggestion surface: one gentle line, tap to hear it. Never a list,
    /// never an exclamation mark, never shown mid-capture.
    private func suggestionCard(_ suggestion: Suggestion) -> some View {
        Button {
            model.suggestionTapped()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkle")
                    .font(.body)
                    .foregroundStyle(model.skin.controlTint)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("A thought")
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.45))
                    Text(suggestion.text)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: PikoSpeaker.shared.isEnabled ? "speaker.wave.2" : "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 2)
            }
            .padding(16)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Suggestion: \(suggestion.text)")
        .accessibilityHint("Double-tap to hear it")
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(.white)
            if model.needsMicrophoneSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.cyan)
            }
            Button("Dismiss") { model.error = nil }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
    }
}
