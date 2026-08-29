import Foundation
import PikoKit

/// Serializes tests that touch the process-wide `AVAudioSession` / `AVAudioEngine`.
/// Swift Testing runs suites in parallel; two coordinators starting I/O at once
/// starves the tap and times out buffer reads.
actor AudioSessionTestGate {
    static let shared = AudioSessionTestGate()
    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        try await body()
    }
}

/// In-memory `SessionChannel` double. No App Group container, no device — mirrors
/// `DarwinChannel`'s lock pattern without touching the real cross-process channel.
final class MockSessionChannel: SessionChannel, @unchecked Sendable {

    private let lock = NSLock()
    private var state: SessionState?
    private var draft: CaptureDraft?
    private var result: CaptureResult?

    func post(_ signal: Signal) {}

    var signals: AsyncStream<Signal> {
        AsyncStream { _ in }
    }

    func readState() -> SessionState? { lock.withLock { state } }
    func writeState(_ state: SessionState) { lock.withLock { self.state = state } }
    func readDraft() -> CaptureDraft? { lock.withLock { draft } }
    func writeDraft(_ draft: CaptureDraft) { lock.withLock { self.draft = draft } }
    func readResult() -> CaptureResult? { lock.withLock { result } }
    func writeResult(_ result: CaptureResult) { lock.withLock { self.result = result } }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
