import Foundation
import PikoKit
import PikoMemory
import Testing
@testable import PikoBrain

private func proposal(_ source: MemoryTurn, value: String) -> ContextProposal {
    ContextProposal(kind: .preference, entityName: "Riya", key: "person/riya/usual",
                    label: "usual", value: value, quote: source.text, sourceTurn: source)
}

@Suite struct ContextOrganizerTests {
    @Test func stageDoesNotWriteAndConfirmCreatesEntity() async throws {
        let memory = EphemeralMemory()
        let source = try await memory.appendTurn(session: UUID(), role: .user,
                                                  text: "Riya\u{27}s usual is tea", at: .now)
        let organizer = ContextOrganizer(memory: memory)
        let staged = try await organizer.stage(proposal(source, value: "tea"), admittedBy: ProposalGate())
        guard case .new = staged else { Issue.record("Expected new"); return }
        #expect(try await memory.fact(forKey: "person/riya/usual") == nil)
        #expect(try await memory.entity(id: "person/riya") == nil)
        let outcome = try await organizer.confirm(staged, observedLSN: nil)
        guard case .saved(let saved) = outcome else { Issue.record("Expected saved"); return }
        #expect(saved.value == "tea" && saved.sourceTurn == source.lsn)
        #expect(saved.entityID == "person/riya")
        #expect(try await memory.entity(id: "person/riya")?.name == "Riya")
        let unchanged = try await organizer.stage(proposal(source, value: "tea"), admittedBy: ProposalGate())
        guard case .unchanged(_, let existing) = unchanged else { Issue.record("Expected unchanged"); return }
        #expect(existing == saved)
    }

    @Test func conflictKeepReplaceAndStaleRevision() async throws {
        let memory = EphemeralMemory()
        let source = try await memory.appendTurn(session: UUID(), role: .user,
                                                  text: "Riya\u{27}s usual is coffee and tea", at: .now)
        let organizer = ContextOrganizer(memory: memory)
        let first = try await organizer.stage(proposal(source, value: "tea"), admittedBy: ProposalGate())
        _ = try await organizer.confirm(first, observedLSN: nil)
        let old = try #require(await memory.fact(forKey: "person/riya/usual"))
        let staged = try await organizer.stage(proposal(source, value: "coffee"), admittedBy: ProposalGate())
        guard case .conflict(_, let existing) = staged else { Issue.record("Expected conflict"); return }
        #expect(existing == old)
        _ = try await organizer.resolve(.keep, on: staged, observedLSN: old.lsn)
        #expect(try await memory.fact(forKey: old.key) == old)
        let replaced = try await organizer.resolve(.replace, on: staged, observedLSN: old.lsn)
        guard case .saved(let updated) = replaced else { Issue.record("Expected replacement"); return }
        #expect(updated.value == "coffee" && updated.lsn != old.lsn)
        let stale = try await organizer.resolve(.replace, on: staged, observedLSN: old.lsn)
        guard case .conflict(let current) = stale else { Issue.record("Expected CAS conflict"); return }
        #expect(current == updated)
        #expect(try await memory.fact(forKey: old.key) == updated)
    }

    @Test func confirmConflictCannotReplaceWithoutResolution() async throws {
        let memory = EphemeralMemory()
        let source = try await memory.appendTurn(session: UUID(), role: .user,
                                                  text: "Riya\u{27}s usual is tea and coffee", at: .now)
        let organizer = ContextOrganizer(memory: memory)
        let first = try await organizer.stage(proposal(source, value: "tea"))
        _ = try await organizer.confirm(first, observedLSN: nil)
        let old = try #require(await memory.fact(forKey: "person/riya/usual"))
        let conflict = try await organizer.stage(proposal(source, value: "coffee"))
        let result = try await organizer.confirm(conflict, observedLSN: old.lsn)
        #expect(result == .conflict(existing: old))
        #expect(try await memory.fact(forKey: old.key) == old)
        let replaced = try await organizer.resolve(.replace, on: conflict, observedLSN: old.lsn)
        guard case .saved(let newFact) = replaced else { Issue.record("Expected replacement"); return }
        #expect(newFact.value == "coffee")
    }

    @Test func concurrentInsertAndGateRejection() async throws {
        let memory = EphemeralMemory()
        let source = try await memory.appendTurn(session: UUID(), role: .user,
                                                  text: "Riya\u{27}s usual is tea", at: .now)
        let organizer = ContextOrganizer(memory: memory)
        let candidate = proposal(source, value: "tea")
        let staged = try await organizer.stage(candidate, admittedBy: ProposalGate())
        let other = try await memory.setFact(MemoryFactInput(key: candidate.key, value: "coffee",
                                                              sourceTurn: source.lsn, confidence: 1), ifLSN: nil)
        let outcome = try await organizer.confirm(staged, observedLSN: nil)
        guard case .conflict(let existing) = outcome else { Issue.record("Expected concurrent conflict"); return }
        #expect(existing == other)
        let invalid = proposal(source, value: "invented")
        await #expect(throws: ProposalGateError.self) {
            _ = try await organizer.stage(invalid, admittedBy: ProposalGate())
        }
        #expect(try await memory.fact(forKey: candidate.key) == other)
    }

    @Test func sensitiveUtterancesNeverWrite() async throws {
        let utterances = [
            "remember my id is 2345-6789-0123",
            "remember my pan is abcde1234f",
            "remember my phone passcode is 482193",
            "remember my upi mpin is 4821",
            "remember my wifi pass is hunter2",
            "Riya\u{27}s usual is 2345-6789-0123",
        ]
        let memory = EphemeralMemory()
        let organizer = ContextOrganizer(memory: memory)
        for text in utterances {
            let source = try await memory.appendTurn(session: UUID(), role: .user, text: text, at: .now)
            let candidate = try #require(RuleContextProposer().propose(from: source).first)
            #expect(throws: ProposalGateError.sensitiveContent) {
                try ProposalGate().admit(candidate, source: source)
            }
            await #expect(throws: ProposalGateError.sensitiveContent) {
                _ = try await organizer.stage(candidate, admittedBy: ProposalGate())
            }
            #expect(try await memory.fact(forKey: candidate.key) == nil)
        }
        #expect(try await memory.entity(id: "person/riya") == nil)
    }

    @Test func sqliteFixture() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        let source = try await memory.appendTurn(session: UUID(), role: .user,
                                                  text: "Riya\u{27}s usual is tea", at: .now)
        let organizer = ContextOrganizer(memory: memory)
        let staged = try await organizer.stage(proposal(source, value: "tea"), admittedBy: ProposalGate())
        #expect(try await memory.fact(forKey: "person/riya/usual") == nil)
        _ = try await organizer.confirm(staged, observedLSN: nil)
        #expect(try await memory.entity(id: "person/riya")?.name == "Riya")
    }
}
