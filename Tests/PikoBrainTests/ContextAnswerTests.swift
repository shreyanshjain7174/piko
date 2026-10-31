import Foundation
import PikoKit
import PikoMemory
import Testing
@testable import PikoBrain

private struct AnswerFixtureMemory: Memory {
    let saved: MemoryFact?
    let source: MemoryTurn?
    func fact(forKey key: String) async throws -> MemoryFact? { saved?.key == key ? saved : nil }
    func turn(lsn: Int64) async throws -> MemoryTurn? { source?.lsn == lsn ? source : nil }
    func record(_ result: CaptureResult) async {}
    func recordEdit(_ pair: EditPair) async {}
    func lexicon(limit: Int) async -> [String] { [] }
    func nearestEdits(to text: String, limit: Int) async -> [EditPair] { [] }
    func search(_ query: String, limit: Int) async -> [CaptureResult] { [] }
    func delete(_ id: UUID) async {}
    func appendTurn(session: UUID, role: MemoryTurn.Role, text: String, at: Date) async throws -> MemoryTurn {
        throw PersonalMemoryError.invalidTurn
    }
    func captureTurn(forCapture id: UUID) async throws -> MemoryTurn { throw PersonalMemoryError.invalidTurn }
    func turns(in session: UUID, limit: Int) async throws -> [MemoryTurn] { [] }
    func setFact(_ input: MemoryFactInput, ifLSN: Int64?) async throws -> MemoryFact {
        throw PersonalMemoryError.invalidTurn
    }
    func facts(matching query: String?, limit: Int) async throws -> [MemoryFact] { [] }
    func touchFact(forKey key: String, ifLSN: Int64, at: Date) async throws -> MemoryFact {
        throw PersonalMemoryError.invalidTurn
    }
    func forgetFact(forKey key: String, ifLSN: Int64) async throws {}
    func createEntity(_ entity: MemoryEntity) async throws {}
    func entity(id: String) async throws -> MemoryEntity? { nil }
    func entities(matching query: String?, limit: Int) async throws -> [MemoryEntity] { [] }
    func forgetEntity(id: String) async throws {}
}

@Suite struct ContextAnswerTests {
    @Test func groundedUsualAndMeetFromEphemeral() async throws {
        let memory = EphemeralMemory()
        let date = Date(timeIntervalSince1970: 123)
        let source = try await memory.appendTurn(session: UUID(), role: .user,
            text: "Riya\u{27}s usual is a flat white, and we meet on Fridays", at: date)
        let organizer = ContextOrganizer(memory: memory)
        for candidate in RuleContextProposer().propose(from: source) {
            let staged = try await organizer.stage(candidate, admittedBy: ProposalGate())
            _ = try await organizer.confirm(staged, observedLSN: nil)
        }
        #expect(ContextAnswer.recognizes("what does Riya drink?"))
        #expect(!ContextAnswer.recognizes("where does Riya live?"))
        let answerer = ContextAnswer(memory: memory)
        for question in ["what does Riya drink?", "what does Riya usually have?", "what\u{27}s Riya\u{27}s usual?"] {
            let reply = try await answerer.answer(question)
            guard case .grounded(let value, let quote, let lsn, let at) = reply else {
                Issue.record("Expected grounded answer for \(question)"); continue
            }
            #expect(value == "a flat white")
            #expect(source.text.contains(quote) && quote.contains(value))
            #expect(lsn == source.lsn && at == date)
        }
        let meeting = try await answerer.answer("when do I meet Riya?")
        guard case .grounded(let value, let quote, let lsn, let at) = meeting else {
            Issue.record("Expected meeting"); return
        }
        #expect(value == "Fridays" && quote == "we meet on Fridays")
        #expect(lsn == source.lsn && at == date)
        #expect(try await answerer.answer("what does Anil drink?") == .unknown)
        #expect(try await answerer.answer("where does Riya live?") == .unknown)
        let saved = try #require(await memory.fact(forKey: "person/riya/usual"))
        try await memory.forgetFact(forKey: saved.key, ifLSN: saved.lsn)
        #expect(try await answerer.answer("what does Riya drink?") == .unknown)
    }

    @Test func syntheticSQLiteGroundingAndForget() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        let source = try await memory.appendTurn(session: UUID(), role: .user,
            text: "Riya\u{27}s usual is tea", at: Date(timeIntervalSince1970: 123))
        let organizer = ContextOrganizer(memory: memory)
        let staged = try await organizer.stage(try #require(RuleContextProposer().propose(from: source).first),
                                                admittedBy: ProposalGate())
        _ = try await organizer.confirm(staged, observedLSN: nil)
        let answerer = ContextAnswer(memory: memory)
        guard case .grounded(let value, let quote, let lsn, let date) = try await answerer.answer("what does Riya drink") else {
            Issue.record("Expected SQLite answer"); return
        }
        #expect(value == "tea" && quote == source.text)
        #expect(lsn == source.lsn && date == source.at)
        let saved = try #require(await memory.fact(forKey: "person/riya/usual"))
        try await memory.forgetFact(forKey: saved.key, ifLSN: saved.lsn)
        #expect(try await answerer.answer("what does Riya drink") == .unknown)
    }

    @Test func rejectsUnverifiableFactsAndFabrication() async throws {
        let source = MemoryTurn(lsn: 9, session: UUID(), role: .user,
                                text: "Riya\u{27}s usual is tea", at: Date(timeIntervalSince1970: 123))
        func fact(_ value: String, sourceTurn: Int64? = 9) -> MemoryFact {
            MemoryFact(key: "person/riya/usual", value: value, lsn: 10, sourceTurn: sourceTurn,
                       confidence: 1, lastUsed: source.at, entityID: nil)
        }
        let nonUser = MemoryTurn(lsn: 9, session: source.session, role: .assistant,
                                 text: source.text, at: source.at)
        let cases: [AnswerFixtureMemory] = [
            .init(saved: nil, source: source),
            .init(saved: fact("tea", sourceTurn: nil), source: source),
            .init(saved: fact("tea"), source: nil),
            .init(saved: fact("tea"), source: nonUser),
            .init(saved: fact("espresso"), source: source), // Fabricating double: value absent from evidence.
        ]
        for fixture in cases {
            #expect(try await ContextAnswer(memory: fixture).answer("what does Riya drink?") == .unknown)
        }
    }
}
