import Testing
import Foundation
import PikoKit
@testable import PikoBrain

/// The pocket harness, tier 0: deterministic routing and honest answers.
@Suite("PikoAgent — the pocket harness")
struct PikoAgentTests {

    private actor StubMemory: Memory {
        var packet: MemoryPacket?
        var forgotten: [String] = []
        init(packet: MemoryPacket?) { self.packet = packet }

        func record(_ result: CaptureResult) {}
        func recordEdit(_ pair: EditPair) {}
        func delete(_ id: UUID) {}
        func lexicon(limit: Int) -> [String] { [] }
        func nearestEdits(to text: String, limit: Int) -> [EditPair] { [] }
        func search(_ query: String, limit: Int) -> [CaptureResult] { [] }
        func recall(query: String) -> MemoryPacket? { packet }
        func forget(entity name: String) { forgotten.append(name) }
    }

    private func packetWith(_ name: String, kind: RememberedEntity.Kind = .topic,
                            hits: Int = 3, lastSaid: String? = "Call Mom tonight.") -> MemoryPacket {
        MemoryPacket(
            lastSaid: lastSaid,
            entities: [RememberedEntity(name: name, kind: kind, hitCount: hits)],
            suggestion: nil
        )
    }

    // MARK: Router

    @Test("recall phrasings route to recall with the subject as query")
    func recallRouting() {
        #expect(AgentRouter.route("what do you remember about Interstellar?") == .recall(query: "interstellar"))
        #expect(AgentRouter.route("tell me about Mom") == .recall(query: "mom"))
        #expect(AgentRouter.route("did I say anything about Lisbon") == .write)
    }

    @Test("suggest phrasings route to suggest")
    func suggestRouting() {
        #expect(AgentRouter.route("suggest something") == .suggest)
        #expect(AgentRouter.route("I'm bored") == .suggest)
    }

    @Test("everything ambiguous falls through to write — dictation is the product")
    func writeIsDefault() {
        #expect(AgentRouter.route("hey piko the quick brown fox") == .write)
        #expect(AgentRouter.route("") == .write)
    }

    // MARK: Turns

    @Test("a recall hit answers with the entity, a chip, and a happy pet")
    func recallHit() async {
        let agent = PikoAgent(memory: StubMemory(packet: packetWith("Interstellar", hits: 3)))
        let turn = await agent.turn("what do you remember about interstellar", hour: 20)
        #expect(turn?.line.contains("Interstellar") == true)
        #expect(turn?.chips.contains("Forget Interstellar") == true)
        #expect(turn?.mood == .happy)
    }

    @Test("a recall miss is honest — never a confabulation")
    func recallMiss() async {
        let agent = PikoAgent(memory: StubMemory(packet: MemoryPacket()))
        let turn = await agent.turn("what do you remember about Lisbon", hour: 20)
        #expect(turn?.line.contains("Nothing yet") == true)
        #expect(turn?.chips.isEmpty == true)
    }

    @Test("the suggest turn carries the suggestion and wants to speak it")
    func suggestTurn() async {
        let packet = MemoryPacket(
            lastSaid: nil,
            entities: [RememberedEntity(name: "Interstellar", kind: .topic, hitCount: 4)],
            suggestion: Suggestion(text: "Interstellar has come up a few times — tonight might be the night.")
        )
        let agent = PikoAgent(memory: StubMemory(packet: packet))
        let turn = await agent.turn("suggest something", hour: 20)
        #expect(turn?.line.contains("Interstellar") == true)
        #expect(turn?.speak == true)
    }

    @Test("a forget chip is a whole follow-up turn")
    func forgetChip() async {
        let memory = StubMemory(packet: packetWith("Mom", kind: .person))
        let agent = PikoAgent(memory: memory)
        let turn = await agent.chip("Forget Mom")
        #expect(turn?.line.contains("forgotten") == true)
        #expect(await memory.forgotten == ["Mom"])
    }
}
