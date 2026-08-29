import Foundation
import PikoAudio
import PikoBridge
import PikoKit
import UIKit

/// The one place `PikoBridge` and `PikoAudio` meet. Sole construction site of a real
/// `DarwinChannel` and `SessionCoordinator`.
@MainActor
final class AppComposition {
    static let shared = AppComposition()

    let channel: any SessionChannel
    let session: SessionCoordinator

    private init() {
        let channel = DarwinChannel()!
        self.channel = channel
        session = SessionCoordinator(channel: channel, interruptions: AVAudioSessionInterruptionSource(), isForeground: { UIApplication.shared.applicationState == .active })
    }
}
