import AVFAudio
import Combine
import SwiftUI
import UIKit
import PikoKit
import PikoBrain
import PikoUI

/// App-only presentation state. All capture and persistence still use the existing coordinators.
@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var isBusy = false
    @Published var text = ""
    @Published var error: String?
    @Published private(set) var needsSpeechDownload = false
    @Published private(set) var notice: String?
    @Published private(set) var needsMicrophoneSettings = false
    @Published private(set) var skin: Skin = .cute
    @Published private(set) var microphonePermission = "Not requested"
    @Published private(set) var assistant: AssistantState?
    @Published private(set) var weeklyDumps = 0
    private var conversation = Conversation()
    private let speaker = Speaker()
    private let calendar = EventKitCalendar()
    private var pauseWatch: Task<Void, Never>?
    private var lastDraftChange = Date()
    private var isFollowUp = false
    /// Set when listening is cancelled by a tap, so the clipped words are not treated as speech.
    private var discardNextResult = false
    let activity = VoiceActivityModel()
    private var lastResultID: UUID?
    private let app: AppComposition

    init(app: AppComposition) {
        self.app = app
        lastResultID = app.channel.readResult()?.id
        app.captureCoordinator.onFailure = { [weak self] in self?.present($0) }
        app.captureCoordinator.onCleanupBypassed = { [weak self] in self?.notice = $0 }
        app.captureCoordinator.onNothingHeard = { [weak self, weak app] in
            guard let self, app?.captureCoordinator.lastCaptureFromKeyboard == false else { return }
            if !self.isFollowUp {
                self.notice = "I didn’t catch that. Tap Talk to Piko and try again."
            }
            Task { await self.finishTurn() }
        }
        app.onTalkRequested = { [weak self] in await self?.talk() }
        app.onStopRequested = { [weak self] in
            self?.speaker.stop()
            self?.pauseWatch?.cancel()
            self?.conversation = Conversation()
            self?.assistant = nil
        }
        refresh()
        weeklyDumps = app.dumpLog.countLastSevenDays()
    }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canEdit: Bool { !isBusy && phase != .capturing && phase != .tidying }
    var sessionActive: Bool { phase != .idle }

    func refresh() {
        let app = self.app
        let nextPhase = app.captureCoordinator.isTidying ? SessionPhase.tidying : app.session.currentPhase
        if phase != nextPhase { phase = nextPhase }
        let nextSkin = app.channel.readState()?.skin ?? .cute
        if skin != nextSkin { skin = nextSkin }
        activity.setActive(phase == .capturing)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphonePermission = "Allowed"
        case .denied: microphonePermission = "Off"
        default: microphonePermission = "Not requested"
        }
    }

    func observe() async {
        refresh()
        let channel = app.channel
        // A capture stopped from the Dynamic Island can finish while Piko is in the background,
        // when nothing is listening. Pick up that result as soon as Piko is back on screen.
        if let result = channel.readResult(), result.id != lastResultID {
            lastResultID = result.id
            text = result.shipped
            if !app.captureCoordinator.lastCaptureFromKeyboard {
                Task { await self.respond(to: result) }
            }
        }
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
                if draft.text != text { lastDraftChange = .now }
                text = draft.text
            }
            if signal == .resultReady, let result = channel.readResult(), result.id != lastResultID {
                lastResultID = result.id
                text = result.shipped
                if !app.captureCoordinator.lastCaptureFromKeyboard {
                    Task { await self.respond(to: result) }
                }
            }
        }
    }

    func toggleCapture() async {
        guard !isBusy, !app.captureCoordinator.isTidying else { return }
        isBusy = true
        error = nil
        notice = nil
        defer { isBusy = false; refresh() }
        let app = self.app
        if app.session.currentPhase == .capturing {
            pauseWatch?.cancel()
            await app.captureCoordinator.stopCapture()
            return
        }
        await listen(followUp: conversation.isWaiting)
    }

    /// Talk to Piko from Control Center, the Action Button or Siri.
    func talk() async {
        guard !isBusy, app.session.currentPhase != .capturing, !app.captureCoordinator.isTidying else { return }
        await listen(followUp: conversation.isWaiting)
    }

    /// Starts listening and ends the turn on its own when the speaker pauses — no "I'm done" tap.
    private func listen(followUp: Bool) async {
        speaker.stop()
        error = nil
        notice = nil
        do {
            try await prepareSession()
            text = ""
            discardNextResult = false
            await app.showLiveActivity()
            try await app.captureCoordinator.startCapture()
            isFollowUp = followUp
            lastDraftChange = .now
            watchForPause()
        } catch {
            present(error)
            await finishTurn()
        }
    }

    private func watchForPause() {
        pauseWatch?.cancel()
        let started = Date()
        pauseWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled, self.app.session.currentPhase == .capturing else { return }
                let heard = !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let quiet = Date().timeIntervalSince(self.lastDraftChange)
                let waited = Date().timeIntervalSince(started)
                if (heard && quiet >= Self.endOfTurnPause) || (!heard && waited >= (self.isFollowUp ? 6 : 10)) {
                    await self.app.captureCoordinator.stopCapture()
                    return
                }
            }
        }
    }

    /// Silence after speech that ends a turn. Short enough to feel instant, long enough for a breath.
    static let endOfTurnPause: TimeInterval = 1.6

    func startSession() async {
        guard !isBusy, !sessionActive else { return }
        isBusy = true
        error = nil
        defer { isBusy = false; refresh() }
        do { try await prepareSession() } catch { present(error) }
    }

    func endSession() async {
        guard !isBusy, !app.captureCoordinator.isTidying else { return }
        isBusy = true
        defer { isBusy = false; refresh() }
        let app = self.app
        if app.session.currentPhase == .capturing { await app.captureCoordinator.stopCapture(endSession: true) }
        await app.session.disarm()
        await app.liveActivityController.end()
    }

    /// One voice turn: answer a pending question, or plan a new request, on-device.
    func respond(to result: CaptureResult) async {
        pauseWatch?.cancel()
        if discardNextResult {
            discardNextResult = false
            return
        }
        let app = self.app
        if conversation.isWaiting,
           let reply = await hear(result.shipped) {
            await handle(reply)
            return
        }
        assistant = .thinking
        do {
            if result.route == .recall {
                var history: [CaptureResult] = []
                for keyword in RecallQuery.keywords(from: result.shipped) {
                    for match in await app.memory.search(keyword, limit: 5)
                    where match.id != result.id && !history.contains(where: { $0.id == match.id }) {
                        history.append(match)
                    }
                }
                let answer = try await app.organizer.answer(result.shipped, from: Array(history.prefix(8)))
                assistant = .answer(answer)
                await speaker.say(answer)
                await finishTurn()
            } else {
                let plan = try await app.planner.plan(result.shipped, tools: app.harness.actionDescriptors, now: .now)
                guard !plan.isEmpty else {
                    assistant = nil
                    notice = "I couldn’t find anything to do there."
                    await finishTurn()
                    return
                }
                var talk = conversation
                let reply = await talk.begin(plan, context: calendar, now: .now)
                conversation = talk
                await handle(reply)
            }
        } catch {
            assistant = nil
            present(error)
            await finishTurn()
        }
    }

    /// Conversation is a value type; copy, update across the suspension, then store back.
    private func hear(_ text: String) async -> Conversation.Reply? {
        var talk = conversation
        let reply = await talk.hear(text, context: calendar, now: .now)
        conversation = talk
        return reply
    }

    private func handle(_ reply: Conversation.Reply) async {
        switch reply {
        case .ask(let prompt), .confirm(let prompt):
            let canConfirm = conversation.waiting == .confirm
            assistant = .proposed(conversation.plan, prompt: prompt, canConfirm: canConfirm)
            await speaker.say(prompt)
            // The user may have tapped Do it or Discard while Piko was speaking.
            guard case .proposed = assistant, conversation.isWaiting else { return }
            await listen(followUp: true)
        case .run(let ack):
            await execute(conversation.plan, ack: ack)
        case .cancelled(let message):
            assistant = nil
            notice = message
            await speaker.say(message)
            await finishTurn()
        }
    }

    private func execute(_ plan: [ToolCall], ack: String) async {
        assistant = .thinking
        let outcomes = await app.harness.run(plan, approve: { _ in true })
        app.dumpLog.record()
        weeklyDumps = app.dumpLog.countLastSevenDays()
        conversation = Conversation()
        assistant = .done(outcomes)
        let allDone = outcomes.allSatisfy { if case .done = $0.status { true } else { false } }
        await speaker.say(allDone ? (ack == "Saved." ? "Saved." : "Done.") : "Some of that didn’t work. Have a look.")
        await finishTurn()
    }

    /// "Do it" on the card — the same as saying yes.
    func runPlan() async {
        await stopListeningQuietly()
        if let reply = await hear("yes") {
            await handle(reply)
        }
    }

    func dismissAssistant() {
        speaker.stop()
        conversation = Conversation()
        assistant = nil
        Task {
            await stopListeningQuietly()
            await finishTurn()
        }
    }

    private func stopListeningQuietly() async {
        pauseWatch?.cancel()
        speaker.stop()
        guard app.session.currentPhase == .capturing else { return }
        discardNextResult = true
        await app.captureCoordinator.stopCapture()
    }

    /// Ends the visible part of a turn: nothing left in the Dynamic Island or on the Lock Screen.
    private func finishTurn() async {
        pauseWatch?.cancel()
        isFollowUp = false
        await app.liveActivityController.end()
    }

    func selectSkin(_ skin: Skin) {
        SkinSelection.apply(skin, via: app.channel)
        self.skin = skin
    }

    private func prepareSession() async throws {
        if app.session.currentPhase == .idle {
            try await app.armSession()
        }
    }

    func downloadSpeechAssets() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false; refresh() }
        do {
            try await app.prepareSpeech(allowDownload: true)
            needsSpeechDownload = false
            error = nil
            notice = "Speech is ready for offline use. Start a session when you are ready."
        } catch { present(error) }
    }

    private func present(_ failure: any Error) {
        needsMicrophoneSettings = (failure as? PikoError).map {
            if case .microphoneDenied = $0 { return true }
            return false
        } ?? false
        needsSpeechDownload = (failure as? PikoError).map {
            if case .speechAssetsMissing = $0 { return true }
            return false
        } ?? false
        error = PikoError.userMessage(for: failure)
    }
}

