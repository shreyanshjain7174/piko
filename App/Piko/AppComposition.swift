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

    let session: SessionCoordinator

    private init() {
        let channel = DarwinChannel()!
        session = SessionCoordinator(channel: channel, interruptions: NullInterruptionSource(), isForeground: { UIApplication.shared.applicationState == .active })
    }
}
