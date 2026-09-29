import Foundation
import Testing
import PikoKit
@testable import PikoBrain
#if os(iOS)
@testable import PikoCaptureCore
#endif

#if os(iOS)

/// Minimal in-memory doubles so AskCoordinator can be exercised end-to-end
/// without the Darwin bridge or SQLite memory.
private final class InMemoryChannel: SessionChannel, @unchecked Sendable {
    let lock = NSLock()
    var stored: SessionState? = SessionState(phase: .armed, heartbeat: .now, skin: .cute, profile: .message)
    var posted: [Signal] = []
    var lastResult: CaptureResult?
    var lastDraft: CaptureDraft?

    var signals: AsyncStream<Signal> { AsyncStream { _ in } }

    func post(_ signal: Signal) {
        lock.lock(); posted.append(signal); lock.unlock()
    }
    func readState() -> SessionState? { lock.lock(); defer { lock.unlock() }; return stored }
    func writeState(_ state: SessionState) { lock.lock(); stored = state; lock.unlock() }
    func readDraft() -> CaptureDraft? { lock.lock(); defer { lock.unlock() }; return lastDraft }
    func writeDraft(_ draft: CaptureDraft) { lock.lock(); lastDraft = draft; lock.unlock() }
    func readResult() -> CaptureResult? { lock.lock(); defer { lock.unlock() }; return lastResult }
    func writeResult(_ result: CaptureResult) { lock.lock(); lastResult = result; lock.unlock() }
}

private actor RecordingMemory: Memory {
    var records: [CaptureResult] = []
    var recallPacket: MemoryPacket?

    func record(_ result: CaptureResult) async { records.append(result) }
    func recordEdit(_ pair: EditPair) async {}
    func lexicon(limit: Int) async -> [String] { [] }
    func nearestEdits(to text: String, limit: Int) async -> [EditPair] { [] }
    func search(_ query: String, limit: Int) async -> [CaptureResult] { [] }
    func delete(_ id: UUID) async {}
    func indexNewResults() async {}
    func rememberedEntities(limit: Int) async -> [RememberedEntity] { [] }
    func forget(entity name: String) async {}
    func recall(query: String) async -> MemoryPacket? { recallPacket }

    func setRecall(_ packet: MemoryPacket?) { recallPacket = packet }
    func recordedCount() -> Int { records.count }
    func recorded(at index: Int) -> CaptureResult? { records[safe: index] }
}

private struct PassthroughBrain: Brain, @unchecked Sendable {
    func route(_ text: String) async -> Route { .write }
    func rewrite(_ text: String, profile: Profile, lexicon: [String], examples: [EditPair]) async throws -> String {
        // Marker suffix so the test can prove the brain's output is what gets shipped.
        text + " ✓"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        (0..<count).contains(index) ? self[index] : nil
    }
}

@Suite("AskCoordinator")
struct AskCoordinatorTests {

    @Test @MainActor func emptyInputProducesNoTurn() async {
        let memory = RecordingMemory()
        let channel = InMemoryChannel()
        let coord = AskCoordinator(
            agent: PikoAgent(memory: memory),
            memory: memory,
            brain: PassthroughBrain(),
            channel: channel
        )
        let result = await coord.handle("   ")
        #expect(result == nil)
        #expect(await memory.recordedCount() == 0)
        #expect(channel.posted.isEmpty)
    }

    @Test @MainActor func writeRouteRecordsAndPostsResult() async {
        let memory = RecordingMemory()
        let channel = InMemoryChannel()
        let coord = AskCoordinator(
            agent: PikoAgent(memory: memory),
            memory: memory,
            brain: PassthroughBrain(),
            channel: channel
        )
        let result = await coord.handle("call mom about dinner")
        #expect(result == nil, "write route hands off to the transcript, not the ask card")
        #expect(await memory.recordedCount() == 1)
        let recorded = await memory.recorded(at: 0)
        #expect(recorded?.raw == "call mom about dinner")
        #expect(recorded?.shipped == "call mom about dinner ✓")
        #expect(channel.readResult()?.shipped == "call mom about dinner ✓")
        #expect(channel.posted.contains(.resultReady))
    }

    @Test @MainActor func recallRouteAnswersInline() async {
        let memory = RecordingMemory()
        await memory.setRecall(MemoryPacket(
            lastSaid: "yesterday",
            entities: [RememberedEntity(name: "the deck", kind: .topic, hitCount: 3, lastSeen: .now)]))
        let channel = InMemoryChannel()
        let coord = AskCoordinator(
            agent: PikoAgent(memory: memory),
            memory: memory,
            brain: PassthroughBrain(),
            channel: channel
        )
        let turn = await coord.handle("what did i say about the deck")
        #expect(turn != nil)
        #expect(turn?.line.contains("the deck") == true)
        #expect(await memory.recordedCount() == 0, "recall must not record")
        #expect(channel.readResult() == nil, "recall must not publish a result")
    }

    @Test @MainActor func chipHandlerRoutesThroughAgent() async {
        let memory = RecordingMemory()
        await memory.setRecall(MemoryPacket(
            lastSaid: "yesterday",
            entities: [RememberedEntity(name: "the deck", kind: .topic, hitCount: 4, lastSeen: .now)]))
        let channel = InMemoryChannel()
        let coord = AskCoordinator(
            agent: PikoAgent(memory: memory),
            memory: memory,
            brain: PassthroughBrain(),
            channel: channel
        )
        let turn = await coord.chip("Forget the deck")
        #expect(turn != nil)
    }
}

#endif
