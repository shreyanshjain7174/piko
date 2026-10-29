import AVFAudio
import EventKit
import Foundation
import PikoBrain
import PikoKit
import Synchronization

/// Resolve the token inside the SDK callback; only a UUID crosses to the main actor.
private final class SpeechCallbackTokens: Sendable {
    private let pending = Mutex<[ObjectIdentifier: UUID]>([:])

    func begin(_ utterance: AVSpeechUtterance) -> UUID {
        let identifier = ObjectIdentifier(utterance)
        let token = UUID()
        pending.withLock { $0[identifier] = token }
        return token
    }

    func take(_ utterance: AVSpeechUtterance) -> UUID? {
        let identifier = ObjectIdentifier(utterance)
        return pending.withLock { $0.removeValue(forKey: identifier) }
    }

    func cancel() { pending.withLock { $0.removeAll(keepingCapacity: true) } }
}

/// Piko's spoken replies, using the on-device system voice.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let enabledKey = "PikoSpokenReplies"
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?
    private var playback = PikoSpeechLifecycle()
    nonisolated private let callbacks = SpeechCallbackTokens()
    var onSpeakingChange: (@MainActor (Bool) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Returns when speech has finished, so listening never overlaps Piko's own voice.
    func say(_ text: String, personality: PikoPersonality = .warm) async {
        guard isEnabled, !text.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-IN") ?? AVSpeechSynthesisVoice(language: "en-US")
        switch personality {
        case .warm:
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            utterance.pitchMultiplier = 1.08
        case .calm:
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
            utterance.pitchMultiplier = 0.98
        case .direct:
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1
        }
        await withCheckedContinuation { continuation in
            finished = continuation
            playback.begin(callbacks.begin(utterance))
            onSpeakingChange?(true)
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        playback.cancel()
        callbacks.cancel()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finished?.resume()
        finished = nil
        onSpeakingChange?(false)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let id = callbacks.take(utterance) else { return }
        Task { @MainActor in self.finishCurrent(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard let id = callbacks.take(utterance) else { return }
        Task { @MainActor in self.finishCurrent(id) }
    }

    private func finishCurrent(_ id: UUID) {
        guard playback.finish(id) else { return }
        finished?.resume()
        finished = nil
        onSpeakingChange?(false)
    }
}

/// Clash checks against the user's calendar. Needs full calendar access, asked the first time
/// Piko is about to add an event.
struct EventKitCalendar: CalendarContext {
    func busy(from start: Date, to end: Date) async -> [String] {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate < end && $0.endDate > start }
            .map { $0.title ?? "something" }
    }
}
