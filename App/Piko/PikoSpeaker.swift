import Foundation
import AVFAudio
import PikoKit

/// Piko's voice: on-device `AVSpeechSynthesizer`, tuned cute (higher pitch, slower
/// rate, half volume), speaking only when the user asked for it and never while the
/// mic is live — the buddy doesn't talk over you (docs/HARNESS.md interactivity rules).
@MainActor
final class PikoSpeaker {
    static let shared = PikoSpeaker()

    private let synthesizer = AVSpeechSynthesizer()
    private let enabledKey = "piko.voice.enabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private init() {
        // Default to off: the buddy earns the voice, it doesn't start with one.
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            UserDefaults.standard.set(false, forKey: enabledKey)
        }
    }

    func preview() {
        speak("Hi, I'm Piko. I remember things, so you don't have to.")
    }

    func speak(_ line: String, phase: SessionPhase = .idle) {
        guard isEnabled, phase != .capturing, phase != .tidying, !line.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = Self.cuteVoice
        utterance.pitchMultiplier = 1.32
        utterance.rate = 0.46
        utterance.volume = 0.5
        utterance.preUtteranceDelay = 0.05
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private static var cuteVoice: AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        // Enhanced/premium builds sound noticeably warmer than the compact default.
        return voices.first { $0.identifier.contains("premium") }
            ?? voices.first { $0.identifier.contains("enhanced") }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}
