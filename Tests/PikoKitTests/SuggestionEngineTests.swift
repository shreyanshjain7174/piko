import Testing
import Foundation
import PikoKit

@Suite("Suggestion engine — suggestions, never solutions")
struct SuggestionEngineTests {

    private func entity(_ name: String, kind: RememberedEntity.Kind = .topic,
                        hits: Int = 3) -> RememberedEntity {
        RememberedEntity(name: name, kind: kind, hitCount: hits)
    }

    @Test("a recurring topic earns an evening line with the entity in it")
    func eveningSuggestion() {
        let suggestion = SuggestionEngine.suggestion(for: [entity("Interstellar")], hour: 20)
        #expect(suggestion != nil)
        #expect(suggestion!.text.contains("Interstellar"))
    }

    @Test("morning gets the pick-it-back-up framing")
    func morningSuggestion() {
        let suggestion = SuggestionEngine.suggestion(for: [entity("Lisbon", hits: 2)], hour: 8)
        #expect(suggestion?.text.contains("pick it back up") == true)
    }

    @Test("people get a soft say-hi nudge regardless of hour")
    func personSuggestion() {
        let suggestion = SuggestionEngine.suggestion(for: [entity("Mom", kind: .person)], hour: 13)
        #expect(suggestion?.text.contains("Mom") == true)
    }

    @Test("single mentions stay quiet")
    func singleMentionIsSilent() {
        #expect(SuggestionEngine.suggestion(for: [entity("Interstellar", hits: 1)], hour: 20) == nil)
    }

    @Test("no entities, no suggestion")
    func emptyIsSilent() {
        #expect(SuggestionEngine.suggestion(for: [], hour: 20) == nil)
    }

    @Test("the style rule: never an exclamation mark")
    func neverShouts() {
        for hour in 0..<24 {
            if let suggestion = SuggestionEngine.suggestion(for: [entity("Thing", hits: 5)], hour: hour) {
                #expect(!suggestion.text.contains("!"))
            }
        }
    }
}
