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
    func delete(_ id: UUID) async

    /// Memory-graph operations (docs/MEMORY-ARCHITECTURE.md). Declared as requirements
    /// so conformers are dynamically dispatched through `any Memory` — extension-only
    /// defaults would statically bind to the default body and silently skip overrides.
    func indexNewResults() async
    func rememberedEntities(limit: Int) async -> [RememberedEntity]
    func forget(entity name: String) async
    func recall(query: String) async -> MemoryPacket?
}

public enum PikoError: Error, Sendable {
    /// `arm()` was called from the background. Illegal — see CONSTRAINTS C2.
    case notForeground
    /// `startCapture()` was called before `arm()`.
    case notArmed
    case sessionInterrupted
    /// The model cannot run here (ineligible device, Apple Intelligence off, not iOS 26).
    case brainUnavailable(String)
    /// The model could run but did not finish within the rewrite budget.
    case brainBudgetExceeded(milliseconds: Int)
    case microphoneDenied
    case audioUnavailable
}

extension PikoError {
    public var userMessage: String {
        switch self {
        case .notForeground:
            "Piko can only arm while it is on screen. Open Piko and tap Start session."
        case .notArmed:
            "Piko is not set up yet. Tap Start session on Home first."
        case .sessionInterrupted:
            "Something else took over the microphone. Tap Start session to try again."
        case .microphoneDenied:
            "Piko needs the microphone to hear you. Turn it on in Settings › Piko › Microphone."
        case .audioUnavailable:
            "The microphone is busy. Close whatever is using it, then tap Start session."
        case .brainUnavailable:
            "Piko can still transcribe, but tidying needs Apple Intelligence turned on for this device."
        case .brainBudgetExceeded:
            "Tidying took too long, so Piko used what it heard instead."
        }
    }

    public static func userMessage(for error: any Error) -> String {
        (error as? PikoError)?.userMessage
            ?? "Piko could not open the microphone. Tap Start session to try again."
    }
}