enum AssistantState: Equatable {
    case thinking
    case proposed([ToolCall], prompt: String, canConfirm: Bool)
    case answer(String)
    case done([ToolOutcome])
}

/// Home is a conversation with Piko: Piko asks, you answer, Piko files it. The room wears the
/// chosen skin; the one filled control is the Talk button, painted in Piko's own body colour.
struct ArmView: View {
    @ObservedObject var model: HomeViewModel
    @State private var showSetup = false
    @State private var copiedText: String?
    @FocusState private var isEditing: Bool
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    #if DEBUG
                    if UserDefaults.standard.string(forKey: "PikoBenchmarkCaptureFixture") != nil {
                        Text("Developer fixture replay. Microphone input is discarded.")
                            .font(.caption)
                            .foregroundStyle(theme.ink2)
                    }
                    #endif
                    HStack {
                        Text("piko")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .tracking(-0.8)
                            .foregroundStyle(theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button { showSetup = true } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.title3)
                                .foregroundStyle(theme.ink2)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("How to use Piko")
                    }
                    PikoFace(phase: model.phase, skin: model.skin)
                        .frame(width: 112, height: 118)
                        .padding(.leading, 4)
                        .accessibilityHidden(true)
                    pikoBubble
                    if model.hasText || model.phase == .capturing || model.phase == .tidying {
                        yourBubble
                    }
                    if let assistant = model.assistant { assistantBubble(assistant) }
                    if let error = model.error { errorBubble(error) }
                    if let notice = model.notice {
                        Text(notice)
                            .font(.subheadline)
                            .foregroundStyle(theme.ink2)
                            .padding(.horizontal, 6)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .animation(.spring(duration: 0.4), value: model.phase)
                .animation(.spring(duration: 0.4), value: model.assistant)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(theme.ground)
            .safeAreaInset(edge: .bottom) { talkBar }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditing = false }
                }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSetup) { OnboardingView(isPresented: $showSetup) }
            .onChange(of: model.text) { _, _ in copiedText = nil }
        }
    }

    // MARK: Piko speaks

    private var pikoBubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pikoLine)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .tracking(-0.6)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            if model.phase == .capturing {
                VoiceWave(activity: model.activity, tint: theme.accent)
                    .frame(height: 44)
            } else {
                Text(pikoHint)
                    .font(.body)
                    .foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.needsSpeechDownload {
                Button("Download the speech pack") {
                    Task { await model.downloadSpeechAssets() }
                }
                .buttonStyle(.pikoQuiet)
                .disabled(model.isBusy)
                .padding(.top, 4)
            }
        }
        .bubble(from: .piko, fill: theme.card)
        .accessibilityElement(children: .combine)
    }

    private var pikoLine: String {
        switch model.phase {
        case .capturing: "I’m listening."
        case .tidying: "Thinking it over…"
        case .armed, .idle: "What’s on your mind?"
        }
    }

    private var pikoHint: String {
        switch model.phase {
        case .tidying: "Sorting what you said into the right place."
        default: "A reminder, an idea, how today felt — or ask “what did I say about…?”"
        }
    }

    // MARK: You speak

    private var yourBubble: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.canEdit ? "You said" : "Hearing you…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.ink2)

            TextEditor(text: $model.text)
                .font(.title3)
                .foregroundStyle(theme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72, maxHeight: 180)
                .focused($isEditing)
                .disabled(!model.canEdit)
                .accessibilityLabel("Dictation text")
                .accessibilityIdentifier("home.transcript")

            if model.canEdit && model.hasText {
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = model.text
                        copiedText = model.text
                    } label: {
                        Label(copiedText == model.text ? "Copied" : "Copy",
                              systemImage: copiedText == model.text ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.pikoQuiet)
                    ShareLink(item: model.text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.pikoQuiet)
                    Spacer(minLength: 0)
                    Button {
                        model.text = ""
                        isEditing = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.ink2)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Clear text from Home")
                }
            }
        }
        .bubble(from: .you, fill: theme.wash)
    }

    // MARK: Piko answers

    @ViewBuilder
    private func assistantBubble(_ state: AssistantState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            PikoFace(phase: state == .thinking ? .tidying : .armed, skin: model.skin)
                .frame(width: 34, height: 36)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 14) {
                switch state {
                case .thinking:
                    HStack(spacing: 10) {
                        Text("Sorting that out…").font(.headline).foregroundStyle(theme.ink)
                        ProgressView().tint(theme.accent)
                    }
                case .proposed(let plan, let prompt, let canConfirm):
                    Text(prompt)
                        .font(.headline)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(plan) { call in planRow(call) }
                    }
                    HStack(spacing: 10) {
                        if canConfirm {
                            Button { Task { await model.runPlan() } } label: {
                                Text("Do it").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.piko)
                            .accessibilityIdentifier("assistant.save")
                        } else {
                            Label("Just say it", systemImage: "waveform")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(theme.ink2)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        Button("Not now") { model.dismissAssistant() }
                            .buttonStyle(.pikoQuiet)
                    }
                case .answer(let answer):
                    Text(answer)
                        .font(.body)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Thanks, Piko") { model.dismissAssistant() }
                        .buttonStyle(.pikoQuiet)
                case .done(let outcomes):
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(outcomes, id: \.call.id) { outcome in
                            switch outcome.status {
                            case .done(let message):
                                Label(message, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(theme.ink)
                                    .labelIconTint(theme.accent)
                            case .skipped(let reason), .failed(let reason):
                                Label("\(outcome.call.text): \(reason)", systemImage: "exclamationmark.circle")
                                    .foregroundStyle(theme.ink2)
                            }
                        }
                    }
                    .font(.body)
                    Button("All good") { model.dismissAssistant() }
                        .buttonStyle(.pikoQuiet)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bubble(from: .piko, fill: theme.card)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.card")
    }

    private func planRow(_ call: ToolCall) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: AssistantTools.symbol(for: call.tool))
                .foregroundStyle(theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.text).font(.body).foregroundStyle(theme.ink)
                if let when = call.when {
                    Text(when.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(theme.ink2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(call.tool): \(call.text)")
    }

    private func errorBubble(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.body)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if model.needsMicrophoneSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.piko)
                }
                Button("OK") { model.error = nil }
                    .buttonStyle(.pikoQuiet)
            }
        }
        .bubble(from: .piko, fill: theme.blush.opacity(0.18))
    }

    // MARK: The one thing to do

    private var talkBar: some View {
        VStack(spacing: 10) {
            Button {
                isEditing = false
                Task { await model.toggleCapture() }
            } label: {
                HStack(spacing: 12) {
                    if model.isBusy || model.phase == .tidying {
                        ProgressView().tint(theme.onPiko)
                    } else {
                        Image(systemName: model.phase == .capturing ? "stop.fill" : "mic.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Text(talkTitle)
                }
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.piko)
            .disabled(model.isBusy || model.phase == .tidying)
            .accessibilityIdentifier("home.dictate")
            .sensoryFeedback(.impact(weight: .medium), trigger: model.phase == .capturing)

            Label("Heard and kept on this iPhone", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(theme.ink2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(theme.ground)
    }

    private var talkTitle: String {
        switch model.phase {
        case .capturing: "I’m done"
        case .tidying: "Thinking…"
        case .armed, .idle: "Talk to Piko"
        }
    }
}

/// Who is speaking decides which top corner of a bubble is pinched toward them.
enum BubbleSide { case piko, you }

private struct Bubble: ViewModifier {
    let from: BubbleSide
    let fill: Color

    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: UnevenRoundedRectangle(
                topLeadingRadius: from == .piko ? 6 : 26,
                bottomLeadingRadius: 26,
                bottomTrailingRadius: 26,
                topTrailingRadius: from == .you ? 6 : 26,
                style: .continuous))
            .padding(from == .you ? .leading : .trailing, 28)
    }
}

extension View {
    func bubble(from speaker: BubbleSide, fill: Color) -> some View {
        modifier(Bubble(from: speaker, fill: fill))
    }

    /// Tints only a Label's icon, keeping its title in the surrounding ink.
    func labelIconTint(_ color: Color) -> some View {
        labelStyle(TintedIconLabelStyle(tint: color))
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
