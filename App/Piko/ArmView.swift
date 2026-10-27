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

struct ArmView: View {
    @ObservedObject var model: HomeViewModel
    @State private var showSetup = false
    @State private var copiedText: String?
    @FocusState private var isEditing: Bool

    private let ink = Color(red: 0.08, green: 0.12, blue: 0.22)
    private let accent = Color(red: 0.24, green: 0.33, blue: 0.92)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heading
                    #if DEBUG
                    if UserDefaults.standard.string(forKey: "PikoBenchmarkCaptureFixture") != nil {
                        Text("Developer fixture replay. Microphone input is discarded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    #endif
                    recordingCard
                    if let assistant = model.assistant { assistantCard(assistant) }
                    if let error = model.error { errorCard(error) }
                    if model.needsSpeechDownload {
                        Button("Download speech language pack") {
                            Task { await model.downloadSpeechAssets() }
                        }
                        .disabled(model.isBusy)
                    }
                    if let notice = model.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.hasText || model.phase == .capturing || model.phase == .tidying {
                        transcriptCard
                    }
                    Label("On-device transcription. Your words stay yours.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("piko")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSetup = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Keyboard setup")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditing = false }
                }
            }
            .sheet(isPresented: $showSetup) { OnboardingView(isPresented: $showSetup) }
            .onChange(of: model.text) { _, _ in copiedText = nil }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hi, I’m Piko.")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .tracking(-1)
                .fixedSize(horizontal: false, vertical: true)
            Text("Talk it out. I’ll sort it out, privately.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(recordingStatus, systemImage: model.phase == .capturing ? "record.circle" : "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("PIKO")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(model.phase == .capturing ? "Go ahead.\nI’m listening." : "What’s on\nyour mind?")
                    .font(.system(size: 28, weight: .medium))
                    .tracking(-0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)

                if model.phase == .capturing {
                    VoiceWave(activity: model.activity, tint: .cyan)
                        .frame(height: 48)
                } else {
                    Text(model.phase == .tidying ? "Piko is thinking…" : "Reminders, ideas, feelings, or “what did I say about…?”")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 8)
                }
            }
            .frame(minHeight: 110, alignment: .topLeading)

            Button {
                isEditing = false
                Task { await model.toggleCapture() }
            } label: {
                HStack(spacing: 10) {
                    if model.isBusy || model.phase == .tidying {
                        ProgressView().tint(ink)
                    } else {
                        Image(systemName: model.phase == .capturing ? "stop.fill" : "mic.fill")
                    }
                    Text(model.phase == .capturing ? "Listening… tap to finish" : model.phase == .tidying ? "Thinking…" : "Talk to Piko")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.subheadline.weight(.medium))
                }
                .foregroundStyle(ink)
                .padding(.horizontal, 18)
                .frame(minHeight: 54)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.phase == .tidying)
            .accessibilityIdentifier("home.dictate")
        }
        .padding(24)
        .background(
            LinearGradient(colors: [ink, Color(red: 0.15, green: 0.2, blue: 0.4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28))
    }

    private var recordingStatus: String {
        switch model.phase {
        case .capturing: "Listening"
        case .tidying: "Thinking"
        case .armed, .idle: "Ready when you are"
        }
    }

    @ViewBuilder
    private func assistantCard(_ state: AssistantState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch state {
            case .thinking:
                HStack(spacing: 12) {
                    PikoFace(phase: .tidying, skin: model.skin).frame(width: 40, height: 44)
                    Text("Sorting that out…").font(.headline)
                    Spacer()
                    ProgressView()
                }
            case .proposed(let plan, let prompt, let canConfirm):
                Text(prompt).font(.headline).fixedSize(horizontal: false, vertical: true)
                ForEach(plan) { call in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: AssistantTools.symbol(for: call.tool))
                            .foregroundStyle(accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(call.text).font(.subheadline)
                            if let when = call.when {
                                Text(when.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(call.tool): \(call.text)")
                }
                HStack(spacing: 12) {
                    if canConfirm {
                        Button { Task { await model.runPlan() } } label: {
                            Text("Do it").font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(accent, in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(.white)
                        }
                        .accessibilityIdentifier("assistant.save")
                    } else {
                        Label("Just say it", systemImage: "waveform")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    Button("Discard") { model.dismissAssistant() }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                }
            case .answer(let answer):
                HStack(alignment: .top, spacing: 12) {
                    PikoFace(phase: .armed, skin: model.skin).frame(width: 40, height: 44)
                    Text(answer).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                Button("Done") { model.dismissAssistant() }.font(.subheadline.weight(.medium))
            case .done(let outcomes):
                ForEach(outcomes, id: \.call.id) { outcome in
                    switch outcome.status {
                    case .done(let message):
                        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                    case .skipped(let reason), .failed(let reason):
                        Label("\(outcome.call.text): \(reason)", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                Button("Done") { model.dismissAssistant() }.font(.subheadline.weight(.medium))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.card")
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.canEdit ? "Your words" : "Live transcript")
                    .font(.headline)
                Spacer()
                if model.canEdit {
                    Button {
                        model.text = ""
                        isEditing = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("Clear text from Home")
                }
            }

            TextEditor(text: $model.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110, maxHeight: 180)
                .focused($isEditing)
                .disabled(!model.canEdit)
                .accessibilityLabel("Dictation text")
                .accessibilityIdentifier("home.transcript")

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = model.text
                    copiedText = model.text
                } label: {
                    Label(copiedText == model.text ? "Copied" : "Copy text",
                          systemImage: copiedText == model.text ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                ShareLink(item: model.text) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 44, height: 44)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Share text")
            }
            .disabled(!model.canEdit || !model.hasText)
            .buttonStyle(.plain)
            .foregroundStyle(accent)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.subheadline)
            if model.needsMicrophoneSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.subheadline.weight(.semibold))
            }
            Button("Dismiss") { model.error = nil }.font(.caption)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
