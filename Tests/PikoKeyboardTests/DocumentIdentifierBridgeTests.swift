#if canImport(UIKit)
import Foundation
import UIKit
import Testing
@testable import PikoKeyboardCore

@MainActor
@Suite struct DocumentIdentifierBridgeTests {
    private final class Provider: NSObject {
        @objc var documentIdentifier: NSUUID?
    }

    @Test func unattachedHostCanReturnNilWithoutTrapping() {
        let provider = Provider()
        #expect(UITextDocumentProxyBox.documentIdentifier(of: provider) == nil)
    }

    @Test func attachedHostRetainsItsActualIdentifier() {
        let provider = Provider()
        let expected = UUID()
        provider.documentIdentifier = expected as NSUUID
        #expect(UITextDocumentProxyBox.documentIdentifier(of: provider) == expected)
    }

    private final class Host: NSObject, UITextDocumentProxy {
        var documentContextBeforeInput: String? = ""
        var documentContextAfterInput: String? { "" }
        var selectedText: String? { nil }
        var documentInputMode: UITextInputMode? { nil }
        let documentIdentifier = UUID()
        var hasText: Bool { !(documentContextBeforeInput ?? "").isEmpty }
        func insertText(_ text: String) { documentContextBeforeInput = (documentContextBeforeInput ?? "") + text }
        func deleteBackward() { documentContextBeforeInput = String((documentContextBeforeInput ?? "").dropLast()) }
        func adjustTextPosition(byCharacterOffset offset: Int) {}
        func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
        func unmarkText() {}
    }

    @Test func providerUsesTheAttachedHostInsteadOfCachingAnEarlyProxy() {
        var current: (any UITextDocumentProxy)?
        let box = UITextDocumentProxyBox(provider: { current })
        #expect(box.documentIdentifier == nil)
        let first = Host()
        current = first
        #expect(box.documentIdentifier == first.documentIdentifier)
        let second = Host()
        current = second
        box.insertText("New document")
        #expect(first.documentContextBeforeInput == "")
        #expect(second.documentContextBeforeInput == "New document")
        #expect(box.documentIdentifier == second.documentIdentifier)
    }

    @Test func captureReadinessWaitsForAnAttachedDocument() {
        var current: (any UITextDocumentProxy)?
        let controller = TextInsertionController(proxyProvider: { current })
        #expect(!controller.hostIsReady)
        current = Host()
        #expect(controller.hostIsReady)
        controller.beginCapture()
        controller.apply(.init(sessionEpoch: 1, sequence: 1, text: "Hello", stablePrefix: 0))
        #expect(current?.documentContextBeforeInput == "Hello")
    }
}
#endif
