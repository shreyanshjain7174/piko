import Foundation
import PikoKit
import Testing
@testable import PikoKeyboardCore

@Suite struct KeyboardCaptureDeliveryTests {
    @Test func hideAndReappearRetainsCaptureButNeverDeliversWhileHidden() {
        var delivery = KeyboardCaptureDelivery()
        delivery.isVisible = true
        delivery.begin(after: nil, result: nil)
        let draft = CaptureDraft(sessionEpoch: 1, sequence: 1, text: "Hello", stablePrefix: 0)
        let result = CaptureResult(raw: "Hello", shipped: "Hello.")
        #expect(delivery.accepts(draft))
        delivery.isVisible = false
        #expect(delivery.isActive)
        #expect(!delivery.accepts(draft))
        #expect(!delivery.accepts(result))
        delivery.isVisible = true
        #expect(delivery.accepts(draft))
        #expect(delivery.accepts(result))
    }

    @Test func previousPayloadsAreNotMistakenForTheNewCapture() {
        var delivery = KeyboardCaptureDelivery()
        delivery.isVisible = true
        let oldDraft = CaptureDraft(sessionEpoch: 4, sequence: 10, text: "Old", stablePrefix: 3)
        let oldResult = CaptureResult(raw: "Old", shipped: "Old.")
        delivery.begin(after: oldDraft, result: oldResult)
        #expect(!delivery.accepts(oldDraft))
        #expect(!delivery.accepts(oldResult))
        #expect(delivery.accepts(CaptureDraft(sessionEpoch: 5, sequence: 1, text: "New", stablePrefix: 0)))
        #expect(delivery.accepts(CaptureResult(raw: "New", shipped: "New.")))
    }

    @Test func finishingStopsDeliveryUntilTheUserStartsAgain() {
        var delivery = KeyboardCaptureDelivery()
        delivery.isVisible = true
        delivery.begin(after: nil, result: nil)
        let result = CaptureResult(raw: "Text", shipped: "Text.")
        delivery.finish()
        #expect(!delivery.isActive)
        #expect(!delivery.accepts(result))
        delivery.begin(after: nil, result: result)
        #expect(!delivery.accepts(result))
        #expect(delivery.accepts(CaptureResult(raw: "Next", shipped: "Next.")))
    }
}
