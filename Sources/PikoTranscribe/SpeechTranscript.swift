import Foundation

/// Mirrors Apple's SpeechAnalyzer sample: final results are appended once, and each volatile
/// result replaces the whole unfinalized tail. Volatile and final ranges for the same speech
/// can start at different times, so phrases must not be keyed by range start.
struct SpeechTranscript {
    private var finals: [String] = []
    private var lastFinalStart: Double?
    private var volatile = ""

    mutating func update(_ text: String, at start: Double, isFinal: Bool) {
        if let lastFinalStart, start <= lastFinalStart { return }
        if isFinal {
            finals.append(text)
            lastFinalStart = start
            volatile = ""
        } else {
            volatile = text
        }
    }

    private static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var text: String { Self.join(finals + [volatile]) }
    var finalText: String { Self.join(finals) }
    var stablePrefix: Int { finalText.count }
    var isFinal: Bool { volatile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
