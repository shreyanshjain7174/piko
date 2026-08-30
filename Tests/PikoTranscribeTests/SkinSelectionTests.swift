#if os(iOS)
import Testing
import PikoKit
@testable import PikoCaptureCore

@Suite("Skin selection")
struct SkinSelectionTests {
    @Test("apply writes skin through channel.writeState when no prior state exists")
    func appliesSkinWithNoPriorState() {
        let channel = MockSessionChannel()

        SkinSelection.apply(.hero, via: channel)

        #expect(channel.readState()?.skin == .hero)
    }

    @Test("apply only touches skin, preserving the rest of the existing state")
    func appliesSkinPreservingOtherFields() {
        let channel = MockSessionChannel()
        channel.writeState(SessionState(phase: .armed, skin: .cute, profile: .code))

        SkinSelection.apply(.sparkle, via: channel)

        let state = channel.readState()
        #expect(state?.skin == .sparkle)
        #expect(state?.phase == .armed)
        #expect(state?.profile == .code)
    }
}
#endif
