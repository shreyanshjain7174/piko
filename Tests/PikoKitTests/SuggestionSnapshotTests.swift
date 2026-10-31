import Foundation
import PikoKit
import Testing

@Suite struct SuggestionSnapshotTests {
    private func fact(_ key: String, _ value: String, lsn: Int64) -> MemoryFact {
        MemoryFact(key: key, value: value, lsn: lsn, sourceTurn: lsn - 1,
                   confidence: 1, lastUsed: .now, entityID: nil)
    }

    @Test func buildFiltersSensitiveAndUnusableFacts() {
        let snapshot = SuggestionSnapshot.build(from: [
            fact("usual", "flat white", lsn: 4),
            fact("usual.number", "4111 1111 1111 1111", lsn: 5),
            fact("hint", "your code is 123456", lsn: 6),
            fact(" ", "value", lsn: 7),
            fact("blank", "  ", lsn: 8),
        ])
        #expect(snapshot.version == 1)
        #expect(snapshot.revision == 4)
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries.first?.key == "usual")
        #expect(snapshot.entries.first?.label == "usual")
        #expect(snapshot.entries.first?.value == "flat white")
        #expect(snapshot.entries.first?.factLSN == 4)
        #expect(snapshot.entries.first?.sourceTurn == 3)
    }

    @Test func capAndRevisionAreDeterministic() {
        let facts = (1...70).map { fact("item.\($0)", "value \($0)", lsn: Int64($0)) }
        let snapshot = SuggestionSnapshot.build(from: facts)
        #expect(snapshot.entries.count == 50)
        #expect(snapshot.revision == 70)
        #expect(snapshot == SuggestionSnapshot.build(from: facts.reversed()))
        #expect(snapshot.entries.first?.factLSN == 70)
        #expect(snapshot.entries.last?.factLSN == 21)
    }

    @Test func rebuildingAfterForgetOmitsKey() {
        let kept = fact("home", "Pune", lsn: 2)
        let forgotten = fact("usual", "flat white", lsn: 3)
        #expect(SuggestionSnapshot.build(from: [kept, forgotten]).entries.map(\.key).contains("usual"))
        let rebuilt = SuggestionSnapshot.build(from: [kept])
        #expect(rebuilt.entries.map(\.key) == ["home"])
        #expect(rebuilt.revision == 2)
    }
}
