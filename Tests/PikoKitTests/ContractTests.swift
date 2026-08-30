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
    let draft = CaptureDraft(sessionEpoch: 3, sequence: 7, text: "hey can we push it", stablePrefix: 12)
    let data = try JSONEncoder().encode(draft)
    let back = try JSONDecoder().decode(CaptureDraft.self, from: data)
    #expect(back == draft)
}

@Test("session state survives a round trip")
func sessionStateCoding() throws {
    let state = SessionState(phase: .capturing, heartbeat: .now, skin: .hero, profile: .code)
    let data = try JSONEncoder().encode(state)
    let back = try JSONDecoder().decode(SessionState.self, from: data)
    #expect(back == state)
}

@Test("capture results, including nested timings, survive a round trip")
func captureResultCoding() throws {
    let result = CaptureResult(raw: "um so basically", shipped: "So.", route: .write,
                                profile: .note, timings: .init(firstWordMS: 120, transcribeMS: 300, brainMS: 80))
    let data = try JSONEncoder().encode(result)
    let back = try JSONDecoder().decode(CaptureResult.self, from: data)
    #expect(back == result)
}

@Test("edit pairs survive a round trip")
func editPairCoding() throws {
    let pair = EditPair(raw: "um hey", shipped: "Hey.", final: "Hey!", profile: .message)
    let data = try JSONEncoder().encode(pair)
    let back = try JSONDecoder().decode(EditPair.self, from: data)
    #expect(back == pair)
}

@Test("app group and signal are singly defined")
func appGroupAndSignalAreSinglyDefined() {
    #expect(!AppGroup.identifier.isEmpty)
    #expect(Signal.allCases.count == 5)
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

@Test("Profile.allCases includes agent and has five cases")
func profileAllCasesIncludesAgent() {
    #expect(Profile.allCases.count == 5)
    #expect(Profile.allCases.map(\.rawValue).contains("agent"))
}

@Test("Profile.agent round-trips through JSON as the raw value agent")
func profileAgentJSONRoundTrip() throws {
    let encoded = try JSONEncoder().encode(Profile(rawValue: "agent"))
    #expect(String(data: encoded, encoding: .utf8) == "\"agent\"")
    let decoded = try JSONDecoder().decode(Profile.self, from: encoded)
    #expect(decoded.rawValue == "agent")
}

@Test("SessionState carrying profile agent survives encode/decode")
func sessionStateWithAgentRoundTrip() throws {
    let agent = try #require(Profile(rawValue: "agent"))
    let state = SessionState(phase: .armed, heartbeat: .now, skin: .sparkle, profile: agent)
    let data = try JSONEncoder().encode(state)
    let back = try JSONDecoder().decode(SessionState.self, from: data)
    #expect(back == state)
    #expect(back.profile.rawValue == "agent")
}

@Test("every Profile case has a non-empty styleHint")
func everyProfileHasNonEmptyStyleHint() {
    for profile in Profile.allCases {
        #expect(!profile.styleHint.isEmpty, "\(profile.rawValue) styleHint must not be empty")
    }
}
