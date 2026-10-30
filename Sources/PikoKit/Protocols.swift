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

    /// Append real conversation evidence; capture results already insert their own user turn.
    func appendTurn(session: UUID, role: MemoryTurn.Role, text: String, at: Date) async throws -> MemoryTurn
    /// Resolve a real persisted capture, not merely an unverified session UUID or fabricated turn.
    func captureTurn(forCapture id: UUID) async throws -> MemoryTurn
    func turn(lsn: Int64) async throws -> MemoryTurn?
    /// Includes the capture's user turn; newest first, bounded by `limit`.
    func turns(in session: UUID, limit: Int) async throws -> [MemoryTurn]
    /// Nil expected LSN means insert-only; updates require the revision returned by a read.
    /// Final-v1 cannot guard against a stale revision reused after deletion and re-creation.
    func setFact(_ input: MemoryFactInput, ifLSN: Int64?) async throws -> MemoryFact
    func fact(forKey key: String) async throws -> MemoryFact?
    /// Search keys, values and linked entity names/aliases; nil query lists facts.
    func facts(matching query: String?, limit: Int) async throws -> [MemoryFact]
    func touchFact(forKey key: String, ifLSN: Int64, at: Date) async throws -> MemoryFact
    func forgetFact(forKey key: String, ifLSN: Int64) async throws
    func createEntity(_ entity: MemoryEntity) async throws
    func entity(id: String) async throws -> MemoryEntity?
    func entities(matching query: String?, limit: Int) async throws -> [MemoryEntity]
    func forgetEntity(id: String) async throws
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
    case speechUnavailable(String)
    case speechAssetsMissing
    case transcriptionFailed
    case sharedContainerUnavailable
    case storageUnavailable
    case benchmarkInProgress
}

extension PikoError {
    public var userMessage: String {
        switch self {
        case .notForeground:
            "Piko can only arm while it is on screen. Open Piko and tap Arm."
        case .notArmed:
            "Piko is not armed yet. Tap Arm first."
        case .sessionInterrupted:
            "Something else took over the microphone. Tap Arm to start again."
        case .microphoneDenied:
            "Piko needs the microphone to hear you. Turn it on in Settings › Piko › Microphone."
        case .audioUnavailable:
            "The microphone is busy. Close whatever is using it, then tap Arm."
        case .speechUnavailable(let locale):
            "On-device speech is unavailable for \(locale) on this iPhone."
        case .speechAssetsMissing:
            "The speech language pack is not ready. Connect once and download it before dictating offline."
        case .transcriptionFailed:
            "Piko could not finish this dictation. Your visible text has been left unchanged. Please re-arm and try again."
        case .sharedContainerUnavailable:
            "Piko cannot open its shared container. Check App Group signing and keyboard Full Access, then reopen Piko."
        case .storageUnavailable:
            "Piko could not open local history. Reopen Piko; do not delete the app if you need to keep saved dictations."
        case .benchmarkInProgress:
            "A developer audio-file benchmark is running. Voice capture is disabled until Piko is relaunched normally."
        case .brainUnavailable:
            "Piko can still transcribe, but tidying needs Apple Intelligence turned on for this device."
        case .brainBudgetExceeded:
            "Tidying took too long, so Piko used what it heard instead."
        }
    }

    public static func userMessage(for error: any Error) -> String {
        (error as? PikoError)?.userMessage
            ?? "Piko could not open the microphone. Tap Arm to try again."
    }
}
