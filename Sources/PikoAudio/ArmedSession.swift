import AVFAudio
import Foundation
import PikoKit

/// AVFAudio does not mark `AVAudioPCMBuffer` Sendable. The engine tap yields each
/// buffer across the render thread via `AsyncStream`; callers treat it as an
/// immutable snapshot and must not mutate it after yield.
extension AVAudioPCMBuffer: @unchecked Sendable {}

/// Owns the microphone. The one object allowed to touch AVAudioSession.
///
/// `arm()` must be called while the app is on screen — CONSTRAINTS C2 makes background
/// activation impossible, and no accessory, intent or notification changes that. Once armed,
/// the session survives backgrounding via the `audio` background mode (C3).
public protocol ArmedSession: Sendable {
    var phase: AsyncStream<SessionPhase> { get }
    /// PCM buffers from the engine tap. Idle until `startCapture()`; finished on `disarm()`.
    var buffers: AsyncStream<AVAudioPCMBuffer> { get }
    /// Foreground only. Throws `PikoError.notForeground` otherwise.
    func arm() async throws
    func disarm() async
    /// Legal only while armed. Throws `PikoError.notArmed` otherwise.
    func startCapture() async throws
    func stopCapture() async
}

// TODO(spike 2): AVAudioEngine implementation.
// Must handle, and be tested against: incoming call, route change mid-sentence, another app
// taking the session, low power mode, outright termination. Each is a re-arm prompt within one
// second, never a crash and never a silent dead mic.
