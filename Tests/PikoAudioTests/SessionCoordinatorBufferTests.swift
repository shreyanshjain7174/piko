#if os(iOS)
import AVFAudio
import Foundation
import Testing
@testable import PikoAudio
@testable import PikoKit

/// Buffer-stream lifecycle for `SessionCoordinator`: idle until `startCapture()`, yields
/// while capturing, silent after `stopCapture()`, and safe to `disarm()` mid-capture.
/// Simulator may yield silent PCM; this suite only proves the tap is installed and torn down.
@Suite("SessionCoordinator buffer lifecycle", .serialized)
struct SessionCoordinatorBufferTests {

    private enum ProbeResult {
        case observed
        case timedOut
    }

    /// Boxed so `AsyncStream.AsyncIterator` can cross into `TaskGroup.addTask`. Same
    /// pattern as `SessionCoordinatorInterruptionTests`: racing `.next()` must be the
    /// last use of that iterator (a cancelled loser returns nil forever after).
    private final class BufferIteratorBox: @unchecked Sendable {
        var iterator: AsyncStream<AVAudioPCMBuffer>.AsyncIterator
        init(_ iterator: AsyncStream<AVAudioPCMBuffer>.AsyncIterator) {
            self.iterator = iterator
        }
    }

    private func raceNextBuffer(
        _ box: BufferIteratorBox,
        timeout: Duration
    ) async throws -> ProbeResult {
        try await withThrowingTaskGroup(of: ProbeResult.self) { group -> ProbeResult in
            group.addTask {
                if await box.iterator.next() != nil { return .observed }
                return .timedOut
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    @Test @MainActor
    func buffersIdleUntilCapture() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let coordinator = SessionCoordinator(
                channel: MockSessionChannel(),
                interruptions: MockInterruptionSource(),
                isForeground: { true })

            try await coordinator.arm()

            let box = BufferIteratorBox(coordinator.buffers.makeAsyncIterator())
            let probe = try await raceNextBuffer(box, timeout: .milliseconds(200))
            #expect(probe == .timedOut)
            await coordinator.disarm()
        }
    }

    @Test @MainActor
    func captureProducesBuffers() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let coordinator = SessionCoordinator(
                channel: MockSessionChannel(),
                interruptions: MockInterruptionSource(),
                isForeground: { true })

            try await coordinator.arm()
            let box = BufferIteratorBox(coordinator.buffers.makeAsyncIterator())
            try await coordinator.startCapture()

            let probe = try await raceNextBuffer(box, timeout: .seconds(2))
            #expect(probe == .observed)

            await coordinator.stopCapture()
            await coordinator.disarm()
        }
    }

    @Test @MainActor
    func stopCaptureStopsBuffers() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let coordinator = SessionCoordinator(
                channel: MockSessionChannel(),
                interruptions: MockInterruptionSource(),
                isForeground: { true })

            try await coordinator.arm()
            let box = BufferIteratorBox(coordinator.buffers.makeAsyncIterator())
            try await coordinator.startCapture()

            let first = try await raceNextBuffer(box, timeout: .seconds(2))
            #expect(first == .observed)

            await coordinator.stopCapture()

            // makeStream() defaults to unbounded buffering, so buffers already
            // yielded before removeTap can still be queued. Drain those, then
            // require a 200ms timeout — proving the tap itself has stopped.
            var tapStopped = false
            for _ in 0..<20 {
                let probe = try await raceNextBuffer(box, timeout: .milliseconds(200))
                if probe == .timedOut {
                    tapStopped = true
                    break
                }
            }
            #expect(tapStopped)
            await coordinator.disarm()
        }
    }

    @Test @MainActor
    func disarmWhileCapturingRemovesTap() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let coordinator = SessionCoordinator(
                channel: MockSessionChannel(),
                interruptions: MockInterruptionSource(),
                isForeground: { true })

            var phaseIterator = coordinator.phase.makeAsyncIterator()

            try await coordinator.arm()
            #expect(await phaseIterator.next() == .armed)

            try await coordinator.startCapture()
            #expect(await phaseIterator.next() == .capturing)

            await coordinator.disarm()
            #expect(await phaseIterator.next() == .idle)
        }
    }
}
#endif
