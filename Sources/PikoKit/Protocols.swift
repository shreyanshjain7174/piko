import Foundation

/// Cross-process channel between the keyboard extension and the container app.
/// The only place that knows how the two talk. See `PikoBridge`.
public protocol SessionChannel: Sendable {
    func post(_ signal: Signal)
    var signals: AsyncStream<Signal> { get }

    func readState() -> SessionState?
    func writeState(_ state: SessionState)
    func readDraft() -> CaptureDraft?
    func writeDraft(_ draft: CaptureDraft)
    func readResult() -> CaptureResult?
    func writeResult(_ result: CaptureResult)
}

/// Speech to text. Implementations must be swappable — see `docs/SPEC.md`.
public protocol Transcriber: Sendable {
    /// Bias the recogniser toward words this user actually uses.
    func setLexicon(_ words: [String]) async

    /// Streaming hypotheses. Ends when the caller stops the capture.
    func hypotheses() -> AsyncStream<CaptureDraft>

    /// Final, best-effort transcript once capture has stopped.
    func finish() async -> String
}

/// Routing and rewriting. One protocol so the model underneath is a config choice.
public protocol Brain: Sendable {
    /// Must be cheap. Never let the rewrite model decide this — see `docs/ARCHITECTURE.md`.
    func route(_ text: String) async -> Route

    func rewrite(_ text: String,
                 profile: Profile,
                 lexicon: [String],
                 examples: [EditPair]) async throws -> String
}

/// Local index and the learning loop. Retrieval, never a growing prompt.
public protocol Memory: Sendable {
    func record(_ result: CaptureResult) async
    func recordEdit(_ pair: EditPair) async
    func lexicon(limit: Int) async -> [String]
    func nearestEdits(to text: String, limit: Int) async -> [EditPair]
    func search(_ query: String, limit: Int) async -> [CaptureResult]
}

public enum PikoError: Error, Sendable {
    /// `arm()` was called from the background. Illegal — see CONSTRAINTS C2.
    case notForeground
    /// `startCapture()` was called before `arm()`.
    case notArmed
    case sessionInterrupted
    case brainUnavailable(String)
}
