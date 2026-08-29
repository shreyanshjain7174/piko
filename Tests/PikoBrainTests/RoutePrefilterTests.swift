import Foundation
import Testing
import PikoKit
@testable import PikoBrain

@Suite
struct RoutePrefilterTests {

    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func routeNeverInvokesInference() async {
        let counter = CallCounter()
        let brain = SystemBrain(inference: { _, _ in
            counter.increment()
            return ""
        })

        let phrases: [(String, Route)] = [
            ("hello there how are you", .write),
            ("um I think we should ship friday", .write),
            ("please send this to the team", .write),
            ("the meeting is at three", .write),
            ("remind me to call alex", .command),
            ("set a timer for ten minutes", .command),
            ("add to the grocery list", .command),
            ("schedule lunch with sam", .command),
            ("create a reminder", .command),
            ("what did i say about pricing", .recall),
            ("when did i last talk to jamie", .recall),
            ("search for the deck", .recall),
            ("show me my notes", .recall),
            ("find where we parked", .recall),
        ]

        for (phrase, expected) in phrases {
            let route = await brain.route(phrase)
            #expect(route == expected, "phrase: \(phrase)")
        }
        #expect(counter.count == 0)
    }

    @Test func recallBeatsOverlappingCommandPrefix() async {
        let route = await SystemBrain().route("remind me what I said about pricing")
        #expect(route == .recall)
        #expect(SystemBrain.prefilterRoute("remind me what i said about pricing") == .recall)
    }

    @Test func leadingWhitespaceAndMixedCasingStillRoute() async {
        let brain = SystemBrain()
        #expect(await brain.route("  REMIND ME to pack  ") == .command)
        #expect(await brain.route("\nWhat Did I say about this\t") == .recall)
        #expect(await brain.route("  Hello World  ") == .write)
    }

    @Test func emptyOrWhitespaceRoutesToWrite() async {
        let brain = SystemBrain()
        #expect(await brain.route("") == .write)
        #expect(await brain.route("   \n\t  ") == .write)
        #expect(SystemBrain.prefilterRoute("") == .write)
    }
}
