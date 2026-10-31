import AVFAudio
import Combine
import SwiftUI
import UIKit
import PikoKit
import PikoBrain
import PikoUI

/// Owned by one explicit voice turn, not by the changing ID of each capture/response.
/// Only actual replies and outcomes are retained, and never more than two exchanges.
struct VoiceSession {
    private(set) var owner: UUID?
    private(set) var recent: [AssistantExchange] = []

    @discardableResult
    mutating func begin() -> UUID {
        end()
        let id = UUID()
        owner = id
        return id
    }

    mutating func append(user: String, reply: String, owner id: UUID) {
        guard owner == id, !reply.isEmpty else { return }
        func bounded(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.prefix(240)))
        }
        recent.append(.init(user: bounded(user), reply: bounded(reply)))
        if recent.count > 2 { recent.removeFirst(recent.count - 2) }
    }

    mutating func appendOutcome(user: String, outcomes: [ToolOutcome], owner id: UUID) {
        let summary = outcomes.map { outcome -> String in
            switch outcome.status {
            case .done(let text): return text
            case .skipped(let reason), .failed(let reason): return "\(outcome.call.text): \(reason)"
            }
        }.joined(separator: "; ")
        append(user: user, reply: summary, owner: id)
    }

    mutating func end() {
        owner = nil
        recent.removeAll()
    }

    /// A confirmed fact mutation invalidates prior personal evidence without ending the voice turn.
    mutating func clearEvidence() {
        recent.removeAll()
    }
}

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
    @Published private(set) var engineCaption: String?
    private var companionStore: PikoCompanionStore?
    private var hasOfferedGreeting = false
    private var usesVoiceFollowUp = true
    private var responseID = UUID()
    private var responseTask: Task<Void, Never>?
    private var captureStartupTask: Task<Void, Never>?
    private var captureStartupID = UUID()
    private var celebrationTask: Task<Void, Never>?
    private var proposalCard: ProposalCard?
    private var conversation = Conversation()
    private var followUpPolicy = FollowUpPolicy()
    var voiceSession = VoiceSession()
    #if DEBUG
    /// Isolated app tests exercise follow-up decisions without activating the microphone.
    var suppressAutomaticCaptureForTests = false
    var celebrationDuration: Duration = .milliseconds(1600)
    #endif
    private struct Clarification {
        let original: String
        let question: String
        let session: UUID?
    }
    private var clarification: Clarification?
    private var actionRequest: String?
    private var actionSession: UUID?
    private let speaker = Speaker()
    private let calendar = EventKitCalendar()
    private var pauseWatch: Task<Void, Never>?
    private var lastDraftChange = Date()
    private var isFollowUp = false
    #if DEBUG
    func simulateFollowUpForTests() { isFollowUp = true }
    #endif
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
            let owner = self.responseID
            Task { await self.finishTurn(requestID: owner) }
        }
        app.onPublishFailure = { [weak self] message in self?.notice = message }
        Task { [weak self] in
            if let message = await app.publishingMemory.publishError { self?.notice = message }
        }
        app.onTalkRequested = { [weak self] in await self?.talk() }
        app.onStopRequested = { [weak self] in
            guard let self else { return }
            self.followUpPolicy.endVoiceTurn()
            self.usesVoiceFollowUp = false
            self.voiceSession.end()
            self.clarification = nil
            self.proposalCard = nil
            self.actionSession = nil
            self.captureStartupTask?.cancel()
            self.responseID = UUID()
            self.responseTask?.cancel()
            self.responseTask = nil
            if self.isExecutingTools {
                self.notice = "The approved action may finish after Stop. Check its destination before retrying."
                self.assistant = nil
                self.engineCaption = nil
                self.speaker.stop()
                return
            }
            self.speaker.stop()
            self.pauseWatch?.cancel()
            self.conversation = Conversation()
            self.assistant = nil
            self.engineCaption = nil
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
        guard active != isCompanionActive else {
            if !active, let proposalCard { dismissProposalCard(proposalCard.id) }
            return
        }
        isCompanionActive = active
        if !active {
            followUpPolicy.endVoiceTurn()
            usesVoiceFollowUp = false
            voiceSession.end()
            clarification = nil
            proposalCard = nil
            if case .contextProposals = assistant { assistant = nil }
            responseID = UUID()
            responseTask?.cancel()
            responseTask = nil
            if isExecutingTools {
                assistant = nil
                engineCaption = nil
                notice = "The approved action may finish while Piko is inactive. Check its destination before retrying."
            } else {
                conversation = Conversation()
                actionRequest = nil
                actionSession = nil
                if assistant == .thinking { assistant = nil; engineCaption = nil }
                if case .proposed = assistant { assistant = nil; engineCaption = nil }
                if case .clarifying = assistant { assistant = nil; engineCaption = nil }
            }
            cancelAutomaticCapture()
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

    private func cancelAutomaticCapture() {
        captureStartupTask?.cancel()
        guard isFollowUp, app.session.currentPhase == .capturing else { return }
        let owner = responseID
        let captureID = captureStartupID
        Task { [weak self] in
            guard let self, self.responseID == owner, self.captureStartupID == captureID else { return }
            await self.stopListeningQuietly()
            guard self.responseID == owner, self.captureStartupID == captureID else { return }
            await self.finishTurn(requestID: owner)
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
        if quiet {
            followUpPolicy.endVoiceTurn()
            usesVoiceFollowUp = false
            voiceSession.end()
            clarification = nil
            responseID = UUID()
            responseTask?.cancel()
            responseTask = nil
            if isExecutingTools {
                assistant = nil
                engineCaption = nil
                notice = "The approved action may finish while Piko is inactive. Check its destination before retrying."
            } else {
                conversation = Conversation()
                actionRequest = nil
                actionSession = nil
                if assistant == .thinking { assistant = nil; engineCaption = nil }
                if case .proposed = assistant { assistant = nil; engineCaption = nil }
                if case .clarifying = assistant { assistant = nil; engineCaption = nil }
            }
            cancelAutomaticCapture()
            speaker.stop()
            greeting = nil
            celebrationTask?.cancel()
            isCelebrating = false
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

    /// Also used when Control Center delivers a result before Home initiated capture.
    func beginVoiceTurn() {
        followUpPolicy.beginVoiceTurn()
        usesVoiceFollowUp = true
        voiceSession.begin()
        proposalCard = nil
        if case .contextProposals = assistant { assistant = nil }
        clarification = nil
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
        if let card = proposalCard {
            // Typed input cannot confirm a card that belongs to a voice session.
            if card.session == nil && Self.isCardYes(request) {
                await saveProposalCard(card.id)
                return true
            }
            dismissProposalCard(card.id)
        }
        error = nil
        notice = nil
        if greeting != nil { recordAttention(.engaged, for: .greeting) }
        greeting = nil
        speaker.stop()
        let typedRequestID = UUID()
        responseID = typedRequestID
        followUpPolicy.endVoiceTurn()
        usesVoiceFollowUp = false
        voiceSession.end()
        if clarification?.session != nil { clarification = nil }
        actionSession = nil
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
        await listen(followUp: conversation.isWaiting || proposalCard != nil)
    }

    /// Talk to Piko from Control Center, the Action Button or Siri.
    func talk() async {
        guard !isBusy, !isExecutingTools, assistant != .thinking,
              app.session.currentPhase != .capturing, !app.captureCoordinator.isTidying else { return }
        if UIApplication.shared.applicationState == .active { setCompanionActive(true) }
        await listen(followUp: conversation.isWaiting || proposalCard != nil)
    }

    /// Starts listening and ends the turn on its own when the speaker pauses — no "I'm done" tap.
    private func listen(followUp: Bool, requestID: UUID? = nil) async {
        guard !Task.isCancelled, requestID.map({ $0 == responseID }) ?? true else { return }
        let owner = requestID ?? UUID()
        if requestID == nil {
            guard isCompanionActive, UIApplication.shared.applicationState == .active else { return }
            beginVoiceTurn()
            responseID = owner
            responseTask?.cancel()
            responseTask = nil
        } else if !followUpPolicy.takeAutomaticListen(
            voiceInitiated: usesVoiceFollowUp, isQuiet: companionPreferences.quietMode,
            isForeground: UIApplication.shared.applicationState == .active,
            isCurrent: isCompanionActive && responseID == owner,
            succeeded: true, isExecutingTools: isExecutingTools
        ) {
            await finishTurn(requestID: owner)
            return
        }
        #if DEBUG
        if requestID != nil && suppressAutomaticCaptureForTests { return }
        #endif
        let captureID = UUID()
        captureStartupID = captureID
        captureStartupTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performListen(followUp: followUp, requestID: owner, captureID: captureID,
                                     automatic: requestID != nil)
        }
        captureStartupTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if captureStartupID == captureID { captureStartupTask = nil }
    }

    private func checkCaptureStartup(requestID: UUID, captureID: UUID, automatic: Bool) throws {
        try Task.checkCancellation()
        guard responseID == requestID, captureStartupID == captureID, isCompanionActive,
              UIApplication.shared.applicationState == .active,
              !automatic || (followUpPolicy.isVoiceTurnActive && usesVoiceFollowUp
                             && !companionPreferences.quietMode && !isExecutingTools) else {
            throw CancellationError()
        }
    }

    private func performListen(followUp: Bool, requestID: UUID, captureID: UUID,
                               automatic: Bool) async {
        let wasIdle = app.session.currentPhase == .idle
        do {
            try checkCaptureStartup(requestID: requestID, captureID: captureID, automatic: automatic)
            if greeting != nil { recordAttention(.engaged, for: .greeting); greeting = nil }
            speaker.stop()
            error = nil
            if !followUp { notice = nil }
            try await prepareSession()
            try checkCaptureStartup(requestID: requestID, captureID: captureID, automatic: automatic)
            text = ""
            discardNextResult = false
            await app.showLiveActivity()
            try checkCaptureStartup(requestID: requestID, captureID: captureID, automatic: automatic)
            try await app.captureCoordinator.startCapture()
            try checkCaptureStartup(requestID: requestID, captureID: captureID, automatic: automatic)
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
            await finishTurn(requestID: requestID)
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
        followUpPolicy.endVoiceTurn()
        usesVoiceFollowUp = false
        voiceSession.end()
        clarification = nil
        proposalCard = nil
        if case .contextProposals = assistant { assistant = nil }
        if !isExecutingTools {
            responseID = UUID()
            responseTask?.cancel()
            responseTask = nil
            conversation = Conversation()
            actionRequest = nil
            actionSession = nil
        }
        captureStartupTask?.cancel()
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
        if !voiceFollowUp {
            followUpPolicy.endVoiceTurn()
            usesVoiceFollowUp = false
            voiceSession.end()
            proposalCard = nil
            if clarification?.session != nil { clarification = nil }
            actionSession = nil
        } else if voiceSession.owner == nil {
            // A capture launched from Control Center may arrive without Home having called listen.
            guard isCompanionActive, !companionPreferences.quietMode,
                  UIApplication.shared.applicationState == .active else { return }
            beginVoiceTurn()
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

    private func isCurrent(_ requestID: UUID, session: UUID?) -> Bool {
        guard responseID == requestID, !Task.isCancelled else { return false }
        guard let session else { return true }
        return voiceSession.owner == session && followUpPolicy.isVoiceTurnActive
            && usesVoiceFollowUp && isCompanionActive
            && UIApplication.shared.applicationState == .active
    }

    private func recordExchange(user: String, reply: String, requestID: UUID, session: UUID?) {
        guard let session, isCurrent(requestID, session: session) else { return }
        voiceSession.append(user: user, reply: reply, owner: session)
    }

    private static func caption(for source: EngineSource) -> String {
        switch source {
        case .model: "On-device model"
        case .rules(let reason): "Rules · \(reason.replacingOccurrences(of: "\n", with: " "))"
        }
    }

    /// Only confirmed facts are offered to general decisions. Raw dictations are searched
    /// separately for explicit history quotes, never as generic evidence after a fact was forgotten.
    private func decisionContext(for result: CaptureResult, request: String,
                                 requestID: UUID, session: UUID?) async throws -> DecisionContext {
        let origin = try await app.memory.captureTurn(forCapture: result.id)
        guard isCurrent(requestID, session: session) else { throw CancellationError() }
        guard origin.role == .user, origin.session == result.id, origin.text == result.shipped else {
            throw PikoError.storageUnavailable
        }
        let keywords = Array(RecallQuery.keywords(from: request).prefix(4))
        var facts: [MemoryFact] = []
        if keywords.isEmpty {
            // Still test the throwing read path instead of silently treating a broken store as empty.
            _ = try await app.memory.facts(matching: nil, limit: 1)
            guard isCurrent(requestID, session: session) else { throw CancellationError() }
        }
        for keyword in keywords {
            let matches = try await app.memory.facts(matching: keyword, limit: 5)
            guard isCurrent(requestID, session: session) else { throw CancellationError() }
            for fact in matches where !facts.contains(where: { $0.key == fact.key }) {
                facts.append(fact)
                if facts.count == 5 { break }
            }
            if facts.count == 5 { break }
        }
        return DecisionContext(facts: facts, recent: session != nil && session == voiceSession.owner
                               ? voiceSession.recent : [], personality: companionPreferences.personality)
    }

    private func quotedHistory(for result: CaptureResult, requestID: UUID,
                               session: UUID?) async throws -> [CaptureResult] {
        let origin = try await app.memory.captureTurn(forCapture: result.id)
        guard isCurrent(requestID, session: session) else { throw CancellationError() }
        guard origin.role == .user, origin.session == result.id, origin.text == result.shipped else {
            throw PikoError.storageUnavailable
        }
        var history: [CaptureResult] = []
        for keyword in RecallQuery.keywords(from: result.shipped).prefix(4) {
            let matches = await app.memory.search(keyword, limit: 5)
            guard isCurrent(requestID, session: session) else { throw CancellationError() }
            for match in matches where match.id != result.id
                && !history.contains(where: { $0.id == match.id }) {
                let source = try await app.memory.captureTurn(forCapture: match.id)
                guard isCurrent(requestID, session: session) else { throw CancellationError() }
                guard source.role == .user, source.session == match.id,
                      source.text == match.shipped else { throw PikoError.storageUnavailable }
                history.append(match)
                if history.count == 5 { break }
            }
            if history.count == 5 { break }
        }
        return history
    }

    private func performResponse(to result: CaptureResult, voiceFollowUp: Bool, requestID: UUID) async {
        let session = voiceFollowUp ? voiceSession.owner : nil
        guard isCurrent(requestID, session: session) else { return }
        usesVoiceFollowUp = voiceFollowUp
        celebrationTask?.cancel()
        isCelebrating = false
        let app = self.app
        let wasWaiting = conversation.isWaiting
        let pendingCard = proposalCard
        // A closing voice turn leaves the prior answer visible; keep its source label.
        if !wasWaiting, !(voiceFollowUp && isFollowUp && FollowUpPolicy.isClosing(result.shipped)) {
            engineCaption = nil
        }
        if wasWaiting,
           let reply = await hear(result.shipped, requestID: requestID) {
            guard isCurrent(requestID, session: session) else { return }
            await handle(reply, requestID: requestID, userText: result.shipped)
            return
        }
        guard isCurrent(requestID, session: session) else { return }
        if let pendingCard {
            if pendingCard.session == session && voiceFollowUp {
                if Self.isCardYes(result.shipped) {
                    await saveProposalCard(pendingCard.id, voice: true, requestID: requestID)
                    return
                }
                if Self.isCardNo(result.shipped) || FollowUpPolicy.isClosing(result.shipped) {
                    dismissProposalCard(pendingCard.id)
                    await finishTurn(requestID: requestID)
                    return
                }
            }
            dismissProposalCard(pendingCard.id)
        }
        if wasWaiting {
            conversation = Conversation()
            actionRequest = nil
            actionSession = nil
            engineCaption = nil
        }
        if voiceFollowUp, isFollowUp, !wasWaiting,
           FollowUpPolicy.isClosing(result.shipped) {
            await finishTurn(requestID: requestID)
            return
        }
        assistant = .thinking
        if let intent = PersonalIntent.parse(result.shipped) {
            clarification = nil
            engineCaption = nil
            await respondToPersonal(intent, capture: result, requestID: requestID)
            return
        }
        do {
            if ContextAnswer.recognizes(result.shipped) {
                let reply = try await ContextAnswer(memory: app.memory).answer(result.shipped)
                guard isCurrent(requestID, session: session) else { return }
                let answer: String
                let source: String?
                switch reply {
                case .unknown:
                    answer = "I don't know that yet. Tell me and I can save it."
                    source = nil
                case .grounded(_, let quote, _, let date):
                    answer = quote + (quote.hasSuffix(".") ? "" : ".")
                    source = "You said on \(date.formatted(date: .abbreviated, time: .omitted)): \"\(quote)\""
                }
                engineCaption = "Rules · Saved context"
                assistant = .personalAnswer(answer, source: source)
                await speak(answer)
                guard isCurrent(requestID, session: session) else { return }
                await listen(followUp: true, requestID: requestID)
                return
            }
            // A missing history turn must not prevent unrelated recall or model requests.
            let turn = try? await app.memory.captureTurn(forCapture: result.id)
            guard isCurrent(requestID, session: session) else { return }
            let candidates = turn.flatMap { turn in
                turn.role == .user && turn.session == result.id && turn.text == result.shipped
                    ? RuleContextProposer().propose(from: turn) : nil
            } ?? []
            if !candidates.isEmpty {
                var items: [ProposalCard.Item] = []
                var unchanged = 0
                var blocked = 0
                let organizer = ContextOrganizer(memory: app.memory)
                for candidate in candidates {
                    do {
                        let staged = try await organizer.stage(candidate)
                        guard isCurrent(requestID, session: session) else { return }
                        if case .unchanged = staged { unchanged += 1 }
                        else { items.append(ProposalCard.Item(staged: staged)) }
                    } catch ProposalGateError.sensitiveContent {
                        blocked += 1
                    }
                }
                if !items.isEmpty {
                    let card = ProposalCard(session: session, items: items)
                    proposalCard = card
                    engineCaption = "Rules · Suggested context"
                    assistant = .contextProposals(card)
                    let prompt = "I can save \(items.count) things about \(items.first?.proposal.entityName ?? "you"). Save them?"
                    await speak(prompt)
                    guard isCurrent(requestID, session: session), proposalCard?.id == card.id else { return }
                    await listen(followUp: true, requestID: requestID)
                    return
                }
                if unchanged > 0 || blocked == candidates.count {
                    let answer = unchanged > 0 ? "I already have that."
                        : "Piko doesn't save passwords, payment, codes or ID numbers."
                    assistant = .answer(answer)
                    await speak(answer)
                    guard isCurrent(requestID, session: session) else { return }
                    await listen(followUp: true, requestID: requestID)
                    return
                }
            }
            if result.route == .recall {
                clarification = nil
                let history = try await quotedHistory(for: result, requestID: requestID, session: session)
                guard isCurrent(requestID, session: session) else { return }
                let answer = try await RuleOrganizer().answer(result.shipped, from: history)
                guard isCurrent(requestID, session: session) else { return }
                engineCaption = "Rules · Quoted dictation history"
                assistant = .answer(answer)
                // A history quote may contain a previously forgotten value. Do not retain it
                // as implicit evidence for the next general model request.
                await speak(answer)
                guard isCurrent(requestID, session: session) else { return }
                await listen(followUp: true, requestID: requestID)
            } else {
                let pending = clarification?.session == session ? clarification : nil
                // Only actual user words can ground an action. The prior model question stays
                // separately quoted in context, never in the current request.
                let request = pending.map { "\($0.original)\n\(result.shipped)" } ?? result.shipped
                clarification = nil
                let baseContext = try await decisionContext(for: result, request: request,
                                                        requestID: requestID, session: session)
                guard isCurrent(requestID, session: session) else { return }
                let context = DecisionContext(facts: baseContext.facts, history: baseContext.history,
                                              recent: baseContext.recent, personality: baseContext.personality,
                                              pendingClarification: pending.map {
                                                  PendingClarification(originalRequest: $0.original,
                                                                       question: $0.question)
                                              })
                let tools = app.harness.actionDescriptors
                let decision = try await app.decider.decide(request, context: context, tools: tools, now: .now)
                guard isCurrent(requestID, session: session) else { return }
                engineCaption = Self.caption(for: decision.source)
                switch decision.decision {
                case .answer(let answer), .unknown(let answer):
                    assistant = .answer(answer)
                    recordExchange(user: result.shipped, reply: answer, requestID: requestID, session: session)
                    await speak(answer)
                    guard isCurrent(requestID, session: session) else { return }
                    await listen(followUp: true, requestID: requestID)
                case .ask(let question):
                    clarification = Clarification(original: request, question: question, session: session)
                    assistant = .clarifying(question)
                    recordExchange(user: result.shipped, reply: question, requestID: requestID, session: session)
                    await speak(question)
                    guard isCurrent(requestID, session: session) else { return }
                    await listen(followUp: true, requestID: requestID)
                case .act(let plan):
                    guard !plan.isEmpty, plan.count <= app.harness.maxSteps,
                          plan.allSatisfy({ call in
                              tools.contains(where: { $0.name == call.tool })
                                  && !call.tool.lowercased().hasPrefix("memory.")
                          }) else {
                        engineCaption = "Rules · Unregistered model action"
                        assistant = .answer("I couldn't safely run that action. Please try again.")
                        await finishTurn(requestID: requestID)
                        return
                    }
                    var talk = Conversation()
                    let reply = await talk.begin(plan, context: calendar, now: .now,
                                                 descriptors: app.harness.descriptors,
                                                 requiresExplicitConfirmation: pending != nil)
                    guard isCurrent(requestID, session: session) else { return }
                    conversation = talk
                    actionRequest = request
                    actionSession = session
                    await handle(reply, requestID: requestID, userText: result.shipped)
                }
            }
        } catch {
            guard isCurrent(requestID, session: session) else { return }
            assistant = nil
            engineCaption = nil
            self.error = "I couldn't check your saved information just now. Please try again."
            await finishTurn(requestID: requestID)
        }
    }

    private func respondToPersonal(_ intent: PersonalIntent, capture: CaptureResult, requestID: UUID) async {
        let session = usesVoiceFollowUp ? voiceSession.owner : nil
        do {
            switch intent {
            case .ask(let key, let subject):
                let fact = try await app.memory.fact(forKey: key)
                guard isCurrent(requestID, session: session) else { return }
                let source: MemoryTurn?
                if let sourceTurn = fact?.sourceTurn {
                    source = try await app.memory.turn(lsn: sourceTurn)
                } else {
                    source = nil
                }
                guard isCurrent(requestID, session: session) else { return }
                let answer = PersonalAnswer.reply(subject: subject, fact: fact)
                let sourceLabel = source.flatMap {
                    $0.role == .user
                        ? "From what you told Piko on \($0.at.formatted(date: .abbreviated, time: .omitted))"
                        : nil
                }
                engineCaption = "Rules · Personal fact lookup"
                assistant = .personalAnswer(answer, source: sourceLabel)
                recordExchange(user: capture.shipped, reply: answer, requestID: requestID, session: session)
                await speak(answer)
                guard isCurrent(requestID, session: session) else { return }
                await listen(followUp: true, requestID: requestID)

            case .remember, .forget:
                let origin = try await app.memory.captureTurn(forCapture: capture.id)
                guard isCurrent(requestID, session: session) else { return }
                guard origin.role == .user, origin.session == capture.id,
                      PersonalIntent.parse(origin.text) == intent else {
                    throw PersonalFactToolError.unverifiedOrigin
                }
                let existing = try await app.memory.fact(forKey: intent.key)
                guard isCurrent(requestID, session: session) else { return }
                if case .forget = intent, existing == nil {
                    let answer = "I don't have a saved fact about your \(intent.subject) to forget."
                    engineCaption = "Rules · No saved personal fact"
                    assistant = .personalAnswer(answer, source: nil)
                    recordExchange(user: capture.shipped, reply: answer, requestID: requestID, session: session)
                    await speak(answer)
                    guard isCurrent(requestID, session: session) else { return }
                    await listen(followUp: true, requestID: requestID)
                    return
                }
                let tool = if case .remember = intent { ToolName.remember } else { ToolName.forget }
                let call = ToolCall(tool: tool, text: origin.text, sourceCaptureID: capture.id,
                                    expectedFactLSN: existing?.lsn)
                var talk = conversation
                let reply = await talk.begin([call], context: nil, now: .now,
                                             descriptors: app.harness.descriptors)
                guard isCurrent(requestID, session: session) else { return }
                conversation = talk
                engineCaption = "Rules · Explicit personal memory"
                actionRequest = origin.text
                actionSession = session
                if let existing, case .confirm(let prompt) = reply {
                    await handle(.confirm("I have your \(intent.subject) saved as \(existing.value). \(prompt)"),
                                 requestID: requestID)
                } else {
                    await handle(reply, requestID: requestID)
                }
            }
        } catch {
            guard isCurrent(requestID, session: session) else { return }
            engineCaption = "Rules · Personal memory unavailable"
            assistant = .personalAnswer(
                (error as? PersonalFactToolError)?.userMessage
                    ?? (error as? PersonalMemoryError).flatMap {
                        if case .sourceCaptureMissing = $0 {
                            return PersonalFactToolError.unverifiedOrigin.userMessage
                        }
                        return nil
                    }
                    ?? "I couldn't check your saved facts just now. Please try again.",
                source: nil
            )
            await finishTurn(requestID: requestID)
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

    private func handle(_ reply: Conversation.Reply, requestID: UUID, userText: String? = nil) async {
        guard responseID == requestID else { return }
        let session = actionSession
        let personalWrite = conversation.plan.allSatisfy {
            $0.tool == ToolName.remember || $0.tool == ToolName.forget
        }
        switch reply {
        case .ask(let prompt), .confirm(let prompt):
            let canConfirm = conversation.waiting == .confirm
            assistant = .proposed(conversation.plan, prompt: prompt, canConfirm: canConfirm)
            if !personalWrite {
                recordExchange(user: userText ?? actionRequest ?? "", reply: prompt,
                               requestID: requestID, session: session)
            }
            await speak(prompt)
            // The user may have tapped Do it or Discard while Piko was speaking.
            guard responseID == requestID, case .proposed = assistant, conversation.isWaiting else { return }
            await listen(followUp: true, requestID: requestID)
        case .run(let ack):
            await execute(conversation.plan, ack: ack, requestID: requestID,
                          userText: userText ?? actionRequest ?? "")
        case .cancelled(let message):
            assistant = nil
            notice = message
            if !personalWrite {
                recordExchange(user: userText ?? actionRequest ?? "", reply: message,
                               requestID: requestID, session: session)
            }
            conversation = Conversation()
            actionRequest = nil
            actionSession = nil
            await speak(message)
            guard responseID == requestID else { return }
            await listen(followUp: true, requestID: requestID)
        }
    }

    private static func cardAnswer(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ".!?"))).lowercased()
    }

    private static func isCardYes(_ text: String) -> Bool {
        ["yes", "save", "save them", "yes please"].contains(cardAnswer(text))
    }

    private static func isCardNo(_ text: String) -> Bool {
        ["no", "no thanks", "cancel", "not now", "dismiss"].contains(cardAnswer(text))
    }

    func dismissProposalCard(_ id: UUID) {
        guard proposalCard?.id == id else { return }
        proposalCard = nil
        if case .contextProposals = assistant { assistant = nil; engineCaption = nil }
    }

    func saveProposalCard(_ id: UUID, voice: Bool = false, requestID: UUID? = nil) async {
        guard let card = proposalCard, card.id == id else { return }
        for item in card.items where item.status == .pending {
            await saveProposal(id, row: item.id)
        }
        guard let updated = proposalCard, updated.id == id else { return }
        let saved = updated.items.filter { $0.status == .saved }.count
        let failed = updated.items.filter { if case .failed = $0.status { return true }; return false }.count
        let changed = updated.items.filter { $0.status == .conflict || $0.changed }.count
        let message = [saved > 0 ? "Saved \(saved)." : nil,
                       failed > 0 ? "Could not save \(failed)." : nil,
                       changed > 0 ? "Review \(changed) changes on the card." : nil]
            .compactMap { $0 }.joined(separator: " ")
        if !updated.items.contains(where: { $0.status == .pending || $0.status == .conflict }) {
            dismissProposalCard(id)
            assistant = .answer(message)
        }
        if voice {
            await speak(message)
            guard let requestID else { return }
            if isCurrent(requestID, session: updated.session) {
                await listen(followUp: true, requestID: requestID)
            } else {
                await finishTurn(requestID: requestID)
            }
        }
    }

    func saveProposal(_ id: UUID, row: UUID) async {
        await applyProposal(id, row: row, resolution: nil)
    }

    func resolveProposal(_ id: UUID, row: UUID, decision: ContextOrganizer.Resolution) async {
        await applyProposal(id, row: row, resolution: decision)
    }

    private func applyProposal(_ id: UUID, row: UUID,
                               resolution: ContextOrganizer.Resolution?) async {
        guard let card = proposalCard, card.id == id,
              card.session == nil || card.session == voiceSession.owner || voiceSession.owner == nil,
              let item = card.items.first(where: { $0.id == row }),
              resolution != nil ? item.status == .conflict : item.status == .pending else { return }
        voiceSession.clearEvidence()
        let organizer = ContextOrganizer(memory: app.memory)
        do {
            let outcome: ContextOrganizer.Outcome
            if let resolution {
                outcome = try await organizer.resolve(resolution, on: item.staged, observedLSN: item.observedLSN)
            } else {
                outcome = try await organizer.confirm(item.staged, observedLSN: item.observedLSN)
            }
            guard proposalCard?.id == id,
                  let index = proposalCard?.items.firstIndex(where: { $0.id == row }) else { return }
            switch outcome {
            case .saved, .unchanged:
                proposalCard?.items[index].status = .saved
                if case .saved = outcome,
                   companionPreferences.shouldPresentRoutine(.completion), isCompanionActive {
                    isCelebrating = true
                    celebrationTask?.cancel()
                    celebrationTask = Task { [weak self] in
                        do { try await Task.sleep(for: self?.celebrationDelay ?? .milliseconds(1600)) } catch { return }
                        self?.isCelebrating = false
                    }
                }
            case .conflict:
                await restageProposal(id, row: row, item: item)
                return
            }
        } catch PersonalMemoryError.factConflict {
            await restageProposal(id, row: row, item: item)
            return
        } catch {
            guard proposalCard?.id == id,
                  let index = proposalCard?.items.firstIndex(where: { $0.id == row }) else { return }
            proposalCard?.items[index].status = .failed("Could not save this fact. Try again later.")
        }
        if let proposalCard { assistant = .contextProposals(proposalCard) }
    }

    private func restageProposal(_ id: UUID, row: UUID, item: ProposalCard.Item) async {
        do {
            let staged = try await ContextOrganizer(memory: app.memory).stage(item.proposal)
            guard proposalCard?.id == id,
                  let index = proposalCard?.items.firstIndex(where: { $0.id == row }) else { return }
            var updated = ProposalCard.Item(staged: staged, id: row)
            updated.changed = true
            proposalCard?.items[index] = updated
            if let proposalCard { assistant = .contextProposals(proposalCard) }
        } catch {
            guard proposalCard?.id == id,
                  let index = proposalCard?.items.firstIndex(where: { $0.id == row }) else { return }
            proposalCard?.items[index].status = .failed("This changed. Please ask again.")
            if let proposalCard { assistant = .contextProposals(proposalCard) }
        }
    }

    private var celebrationDelay: Duration {
        #if DEBUG
        celebrationDuration
        #else
        .milliseconds(1600)
        #endif
    }

    private func execute(_ plan: [ToolCall], ack: String, requestID: UUID, userText: String) async {
        guard responseID == requestID, plan == conversation.plan,
              plan.allSatisfy({ !conversation.requiresConfirmation($0) || conversation.isConfirmed($0) }) else {
            notice = "That action needs a fresh confirmation."
            return
        }
        let confirmed = conversation.confirmedPlan
        let session = actionSession
        let personalWrite = plan.allSatisfy {
            $0.tool == ToolName.remember || $0.tool == ToolName.forget
        }
        if personalWrite {
            voiceSession.clearEvidence()
            clarification = nil
        }
        isExecutingTools = true
        defer { isExecutingTools = false }
        assistant = .thinking
        let outcomes = await app.harness.run(plan, approve: { confirmed.contains($0) })
        guard isCurrent(requestID, session: session) else { return }
        if !personalWrite, outcomes.contains(where: {
            if case .done = $0.status { true } else { false }
        }) {
            app.dumpLog.record()
            weeklyDumps = app.dumpLog.countLastSevenDays()
        }
        if !personalWrite {
            if let session, isCurrent(requestID, session: session) {
                voiceSession.appendOutcome(user: userText, outcomes: outcomes, owner: session)
            }
        }
        conversation = Conversation()
        actionRequest = nil
        actionSession = nil
        assistant = .done(outcomes)
        let allDone = !outcomes.isEmpty && outcomes.count == plan.count
            && outcomes.allSatisfy { if case .done = $0.status { true } else { false } }
        if allDone, companionPreferences.shouldPresentRoutine(.completion), isCompanionActive {
            isCelebrating = true
            celebrationTask?.cancel()
            celebrationTask = Task { [weak self] in
                do { try await Task.sleep(for: self?.celebrationDelay ?? .milliseconds(1600)) } catch { return }
                self?.isCelebrating = false
            }
        }
        if !allDone || companionPreferences.shouldPresentRoutine(.completion) {
            let memoryOutcome: String? = plan.count == 1
                && (plan[0].tool == ToolName.remember || plan[0].tool == ToolName.forget)
                ? outcomes.first.flatMap { if case .done(let text) = $0.status { text } else { nil } }
                : nil
            await speak(allDone ? (memoryOutcome ?? (ack == "Saved." ? "Saved." : "Done."))
                                : "Some of that didn’t work. Have a look.")
        }
        guard responseID == requestID else { return }
        isExecutingTools = false
        if allDone {
            await listen(followUp: true, requestID: requestID)
        } else {
            await finishTurn(requestID: requestID)
        }
    }

    /// "Do it" on the card — the same as saying yes.
    func runPlan() async {
        guard !isBusy, !isExecutingTools else {
            notice = "The current action is still finishing."
            return
        }
        guard case .proposed(let visible, _, true) = assistant,
              conversation.waiting == .confirm, visible == conversation.plan else {
            notice = "That action needs a fresh confirmation."
            return
        }
        isBusy = true
        defer { isBusy = false }
        let requestID = UUID()
        responseID = requestID
        followUpPolicy.endVoiceTurn()
        usesVoiceFollowUp = false
        voiceSession.end()
        if clarification?.session != nil { clarification = nil }
        actionSession = nil
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
            followUpPolicy.endVoiceTurn()
            usesVoiceFollowUp = false
            voiceSession.end()
            clarification = nil
            actionSession = nil
            notice = "The approved action is finishing. Its result will stay visible."
            return
        }
        if let assistant {
            switch assistant {
            case .answer, .personalAnswer, .done:
                recordAttention(engaged ? .engaged : .dismissed, for: .completion)
            default: break
            }
        }
        responseID = UUID()
        followUpPolicy.endVoiceTurn()
        usesVoiceFollowUp = false
        voiceSession.end()
        clarification = nil
        actionRequest = nil
        actionSession = nil
        captureStartupTask?.cancel()
        responseTask?.cancel()
        celebrationTask?.cancel()
        isCelebrating = false
        speaker.stop()
        conversation = Conversation()
        proposalCard = nil
        assistant = nil
        engineCaption = nil
        let cleanupID = responseID
        let captureID = captureStartupID
        Task {
            guard self.responseID == cleanupID, self.captureStartupID == captureID else { return }
            await stopListeningQuietly()
            guard self.responseID == cleanupID, self.captureStartupID == captureID else { return }
            await finishTurn(requestID: cleanupID)
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
    private func finishTurn(requestID: UUID) async {
        guard responseID == requestID else { return }
        followUpPolicy.endVoiceTurn()
        if let session = voiceSession.owner {
            if clarification?.session == session { clarification = nil }
            if actionSession == session { actionSession = nil }
            voiceSession.end()
        }
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
    case contextProposals(ProposalCard)
    case proposed([ToolCall], prompt: String, canConfirm: Bool)
    case answer(String)
    case clarifying(String)
    case personalAnswer(String, source: String?)
    case done([ToolOutcome])

    var showsEngineCaption: Bool {
        switch self {
        case .contextProposals, .proposed, .answer, .clarifying, .personalAnswer, .done: true
        case .thinking: false
        }
    }
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var isHomeVisible = false

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
            .onAppear { isHomeVisible = true }
            .onDisappear {
                isHomeVisible = false
                model.setCompanionActive(false)
            }
            .onChange(of: showSetup) { _, showing in
                model.setCompanionActive(!showing && isHomeVisible && scenePhase == .active)
            }
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
                case .contextProposals(let card):
                    ContextProposalCard(card: card,
                        onSaveAll: { await model.saveProposalCard($0) },
                        onSave: { await model.saveProposal($0, row: $1) },
                        onResolve: { await model.resolveProposal($0, row: $1, decision: $2) },
                        onDismiss: { model.dismissProposalCard($0) })
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
                case .clarifying(let question):
                    Text(question)
                        .font(.headline)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Tell Piko the answer to continue.")
                        .font(.subheadline)
                        .foregroundStyle(theme.ink2)
                    Button("Not now") { model.dismissAssistant() }
                        .buttonStyle(.pikoQuiet)
                case .personalAnswer(let answer, let source):
                    Text(answer)
                        .font(.body)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let source {
                        Text(source).font(.caption).foregroundStyle(theme.ink2)
                    }
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
                if state.showsEngineCaption, let caption = model.engineCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(theme.ink2)
                        .accessibilityIdentifier("assistant.engine")
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
