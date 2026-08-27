import UIKit
import PikoKit
import PikoBridge

/// A remote control and a text sink. Nothing else lives here.
///
/// Hard rules (CONSTRAINTS C1, C4):
/// - No microphone. The runtime refuses; do not try.
/// - No model, no database, no audio buffers. ~60 MB and jetsam does not warn you.
/// - `RequestsOpenAccess` must be true in Info.plist for the App Group to be writable.
final class KeyboardViewController: UIInputViewController {

    private var channel: DarwinChannel?
    private var lastSequence = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        channel = DarwinChannel()
        Task { await observe() }
    }

    private func observe() async {
        guard let channel else { return }
        for await signal in channel.signals {
            switch signal {
            case .draftUpdated: applyDraft()
            case .resultReady:  applyResult()
            default: break
            }
        }
    }

    /// Insert only what is new. Ignore anything older than what we already typed, or the field
    /// thrashes — that is the failure mode spike 3 exists to prevent.
    private func applyDraft() {
        guard let draft = channel?.readDraft(), draft.sequence > lastSequence else { return }
        lastSequence = draft.sequence
        // TODO: diff against what we already inserted, deleteBackward the unstable tail,
        // insertText the new tail.
    }

    private func applyResult() {
        guard let result = channel?.readResult() else { return }
        // TODO: replace the streamed draft with result.shipped, then reset lastSequence.
        _ = result
    }

    private func startCapture() { channel?.post(.captureStart) }
    private func stopCapture()  { channel?.post(.captureStop) }
}
