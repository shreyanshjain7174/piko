import AVFAudio
import EventKit
import Foundation
import PikoBrain

/// Piko's spoken replies, using the on-device system voice.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let enabledKey = "PikoSpokenReplies"
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Returns when speech has finished, so listening never overlaps Piko's own voice.
    func say(_ text: String) async {
        guard isEnabled, !text.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-IN") ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        await withCheckedContinuation { continuation in
            finished = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finished?.resume()
        finished = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishCurrent() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishCurrent() }
    }

    private func finishCurrent() {
        finished?.resume()
        finished = nil
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
