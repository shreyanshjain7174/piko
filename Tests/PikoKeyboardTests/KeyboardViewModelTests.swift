import Foundation
import PikoKit
import Testing

/// Mic-button signal rules, extracted from the keyboard's remote-control logic so they
/// can be tested without a `UIInputViewController`. Production wiring in Plan 04-01 Task 3
/// duplicates this switch against a live `SessionChannel`.
final class KeyboardViewModel {
    var channel: SessionChannel
    var sessionState: SessionState?

    init(channel: SessionChannel) { self.channel = channel }

    func micButtonAction() {
        guard let state = sessionState, state.isLive() else { return }
        switch state.phase {
        case .armed: channel.post(.captureStart)
        case .capturing: channel.post(.captureStop)
        default: break
        }
    }
}

@Suite("KeyboardViewModel mic button signals")
struct KeyboardViewModelTests {

    @Test("posting .captureStart when state.phase == .armed succeeds")
    func postsCaptureStartWhenArmed() {
        let mock = MockSessionChannel()
        let vm = KeyboardViewModel(channel: mock)
        vm.sessionState = SessionState(phase: .armed, heartbeat: .now)

        vm.micButtonAction()

        #expect(mock.postedSignals == [.captureStart])
    }

    @Test("posting .captureStop when state.phase == .capturing succeeds")
    func postsCaptureStopWhenCapturing() {
        let mock = MockSessionChannel()
        let vm = KeyboardViewModel(channel: mock)
        vm.sessionState = SessionState(phase: .capturing, heartbeat: .now)

        vm.micButtonAction()

        #expect(mock.postedSignals == [.captureStop])
    }

    @Test("micButtonAction does NOT post when state is nil")
    func doesNotPostWhenStateIsNil() {
        let mock = MockSessionChannel()
        let vm = KeyboardViewModel(channel: mock)
        vm.sessionState = nil

        vm.micButtonAction()

        #expect(mock.postedSignals.isEmpty)
    }

    @Test("micButtonAction does NOT post when state.isLive() is false")
    func doesNotPostWhenHeartbeatIsStale() {
        let mock = MockSessionChannel()
        let vm = KeyboardViewModel(channel: mock)
        vm.sessionState = SessionState(
            phase: .armed,
            heartbeat: Date(timeIntervalSinceNow: -30))

        vm.micButtonAction()

        #expect(mock.postedSignals.isEmpty)
    }
}
