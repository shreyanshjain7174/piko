import Testing
import Foundation
import PikoKit
@testable import PikoMemory

@Suite("Memory graph — remember, recall, forget")
struct MemoryGraphTests {

    private func makeMemory() throws -> SQLiteMemory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("piko-graph-\(UUID().uuidString).sqlite")
        return try SQLiteMemory(path: url)
    }

    @Test("indexing builds entities from dictations and is idempotent")
    func indexBuildsAndIsIdempotent() async throws {
        let memory = try makeMemory()
        await memory.record(CaptureResult(id: UUID(), raw: "call mom about the Interstellar plan",
                                          shipped: "Call Mom about the Interstellar plan"))
        await memory.indexNewResults()
        let once = await memory.rememberedEntities(limit: 20)
        #expect(!once.isEmpty)
        #expect(once.contains { $0.name.localizedCaseInsensitiveCompare("mom") == .orderedSame })

        // Re-running processes zero rows: no doubled counts.
        await memory.indexNewResults()
        let twice = await memory.rememberedEntities(limit: 20)
        for entity in twice {
            let before = once.first { $0.name.localizedCaseInsensitiveCompare(entity.name) == .orderedSame }
            #expect(before?.hitCount == entity.hitCount, "\(entity.name) should not double-count")
        }
    }

    @Test("repeated mentions raise hit counts")
    func repetitionRaisesCounts() async throws {
        let memory = try makeMemory()
        for _ in 0..<3 {
            await memory.record(CaptureResult(id: UUID(), raw: "watch Interstellar tonight",
                                              shipped: "Watch Interstellar tonight."))
        }
        await memory.indexNewResults()
        let entities = await memory.rememberedEntities(limit: 20)
        let topic = entities.first { $0.name.localizedCaseInsensitiveCompare("interstellar") == .orderedSame }
        #expect(topic?.hitCount == 3)
    }

    @Test("recall returns the last line and the hot entities")
    func recallPacket() async throws {
        let memory = try makeMemory()
        await memory.record(CaptureResult(id: UUID(), raw: "one", shipped: "First entry."))
        await memory.record(CaptureResult(id: UUID(), raw: "two", shipped: "Second entry about Interstellar."))
        await memory.indexNewResults()
        let packet = await memory.recall(query: "")
        #expect(packet?.lastSaid == "Second entry about Interstellar.")
        #expect((packet?.entities.isEmpty == false))
    }

    @Test("forget removes the entity entirely")
    func forgetRemovesEntity() async throws {
        let memory = try makeMemory()
        await memory.record(CaptureResult(id: UUID(), raw: "call mom",
                                          shipped: "Call Mom."))
        await memory.indexNewResults()
        await memory.forget(entity: "Mom")
        let remaining = await memory.rememberedEntities(limit: 20)
        #expect(!remaining.contains { $0.name.localizedCaseInsensitiveCompare("mom") == .orderedSame })
    }

    @Test("rebuildGraph re-derives the projection from the journal")
    func rebuildRecovers() async throws {
        let memory = try makeMemory()
        await memory.record(CaptureResult(id: UUID(), raw: "book flights to Lisbon",
                                          shipped: "Book flights to Lisbon."))
        await memory.indexNewResults()
        await memory.rebuildGraph()
        let entities = await memory.rememberedEntities(limit: 20)
        #expect(!entities.isEmpty)
    }

    @Test("topics ignore stopwords and short words")
    func topicFiltering() {
        let hits = EntityExtractor.extract(from: "maybe send that thing about tonight thanks")
        #expect(hits.filter { $0.kind == .topic }.isEmpty)
    }

    @Test("names are trimmed of articles and possessives")
    func nameTrimming() {
        #expect("the Park".trimmedName == "Park")
        #expect("mom's".trimmedName == "mom")
    }
}
