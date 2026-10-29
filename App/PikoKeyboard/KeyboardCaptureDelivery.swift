import Foundation
import PikoKit

struct KeyboardCaptureDelivery {
    var isVisible = false
    private(set) var isActive = false
    private var baselineEpoch = 0
    private var baselineResultID: UUID?

    mutating func begin(after draft: CaptureDraft?, result: CaptureResult?) {
        baselineEpoch = draft?.sessionEpoch ?? 0
        baselineResultID = result?.id
        isActive = true
    }

    func accepts(_ draft: CaptureDraft) -> Bool {
        isVisible && isActive && draft.sessionEpoch > baselineEpoch
    }

    func accepts(_ result: CaptureResult) -> Bool {
        isVisible && isActive && result.id != baselineResultID
    }

    mutating func finish() {
        isActive = false
    }
}
