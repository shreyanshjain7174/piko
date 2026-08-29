#if os(iOS)
import AVFAudio
import Foundation

/// Real `InterruptionSource` conformer, merging three independent OS notification streams
/// (interruption, route change, low power mode) into one `events` stream. Second and last
/// file in this package touching `AVFAudio` — see `SessionCoordinator.swift` for the first.
public final class AVAudioSessionInterruptionSource: InterruptionSource, @unchecked Sendable {

    public init() {}

    public var events: AsyncStream<InterruptionEvent> {
        AsyncStream { continuation in
            let interruptionTask = Task {
                for await note in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                    guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { continue }
                    switch type {
                    case .began:
                        continuation.yield(.began)
                    case .ended:
                        let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
                        continuation.yield(.ended(shouldResume: shouldResume))
                    @unknown default:
                        continue
                    }
                }
            }

            let routeChangeTask = Task {
                for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                    continuation.yield(.routeChanged)
                }
            }

            let lowPowerTask = Task {
                for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                    continuation.yield(.lowPowerModeChanged(enabled: ProcessInfo.processInfo.isLowPowerModeEnabled))
                }
            }

            continuation.onTermination = { _ in
                interruptionTask.cancel()
                routeChangeTask.cancel()
                lowPowerTask.cancel()
            }
        }
    }
}
#endif
