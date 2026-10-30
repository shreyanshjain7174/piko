import Foundation
import PikoKit
import Testing
@testable import PikoBrain

@Suite struct PersonalIntentTests {
    @Test func explicitFactsAndQuestions() {
        #expect(PersonalIntent.parse("Remember my sister is Riya.")
                == .remember(key: "my/sister", subject: "sister", value: "Riya"))
        #expect(PersonalIntent.parse("Piko, remember that my blood type is O+!")
                == .remember(key: "my/blood-type", subject: "blood type", value: "O+"))
        #expect(PersonalIntent.parse("Piko forget my Sister?")
                == .forget(key: "my/sister", subject: "sister"))
        #expect(PersonalIntent.parse("Who is my SISTER?")
                == .ask(key: "my/sister", subject: "sister"))
        #expect(PersonalIntent.parse("What's my blood type?")
                == .ask(key: "my/blood-type", subject: "blood type"))
        #expect(PersonalIntent.parse("What is my blood type?!")
                == .ask(key: "my/blood-type", subject: "blood type"))
    }

    @Test func noStealingOtherTasksOrSpeculativeFacts() {
        for request in [
            "remind me to call my sister", "remember to buy milk", "please remember my sister is Riya",
            "my sister is Riya", "what did I say about my sister", "show me my notes",
            "what is my calendar?", "who is my reminder?", "what's my journal?",
            "what is my schedule?", "what is my note?", "remember my calendar is busy",
            "remember my sister is", "forget my sister's birthday", "Pikomon remember my sister is Riya",
            "Remember my sister is Riya and remind me to call her",
            "Remember my sister is Riya and my brother is Anil",
            String(repeating: "a", count: 513),
            String(repeating: "!", count: 513) + "Remember my sister is Riya",
        ] {
            #expect(PersonalIntent.parse(request) == nil, "Unexpected personal intent: \(request)")
        }
    }

    @Test func answersUseOnlySavedFacts() {
        let fact = MemoryFact(key: "my/sister", value: "Riya", lsn: 1, sourceTurn: nil,
                              confidence: 1, lastUsed: .now, entityID: nil)
        #expect(PersonalAnswer.reply(subject: "sister", fact: fact) == "Your sister is Riya.")
        #expect(PersonalAnswer.reply(subject: "blood type", fact: nil)
                == "I don't know your blood type yet.")
    }
}
