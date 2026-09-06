import Testing
import Foundation
@testable import PikoBridge
@testable import PikoKit

/// Proves the Darwin-notification + App-Group-file round-trip *mechanism* completes and returns
/// the exact payload sent, using a generous CI-safe timeout. This does NOT certify the literal
/// under-120ms BRDG-02 acceptance number -- that requires a physical-device measurement, recorded
/// separately in docs/SPIKES.md Spike 1 (currently "not run"). Per 02-RESEARCH.md's Pitfall 3, a
/// same-process or Simulator-adjacent timing number must never be reported as satisfying BRDG-02.

@Test("a draft written by one channel is observed via signal and read back correctly by another")
func roundTripCompletesWithCorrectPayload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sideA = DarwinChannel(container: directory)
    let sideB = DarwinChannel(container: directory)

    let sent = CaptureDraft(sessionEpoch: 0, sequence: 0, text: "roundtrip", stablePrefix: 0, startedAt: .now)

    enum RaceResult { case signalObserved, timedOut }

    // Materialize the AsyncStream (which registers its continuation synchronously, see
    // DarwinChannel.signals) BEFORE writing, so the write below cannot race ahead of the
    // subscription -- AsyncStream buffers unbounded, so any signal posted after this line is
    // guaranteed to be observed once the child task below starts iterating.
    let stream = sideB.signals

    let result = try await withThrowingTaskGroup(of: RaceResult.self) { group in
        group.addTask {
            for await signal in stream where signal == .draftUpdated {
                return .signalObserved
            }
            return .timedOut
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            return .timedOut
        }

        sideA.writeDraft(sent)

        let first = try await group.next()!
        group.cancelAll()
        return first
    }

    #expect(result == .signalObserved, "round trip did not complete within the 2s CI-safe timeout")

    let received = try #require(sideB.readDraft())
    #expect(received == sent)

    // Observed in-process elapsed time, recorded for interest only -- this is explicitly NOT the
    // BRDG-02 acceptance measurement. That is a physical-device-only number tracked in
    // docs/SPIKES.md Spike 1, which remains "not run" as of this plan.
    let observedElapsedMS = Date.now.timeIntervalSince(received.startedAt) * 1000
    print("RoundTripLatencyTests: observed in-process elapsed ms (NOT the BRDG-02 device measurement): \(observedElapsedMS)")
}
