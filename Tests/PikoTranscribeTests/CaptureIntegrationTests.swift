import Foundation
import Testing
import PikoKit
@testable import PikoTranscribe
#if os(iOS)
@testable import PikoAudio
@testable import PikoCaptureCore
#endif

/// Integration tests for the capture pipeline using mocks
@Suite("Capture pipeline integration", .serialized)
struct CaptureIntegrationTests {

    #if os(iOS)
    @Test @MainActor func startCaptureBeginsDraftFlow() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let channel = MockSessionChannel()
            let mock = MockTranscriber()
            let script = MockTranscriber.Script(drafts: [
                CaptureDraft(sessionEpoch: 1, sequence: 1, text: "Hello", stablePrefix: 0),
                CaptureDraft(sessionEpoch: 1, sequence: 2, text: "Hello world", stablePrefix: 11),
            ], delayBetween: .milliseconds(50))
            await mock.setScript(script)

            let session = SessionCoordinator(
                channel: channel,
                interruptions: NullInterruptionSource(),
                isForeground: { true }
            )

            let coordinator = CaptureCoordinator(
                session: session,
                channel: channel,
                transcriber: mock
            )

            try await session.arm()
            try await coordinator.startCapture()

            try await Task.sleep(for: .milliseconds(200))

            let drafts = channel.allDrafts()
            #expect(drafts.count >= 2)
            #expect(drafts.last?.text == "Hello world")
            #expect(channel.postedSignals.contains(.draftUpdated))

            await coordinator.stopCapture()
            await session.disarm()
        }
    }

    @Test @MainActor func stopCaptureWritesResult() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let channel = MockSessionChannel()
            let mock = MockTranscriber()
            let script = MockTranscriber.Script(drafts: [
                CaptureDraft(sessionEpoch: 1, sequence: 1, text: "Final text.", stablePrefix: 11),
            ], delayBetween: .milliseconds(10))
            await mock.setScript(script)

            let session = SessionCoordinator(
                channel: channel,
                interruptions: NullInterruptionSource(),
                isForeground: { true }
            )

            let coordinator = CaptureCoordinator(
                session: session,
                channel: channel,
                transcriber: mock
            )

            try await session.arm()
            try await coordinator.startCapture()
            try await Task.sleep(for: .milliseconds(100))
            await coordinator.stopCapture()

            let result = channel.readResult()
            #expect(result != nil)
            #expect(result?.raw == "Final text.")
            #expect(channel.postedSignals.contains(.resultReady))

            await session.disarm()
        }
    }
    #endif
}

#if os(iOS)
/// In-memory `SessionChannel` double for capture-pipeline tests.
/// Records every draft (not just the latest) and every posted signal.
final class MockSessionChannel: SessionChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var posted: [Signal] = []
    private var state: SessionState?
    private var draft: CaptureDraft?
    private var drafts: [CaptureDraft] = []
    private var result: CaptureResult?

    var postedSignals: [Signal] { lock.withLock { posted } }

    func allDrafts() -> [CaptureDraft] { lock.withLock { drafts } }

    func post(_ signal: Signal) {
        lock.withLock { posted.append(signal) }
    }

    var signals: AsyncStream<Signal> {
        AsyncStream { _ in }
    }

    func readState() -> SessionState? { lock.withLock { state } }
    func writeState(_ state: SessionState) { lock.withLock { self.state = state } }
    func readDraft() -> CaptureDraft? { lock.withLock { draft } }
    func writeDraft(_ draft: CaptureDraft) {
        lock.withLock {
            self.draft = draft
            drafts.append(draft)
        }
    }
    func readResult() -> CaptureResult? { lock.withLock { result } }
    func writeResult(_ result: CaptureResult) { lock.withLock { self.result = result } }
}

/// Serializes tests that touch process-wide `AVAudioSession` / `AVAudioEngine`.
/// Copied locally so PikoTranscribeTests does not depend on PikoAudioTests.
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

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
#endif
