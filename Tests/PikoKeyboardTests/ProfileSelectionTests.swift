import Foundation
import PikoKit
import Testing
@testable import PikoKeyboardCore

@Suite("Profile selection through SessionChannel")
struct ProfileSelectionTests {

    @Test("selecting agent writes SessionState.profile while preserving phase, heartbeat and skin")
    func selectAgentPreservesOtherFields() throws {
        let channel = MockSessionChannel()
        let heartbeat = Date(timeIntervalSinceNow: -1)
        channel.writeState(SessionState(
            phase: .armed,
            heartbeat: heartbeat,
            skin: .hero,
            profile: .message))

        ProfileSelectionController(channel: channel).select(.agent)

        let state = try #require(channel.readState())
        #expect(state.profile == .agent)
        #expect(state.phase == .armed)
        #expect(state.heartbeat == heartbeat)
        #expect(state.skin == .hero)
    }

    @Test("select does nothing when the channel has no session state")
    func selectDoesNothingWithoutState() {
        let channel = MockSessionChannel()
        ProfileSelectionController(channel: channel).select(.agent)
        #expect(channel.readState() == nil)
    }

    @Test("keyboard picker is generated from Profile.allCases so all five profiles appear")
    func pickerUsesAllCasesIncludingAgent() {
        let profiles = ProfileSelectionController.pickerProfiles
        #expect(profiles == Array(Profile.allCases))
        #expect(profiles.count == 5)
        #expect(profiles.contains(.agent))
    }
}
