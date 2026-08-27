import Testing
import Foundation
@testable import PikoKit
@testable import PikoBrain

@Test("session goes stale without a heartbeat")
func staleSession() {
    let fresh = SessionState(phase: .armed, heartbeat: .now)
    #expect(fresh.isLive())

    let stale = SessionState(phase: .armed, heartbeat: Date(timeIntervalSinceNow: -30))
    #expect(!stale.isLive())

    let idle = SessionState(phase: .idle, heartbeat: .now)
    #expect(!idle.isLive(), "idle is never live regardless of heartbeat")
}

@Test("drafts survive a round trip")
func draftCoding() throws {
    let draft = CaptureDraft(sequence: 7, text: "hey can we push it", stablePrefix: 12)
    let data = try JSONEncoder().encode(draft)
    let back = try JSONDecoder().decode(CaptureDraft.self, from: data)
    #expect(back == draft)
}

@Test("commands and recalls route away from write")
func routing() async {
    let brain = SystemBrain()
    #expect(await brain.route("remind me to pay the invoice") == .command)
    #expect(await brain.route("what did I say about pricing") == .recall)
    #expect(await brain.route("hey can we push it to thursday") == .write)
}

@Test("mock cleanup strips fillers and punctuates")
func mockRewrite() async throws {
    let brain = MockBrain()
    let out = try await brain.rewrite("um hey can we push it to thursday",
                                      profile: .message, lexicon: [], examples: [])
    #expect(out == "Hey can we push it to thursday.")
}
