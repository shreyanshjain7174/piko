import Foundation
import PikoKit
import Testing
@testable import PikoBrain

private func turn(_ text: String, role: MemoryTurn.Role = .user) -> MemoryTurn {
    MemoryTurn(lsn: 7, session: UUID(), role: role, text: text, at: Date(timeIntervalSince1970: 0))
}

private struct FabricatingProposer: ContextProposer {
    func propose(from source: MemoryTurn) -> [ContextProposal] {
        [ContextProposal(kind: .preference, entityName: "Riya", key: "person/riya/usual",
                         label: "usual", value: "espresso", quote: "Riya likes tea", sourceTurn: source)]
    }
}
private struct LeakyProposer: ContextProposer {
    func propose(from source: MemoryTurn) -> [ContextProposal] {
        [ContextProposal(kind: .preference, entityName: "Riya", key: "person/riya/usual",
                         label: "usual", value: "4111 1111 1111 1111",
                         quote: source.text, sourceTurn: source)]
    }
}
private struct AlwaysAdmitGate: ContextProposalGating {
    func admit(_ proposal: ContextProposal, source: MemoryTurn) throws {}
}

@Suite struct ContextProposalTests {
    @Test func riyaHasExactlyTwoGroundedProposals() throws {
        let source = turn("Riya\u{27}s usual is a flat white, and we meet on Fridays")
        let proposals = RuleContextProposer().propose(from: source)
        #expect(proposals.count == 2)
        #expect(proposals.map(\.kind) == [.preference, .routine])
        #expect(proposals.map(\.key) == ["person/riya/usual", "person/riya/meets"])
        #expect(proposals.map(\.value) == ["a flat white", "Fridays"])
        #expect(proposals.map(\.quote) == ["Riya\u{27}s usual is a flat white", "we meet on Fridays"])
        for proposal in proposals {
            #expect(proposal.entityName == "Riya")
            #expect(proposal.sourceTurn == source)
            try ProposalGate().admit(proposal, source: source)
        }
    }

    @Test func personAndExplicitFact() throws {
        let person = turn("Riya is my sister")
        let proposedPerson = try #require(RuleContextProposer().propose(from: person).first)
        #expect(proposedPerson.kind == .person)
        #expect(proposedPerson.entityName == "Riya")
        #expect(proposedPerson.value == "sister")
        #expect(proposedPerson.quote == "Riya is my sister")
        try ProposalGate().admit(proposedPerson, source: person)
        let fact = turn("Remember my blood type is O+")
        let proposedFact = try #require(RuleContextProposer().propose(from: fact).first)
        #expect(proposedFact.kind == .fact)
        #expect(proposedFact.key == PersonalIntent.parse(fact.text)?.key)
        #expect(proposedFact.value == "O+")
        try ProposalGate().admit(proposedFact, source: fact)
    }

    @Test func noUnnamedRoutineOrAssistantExtraction() {
        #expect(RuleContextProposer().propose(from: turn("We meet on Fridays")).isEmpty)
        let named = RuleContextProposer().propose(from: turn("We meet on Fridays with Riya"))
        #expect(named.count == 1)
        #expect(named.first?.key == "person/riya/meets")
        #expect(RuleContextProposer().propose(from: turn("Riya is my sister", role: .assistant)).isEmpty)
    }

    @Test func gateRejectsUntrustedProposals() {
        let source = turn("Riya\u{27}s usual is tea")
        let base = ContextProposal(kind: .preference, entityName: "Riya", key: "person/riya/usual",
                                   label: "usual", value: "tea", quote: source.text, sourceTurn: source)
        func changed(key: String = "person/riya/usual", value: String = "tea",
                     quote: String = "Riya\u{27}s usual is tea", sourceTurn: MemoryTurn? = nil) -> ContextProposal {
            ContextProposal(kind: .preference, entityName: "Riya", key: key, label: "usual",
                            value: value, quote: quote, sourceTurn: sourceTurn ?? source)
        }
        let card = turn("Riya\u{27}s usual is 4111 1111 1111 1111")
        let cases: [(ContextProposal, MemoryTurn)] = [
            (changed(value: "coffee"), source), (changed(quote: "Riya likes tea"), source),
            (changed(sourceTurn: turn(source.text)), source), (changed(key: ""), source),
            (changed(key: String(repeating: "x", count: 513)), source),
            (LeakyProposer().propose(from: card)[0], card),
            (base, turn(source.text, role: .assistant)),
            (changed(sourceTurn: turn(source.text, role: .assistant)),
             turn(source.text, role: .assistant)),
        ]
        for (proposal, cited) in cases {
            #expect(throws: (any Error).self) { try ProposalGate().admit(proposal, source: cited) }
        }
    }

    @Test func counterexamplesProveGate() {
        let fixtures = [turn("Riya\u{27}s usual is tea"), turn("Riya\u{27}s usual is 4111 1111 1111 1111")]
        for proposer in [FabricatingProposer() as any ContextProposer, LeakyProposer()] {
            #expect(!ProposalGateAudit.violations(gate: AlwaysAdmitGate(), proposer: proposer,
                                                  fixtures: fixtures).isEmpty)
            #expect(ProposalGateAudit.violations(gate: ProposalGate(), proposer: proposer,
                                                 fixtures: fixtures).isEmpty)
        }
        #expect(ProposalGateAudit.violations(gate: ProposalGate(), proposer: RuleContextProposer(),
                                             fixtures: fixtures).isEmpty)
    }
}
