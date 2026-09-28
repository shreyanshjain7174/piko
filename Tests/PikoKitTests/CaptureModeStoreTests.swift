import Foundation
import Testing
@testable import PikoKit

@Suite("CaptureModeStore round-trip", .serialized)
struct CaptureModeStoreTests {

    /// Isolate every test on its own in-memory UserDefaults so parallel test
    /// runs don't clobber each other's state. `_setDefaults` is the SPI hook.
    private func fresh() -> UserDefaults {
        let suite = "dev.piko.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        CaptureModeStore._setDefaults(defaults)
        return defaults
    }

    @Test func defaultsAreTapToTalkAndOnDevice() {
        _ = fresh()
        #expect(CaptureModeStore.read() == .tapToTalk)
        #expect(CaptureModeStore.readBackend() == .onDevice)
    }

    @Test func captureModeRoundTrips() {
        _ = fresh()
        CaptureModeStore.write(.auto)
        #expect(CaptureModeStore.read() == .auto)
        CaptureModeStore.write(.tapToTalk)
        #expect(CaptureModeStore.read() == .tapToTalk)
    }

    @Test func backendRoundTrips() {
        _ = fresh()
        CaptureModeStore.writeBackend(.sarvamCloud)
        #expect(CaptureModeStore.readBackend() == .sarvamCloud)
        CaptureModeStore.writeBackend(.onDevice)
        #expect(CaptureModeStore.readBackend() == .onDevice)
    }

    @Test func garbageValueFallsBackToDefault() {
        let defaults = fresh()
        defaults.set("not-a-real-mode", forKey: "dev.piko.captureMode")
        defaults.set("cloud-something", forKey: "dev.piko.transcriberBackend")
        #expect(CaptureModeStore.read() == .tapToTalk)
        #expect(CaptureModeStore.readBackend() == .onDevice)
    }

    @Test func silenceTimeoutIsMuchShorterInAutoMode() {
        // A field that opened but no speech arrived shouldn't leave the mic hot
        // for the same duration as an explicit walk-away hold-to-talk session.
        #expect(CaptureMode.auto.silenceTimeout < CaptureMode.tapToTalk.silenceTimeout)
        #expect(CaptureMode.auto.silenceTimeout <= 3)
        #expect(CaptureMode.tapToTalk.silenceTimeout >= 10)
    }
}
