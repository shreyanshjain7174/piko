import Foundation
import PikoKit

/// Apple's on-device speech stack behind the `Transcriber` protocol.
///
/// The interesting parameter is the stable-prefix threshold: how much of a hypothesis we are
/// willing to call settled and hand to the keyboard. Too eager and the field thrashes; too
/// conservative and text arrives in one lump at the end. Spike 3 finds the number.
public actor SpeechTranscriberEngine: Transcriber {
    private var lexicon: [String] = []
    private var sequence = 0

    public init() {}

    public func setLexicon(_ words: [String]) { lexicon = words }

    nonisolated public func hypotheses() -> AsyncStream<CaptureDraft> {
        // TODO(spike 3): SpeechAnalyzer + SpeechTranscriber with volatile results.
        // Verify how far SpeechTranscriber's contextual vocabulary reaches;
        // SFSpeechRecognitionRequest.contextualStrings is the documented fallback.
        AsyncStream { $0.finish() }
    }

    public func finish() async -> String { "" }
}
