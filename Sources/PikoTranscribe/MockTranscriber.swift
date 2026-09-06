import Foundation
import PikoKit

/// Deterministic transcriber for tests and Simulator development.
/// Ignores actual audio buffers; produces a scripted sequence of drafts.
public actor MockTranscriber: Transcriber {
    public struct Script: Sendable {
        public let drafts: [CaptureDraft]
        public let delayBetween: Duration

        public init(drafts: [CaptureDraft], delayBetween: Duration = .milliseconds(100)) {
            self.drafts = drafts
            self.delayBetween = delayBetween
        }

        /// Convenience: builds a progressive dictation like "Hel" → "Hello" → "Hello wor" → "Hello world"
        public static func progressive(_ final: String, chunkSize: Int = 3, sessionEpoch: Int = 1) -> Script {
            var drafts: [CaptureDraft] = []
            var i = 0
            for endIndex in stride(from: chunkSize, through: final.count, by: chunkSize) {
                let text = String(final.prefix(endIndex))
                let stablePrefix = text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") ? text.count : 0
                i += 1
                drafts.append(CaptureDraft(sessionEpoch: sessionEpoch, sequence: i, text: text, stablePrefix: stablePrefix))
            }
            // Final draft with full text
            if drafts.last?.text != final {
                i += 1
                drafts.append(CaptureDraft(sessionEpoch: sessionEpoch, sequence: i, text: final, stablePrefix: final.count))
            }
            return Script(drafts: drafts)
        }
    }

    private var script: Script?
    private var usesExplicitScript = false
    private var lexicon: [String] = []

    public init() {}

    public func setLexicon(_ words: [String]) { lexicon = words }

    public func setScript(_ script: Script) {
        self.script = script
        usesExplicitScript = true
    }

    public func setDefaultScript(_ script: Script) {
        guard !usesExplicitScript else { return }
        self.script = script
    }

    nonisolated public func hypotheses() -> AsyncStream<CaptureDraft> {
        AsyncStream { continuation in
            Task { await self.runScript(continuation: continuation) }
        }
    }

    private func runScript(continuation: AsyncStream<CaptureDraft>.Continuation) async {
        guard let script else {
            continuation.finish()
            return
        }

        for draft in script.drafts {
            try? await Task.sleep(for: script.delayBetween)
            continuation.yield(draft)
        }
        continuation.finish()
    }

    public func finish() async -> String {
        script?.drafts.last?.text ?? ""
    }
}
