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
    @Published private(set) var companionPreferences = PikoCompanionPreferences()
    @Published private(set) var companionPreferenceError: String?
    @Published private(set) var greeting: String?
    @Published private(set) var isCompanionActive = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var isExecutingTools = false
    @Published private(set) var isCelebrating = false
    @Published private(set) var spokenRepliesEnabled = true
    private var companionStore: PikoCompanionStore?
    private var hasOfferedGreeting = false
    private var usesVoiceFollowUp = true
    private var responseID = UUID()
    private var responseTask: Task<Void, Never>?
    private var captureStartupTask: Task<Void, Never>?
    private var captureStartupID = UUID()
    private var celebrationTask: Task<Void, Never>?
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
        spokenRepliesEnabled = speaker.isEnabled
        do {
            let store = try PikoCompanionStore()
            companionStore = store
            companionPreferences = store.preferences
        } catch {
            companionPreferences.quietMode = true
            companionPreferenceError = "Piko could not load companion preferences. Learning is paused until you reset them."
            notice = companionPreferenceError
            print("Piko companion preferences: load failed: \(error)")
        }
        speaker.onSpeakingChange = { [weak self] speaking in self?.isSpeaking = speaking }
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
            guard let self else { return }
            self.captureStartupTask?.cancel()
            if self.isExecutingTools {
                self.notice = "The approved action is finishing. Its result will stay visible."
                self.speaker.stop()
                return
            }
            self.responseID = UUID()
            self.responseTask?.cancel()
            self.speaker.stop()
            self.pauseWatch?.cancel()
            self.conversation = Conversation()
            self.assistant = nil
        }
        refresh()
        weeklyDumps = app.dumpLog.countLastSevenDays()
    }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canEdit: Bool { !isBusy && !isExecutingTools && assistant != .thinking && phase != .capturing && phase != .tidying }
    var sessionActive: Bool { phase != .idle }
    var canSubmitRequest: Bool {
        !isBusy && !isExecutingTools && phase != .capturing && phase != .tidying && assistant != .thinking
    }

    var petActivity: PikoPetActivity {
        if phase == .capturing { return .listening }
        if isSpeaking { return .speaking }
        if phase == .tidying || assistant == .thinking { return .thinking }
        return isCelebrating ? .happy : .idle
    }

    func setCompanionActive(_ active: Bool) {
        guard active != isCompanionActive else { return }
        isCompanionActive = active
        if !active {
            captureStartupTask?.cancel()
            greeting = nil
            speaker.stop()
            celebrationTask?.cancel()
            isCelebrating = false
        } else if !hasOfferedGreeting {
            hasOfferedGreeting = true
            if assistant == nil, companionPreferences.shouldPresentRoutine(.greeting) {
                greeting = companionPreferences.personality.greeting
            }
        }
    }

    func patPiko() {
        let offeredGreeting = greeting != nil
        if offeredGreeting {
            recordAttention(.engaged, for: .greeting)
            greeting = nil
        }
        guard offeredGreeting, isCompanionActive, !companionPreferences.quietMode,
              canSubmitRequest, assistant == nil else { return }
        let requestID = responseID
        Task { [weak self] in
            guard let self, self.responseID == requestID, self.isCompanionActive,
                  !self.companionPreferences.quietMode, self.canSubmitRequest,
                  self.assistant == nil else { return }
            await self.speaker.say(self.companionPreferences.personality.greeting,
                                   personality: self.companionPreferences.personality)
        }
    }

    func dismissGreeting() {
        guard greeting != nil else { return }
        recordAttention(.dismissed, for: .greeting)
        greeting = nil
    }

    func setPersonality(_ personality: PikoPersonality) {
        var preferences = companionPreferences
        preferences.personality = personality
        saveCompanionPreferences(preferences)
        if greeting != nil { greeting = companionPreferences.personality.greeting }
    }

    func setQuietMode(_ quiet: Bool) {
        var preferences = companionPreferences
        preferences.quietMode = quiet
        saveCompanionPreferences(preferences)
        if companionPreferences.quietMode {
            speaker.stop()
            greeting = nil
        }
    }

    func setSpokenReplies(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Speaker.enabledKey)
        spokenRepliesEnabled = enabled
        if !enabled { speaker.stop() }
    }

    func resetCompanionLearning() {
        do {
            if companionStore == nil {
                UserDefaults.standard.removeObject(forKey: PikoCompanionStore.preferencesKey)
                companionStore = try PikoCompanionStore()
            }
            var preferences = companionPreferences
            preferences.resetLearning()
            guard let companionStore else { throw PikoCompanionStorageError.invalidStoredValue }
            try companionStore.save(preferences)
            companionPreferences = preferences
            companionPreferenceError = nil
            notice = "Piko's learned attention patterns have been reset."
        } catch {
            companionPreferenceError = "Piko could not reset companion learning. Your history is unchanged."
            print("Piko companion preferences: reset failed: \(error)")
        }
    }

    private func saveCompanionPreferences(_ preferences: PikoCompanionPreferences) {
        do {
            guard let companionStore else { throw PikoCompanionStorageError.invalidStoredValue }
            try companionStore.save(preferences)
            companionPreferences = preferences
            companionPreferenceError = nil
        } catch {
            companionPreferenceError = "Piko could not save companion preferences. Reset them in Settings to resume learning."
            notice = companionPreferenceError
            print("Piko companion preferences: save failed: \(error)")
        }
    }

    private func recordAttention(_ feedback: PikoAttentionFeedback, for kind: PikoAttentionKind) {
        var preferences = companionPreferences
        preferences.record(feedback, for: kind)
        saveCompanionPreferences(preferences)
    }

    private func speak(_ text: String) async {
        guard usesVoiceFollowUp, isCompanionActive, !companionPreferences.quietMode else { return }
        await speaker.say(text, personality: companionPreferences.personality)
    }

    func submitTypedRequest(_ request: String) async -> Bool {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            notice = "Tell Piko what you would like help with."
            return false
        }
        guard canSubmitRequest else {
            notice = "Finish or stop the current request before starting another."
            return false
        }
        error = nil
        notice = nil
        if greeting != nil { recordAttention(.engaged, for: .greeting) }
        greeting = nil
        speaker.stop()
        let typedRequestID = UUID()
        responseID = typedRequestID
        captureStartupTask?.cancel()
        responseTask?.cancel()
        responseTask = nil
        assistant = .thinking
        defer { refresh() }
        let route = await app.brain.route(request)
        guard responseID == typedRequestID else { return false }
        let result = CaptureResult(raw: request, shipped: request, route: route)
        await app.memory.record(result)
        guard responseID == typedRequestID else { return false }
        text = request
        await respond(to: result, voiceFollowUp: false)
        return true
    }

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
        guard !isBusy, !isExecutingTools, assistant != .thinking, !app.captureCoordinator.isTidying else { return }
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
        guard !isBusy, !isExecutingTools, assistant != .thinking,
              app.session.currentPhase != .capturing, !app.captureCoordinator.isTidying else { return }
        if UIApplication.shared.applicationState == .active { setCompanionActive(true) }
        await listen(followUp: conversation.isWaiting)
    }

    /// Starts listening and ends the turn on its own when the speaker pauses — no "I'm done" tap.
    private func listen(followUp: Bool, requestID: UUID? = nil) async {
        guard !Task.isCancelled, isCompanionActive,
              requestID.map({ $0 == responseID }) ?? true else { return }
        let owner = requestID ?? UUID()
        if requestID == nil {
            responseID = owner
            responseTask?.cancel()
            responseTask = nil
        }
        let captureID = UUID()
        captureStartupID = captureID
        captureStartupTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performListen(followUp: followUp, requestID: owner, captureID: captureID)
        }
        captureStartupTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if captureStartupID == captureID { captureStartupTask = nil }
    }

    private func checkCaptureStartup(requestID: UUID, captureID: UUID) throws {
        try Task.checkCancellation()
        guard responseID == requestID, captureStartupID == captureID, isCompanionActive else {
            throw CancellationError()
        }
    }

    private func performListen(followUp: Bool, requestID: UUID, captureID: UUID) async {
        let wasIdle = app.session.currentPhase == .idle
        do {
            try checkCaptureStartup(requestID: requestID, captureID: captureID)
            if greeting != nil { recordAttention(.engaged, for: .greeting); greeting = nil }
            speaker.stop()
            error = nil
            notice = nil
            try await prepareSession()
            try checkCaptureStartup(requestID: requestID, captureID: captureID)
            text = ""
            discardNextResult = false
            await app.showLiveActivity()
            try checkCaptureStartup(requestID: requestID, captureID: captureID)
            try await app.captureCoordinator.startCapture()
            try checkCaptureStartup(requestID: requestID, captureID: captureID)
            isFollowUp = followUp
            lastDraftChange = .now
            watchForPause()
        } catch {
            guard captureStartupID == captureID else { return }
            if error is CancellationError || Task.isCancelled || responseID != requestID || !isCompanionActive {
                if app.session.currentPhase == .capturing {
                    discardNextResult = true
                    await app.captureCoordinator.cancelCapture()
                }
                guard captureStartupID == captureID else { return }
                if wasIdle, app.session.currentPhase == .armed { await app.session.disarm() }
                guard captureStartupID == captureID, responseID == requestID else { return }
                await app.liveActivityController.end()
                return
            }
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
    func respond(to result: CaptureResult, voiceFollowUp: Bool = true) async {
        pauseWatch?.cancel()
        if discardNextResult, voiceFollowUp {
            discardNextResult = false
            return
        }
        guard !isExecutingTools else {
            notice = "Let the approved action finish before starting another request."
            return
        }
        let requestID = UUID()
        responseID = requestID
        captureStartupTask?.cancel()
        responseTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performResponse(to: result, voiceFollowUp: voiceFollowUp, requestID: requestID)
        }
        responseTask = task
        await task.value
        if responseID == requestID { responseTask = nil }
    }

    private func performResponse(to result: CaptureResult, voiceFollowUp: Bool, requestID: UUID) async {
        guard responseID == requestID, !Task.isCancelled else { return }
        usesVoiceFollowUp = voiceFollowUp
        celebrationTask?.cancel()
        isCelebrating = false
        let app = self.app
        if conversation.isWaiting,
           let reply = await hear(result.shipped, requestID: requestID) {
            guard responseID == requestID else { return }
            await handle(reply, requestID: requestID)
            return
        }
        guard responseID == requestID, !Task.isCancelled else { return }
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
                guard responseID == requestID, !Task.isCancelled else { return }
                let answer = try await app.organizer.answer(result.shipped, from: Array(history.prefix(8)))
                guard responseID == requestID else { return }
                assistant = .answer(answer)
                await speak(answer)
                guard responseID == requestID else { return }
                await finishTurn()
            } else {
                let plan = try await app.planner.plan(result.shipped, tools: app.harness.actionDescriptors, now: .now)
                guard responseID == requestID else { return }
                guard !plan.isEmpty else {
                    assistant = nil
                    notice = "I couldn’t find anything to do there."
                    await finishTurn()
                    return
                }
                var talk = conversation
                let reply = await talk.begin(plan, context: calendar, now: .now)
                guard responseID == requestID else { return }
                conversation = talk
                await handle(reply, requestID: requestID)
            }
        } catch {
            guard responseID == requestID else { return }
            assistant = nil
            present(error)
            await finishTurn()
        }
    }

    /// Conversation is a value type; copy, update across the suspension, then store back.
    private func hear(_ text: String, requestID: UUID) async -> Conversation.Reply? {
        guard responseID == requestID, !Task.isCancelled else { return nil }
        var talk = conversation
        let reply = await talk.hear(text, context: calendar, now: .now)
        guard responseID == requestID, !Task.isCancelled else { return nil }
        conversation = talk
        return reply
    }

    private func handle(_ reply: Conversation.Reply, requestID: UUID) async {
        guard responseID == requestID else { return }
        switch reply {
        case .ask(let prompt), .confirm(let prompt):
            let canConfirm = conversation.waiting == .confirm
            assistant = .proposed(conversation.plan, prompt: prompt, canConfirm: canConfirm)
            await speak(prompt)
            // The user may have tapped Do it or Discard while Piko was speaking.
            guard responseID == requestID, case .proposed = assistant, conversation.isWaiting else { return }
            if usesVoiceFollowUp, isCompanionActive {
                await listen(followUp: true, requestID: requestID)
            } else {
                await finishTurn()
            }
        case .run(let ack):
            await execute(conversation.plan, ack: ack, requestID: requestID)
        case .cancelled(let message):
            assistant = nil
            notice = message
            await speak(message)
            guard responseID == requestID else { return }
            await finishTurn()
        }
    }

    private func execute(_ plan: [ToolCall], ack: String, requestID: UUID) async {
        guard responseID == requestID else { return }
        isExecutingTools = true
        defer { isExecutingTools = false }
        assistant = .thinking
        let outcomes = await app.harness.run(plan, approve: { _ in true })
        app.dumpLog.record()
        weeklyDumps = app.dumpLog.countLastSevenDays()
        conversation = Conversation()
        assistant = .done(outcomes)
        let allDone = outcomes.allSatisfy { if case .done = $0.status { true } else { false } }
        if allDone, companionPreferences.shouldPresentRoutine(.completion), isCompanionActive {
            isCelebrating = true
            celebrationTask?.cancel()
            celebrationTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(1600)) } catch { return }
                self?.isCelebrating = false
            }
        }
        if !allDone || companionPreferences.shouldPresentRoutine(.completion) {
            await speak(allDone ? (ack == "Saved." ? "Saved." : "Done.") : "Some of that didn’t work. Have a look.")
        }
        guard responseID == requestID else { return }
        await finishTurn()
    }

    /// "Do it" on the card — the same as saying yes.
    func runPlan() async {
        guard !isBusy, !isExecutingTools else {
            notice = "The current action is still finishing."
            return
        }
        isBusy = true
        defer { isBusy = false }
        let requestID = UUID()
        responseID = requestID
        captureStartupTask?.cancel()
        responseTask?.cancel()
        responseTask = nil
        await stopListeningQuietly()
        if let reply = await hear("yes", requestID: requestID) {
            await handle(reply, requestID: requestID)
        }
    }

    func dismissAssistant(engaged: Bool = false) {
        guard !isExecutingTools else {
            notice = "The approved action is finishing. Its result will stay visible."
            return
        }
        if let assistant {
            switch assistant {
            case .answer, .done: recordAttention(engaged ? .engaged : .dismissed, for: .completion)
            default: break
            }
        }
        responseID = UUID()
        captureStartupTask?.cancel()
        responseTask?.cancel()
        celebrationTask?.cancel()
        isCelebrating = false
        speaker.stop()
        conversation = Conversation()
        assistant = nil
        let cleanupID = responseID
        let captureID = captureStartupID
        Task {
            guard self.responseID == cleanupID, self.captureStartupID == captureID else { return }
            await stopListeningQuietly()
            guard self.responseID == cleanupID, self.captureStartupID == captureID else { return }
            await finishTurn()
        }
    }

    private func stopListeningQuietly() async {
        pauseWatch?.cancel()
        speaker.stop()
        guard app.session.currentPhase == .capturing else { return }
        discardNextResult = true
        await app.captureCoordinator.cancelCapture()
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

/// The work leads; a small Piko stays nearby without taking over the screen.
struct ArmView: View {
    @ObservedObject var model: HomeViewModel
    @State private var showSetup = false
    @State private var copiedText: String?
    @State private var typedRequest = ""
    @State private var isPetVisible = false
    @FocusState private var isEditing: Bool
    @FocusState private var isTypingRequest: Bool
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
                        Text("Your space")
                            .font(.subheadline)
                            .foregroundStyle(theme.ink2)
                        Spacer()
                        Button { model.setQuietMode(!model.companionPreferences.quietMode) } label: {
                            Image(systemName: model.companionPreferences.quietMode ? "moon.fill" : "moon")
                                .font(.title3)
                                .foregroundStyle(theme.ink2)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(model.companionPreferences.quietMode ? "Turn Quiet mode off" : "Turn Quiet mode on")
                        .accessibilityIdentifier("companion.quiet")
                        Button { showSetup = true } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.title3)
                                .foregroundStyle(theme.ink2)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("How to use Piko")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("A little less\non your mind.")
                            .font(.largeTitle.weight(.semibold))
                            .tracking(-0.8)
                            .foregroundStyle(theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text("Piko is here. No rush.")
                            .font(.subheadline)
                            .foregroundStyle(theme.ink2)
                    }
                    .padding(.vertical, 12)
                    if let greeting = model.greeting {
                        HStack(alignment: .top, spacing: 12) {
                            Text(greeting)
                                .font(.subheadline)
                                .foregroundStyle(theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { model.dismissGreeting() } label: {
                                Image(systemName: "xmark")
                                    .foregroundStyle(theme.ink2)
                                    .frame(width: 32, height: 32)
                            }
                            .accessibilityLabel("Dismiss Piko's greeting")
                            .accessibilityIdentifier("companion.dismissGreeting")
                        }
                        .padding(16)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityIdentifier("companion.greeting")
                    }
                    if model.phase == .capturing || model.phase == .tidying { pikoBubble }
                    if let assistant = model.assistant { assistantBubble(assistant) }
                    if model.hasText || model.phase == .capturing || model.phase == .tidying {
                        yourBubble
                    }
                    if let error = model.error { errorBubble(error) }
                    if let notice = model.notice {
                        Text(notice)
                            .font(.subheadline)
                            .foregroundStyle(theme.ink2)
                            .padding(.horizontal, 6)
                    }
                    HStack(alignment: .bottom, spacing: 6) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("piko.")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(theme.ink)
                            Text(model.companionPreferences.quietMode ? "Quiet, but still here." : "Here when you need me.")
                                .font(.subheadline)
                                .foregroundStyle(theme.ink2)
                        }
                        .padding(.bottom, 30)
                        Spacer(minLength: 0)
                        if model.isCompanionActive {
                            CompanionPet(model: model, room: theme.ground,
                                         isActive: isPetVisible && !showSetup)
                                .frame(width: 172, height: 215)
                                .onScrollVisibilityChange(threshold: 0.1) { isPetVisible = $0 }
                                .accessibilityIdentifier("companion.pet")
                        } else {
                            Color.clear.frame(width: 172, height: 215)
                        }
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
                    Button("Done") { isEditing = false; isTypingRequest = false }
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
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Piko").font(.caption.weight(.semibold)).foregroundStyle(theme.ink2)
                    Spacer()
                    Button { model.dismissAssistant() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(theme.ink2)
                            .frame(width: 32, height: 32)
                    }
                    .disabled(model.isExecutingTools)
                    .accessibilityLabel(state == .thinking ? "Cancel planning" : "Dismiss Piko's response")
                    .accessibilityIdentifier("assistant.dismiss")
                }
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
                            .disabled(model.isBusy || model.isExecutingTools)
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
                    Button("Thanks, Piko") { model.dismissAssistant(engaged: true) }
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
                    Button("All good") { model.dismissAssistant(engaged: true) }
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
            HStack(spacing: 12) {
                TextField("Ask Piko...", text: $typedRequest)
                    .font(.body)
                    .foregroundStyle(theme.ink)
                    .submitLabel(.send)
                    .focused($isTypingRequest)
                    .disabled(!model.canSubmitRequest)
                    .onSubmit { sendTypedRequest() }
                    .accessibilityIdentifier("home.request")
                Button { sendTypedRequest() } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .foregroundStyle(theme.onPiko)
                        .frame(width: 40, height: 40)
                        .background(theme.piko, in: Circle())
                }
                .disabled(!model.canSubmitRequest || typedRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send request to Piko")
                .accessibilityIdentifier("home.send")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 22))
            Button {
                isEditing = false
                isTypingRequest = false
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
            .disabled(model.isBusy || model.isExecutingTools || model.assistant == .thinking || model.phase == .tidying)
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

    private func sendTypedRequest() {
        let request = typedRequest
        isTypingRequest = false
        Task {
            let accepted = await model.submitTypedRequest(request)
            if accepted, typedRequest == request { typedRequest = "" }
        }
    }

    private var talkTitle: String {
        switch model.phase {
        case .capturing: "I’m done"
        case .tidying: "Thinking…"
        case .armed, .idle: "Talk to Piko"
        }
    }
}

private struct CompanionPet: View {
    @ObservedObject var model: HomeViewModel
    @ObservedObject private var activity: VoiceActivityModel
    let room: Color
    let isActive: Bool

    init(model: HomeViewModel, room: Color, isActive: Bool) {
        self.model = model
        self.room = room
        self.isActive = isActive
        _activity = ObservedObject(wrappedValue: model.activity)
    }

    var body: some View {
        PikoPetView(activity: model.petActivity, loudness: activity.level(),
                    isActive: model.isCompanionActive && isActive, room: room, onPat: model.patPiko)
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
