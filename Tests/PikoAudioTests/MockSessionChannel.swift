import Foundation
import PikoKit

/// Serializes tests that touch the process-wide `AVAudioSession` / `AVAudioEngine`.
/// Swift Testing runs suites in parallel; two coordinators starting I/O at once
/// starves the tap and times out buffer reads.
///
/// FIFO mutex: `busy` stays true while `body` runs. A naive `actor` method that
/// only `await`s `body()` hops off isolation and lets a second test enter.
actor AudioSessionTestGate {
    static let shared = AudioSessionTestGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
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
