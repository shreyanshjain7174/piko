import PikoKit
#if canImport(UIKit)
import UIKit
#endif

/// Host-field mutation surface. Production wraps `UITextDocumentProxy`; tests use `MockTextDocumentProxy`.
/// Isolated to the main actor because `UITextDocumentProxy` is UIKit and not Sendable.
@MainActor
protocol TextProxy: AnyObject {
    func insertText(_ text: String)
    func deleteBackward()
}

#if canImport(UIKit)
/// Weak box so the controller does not retain the keyboard's `textDocumentProxy`.
@MainActor
final class UITextDocumentProxyBox: TextProxy {
    private weak var proxy: (any UITextDocumentProxy)?

    init(_ proxy: any UITextDocumentProxy) {
        self.proxy = proxy
    }

    func insertText(_ text: String) { proxy?.insertText(text) }
    func deleteBackward() { proxy?.deleteBackward() }
}
#endif

/// StablePrefix-aware streaming insertion. Only the unstable tail is rewritten.
@MainActor
final class TextInsertionController {
    private let proxy: any TextProxy
    private(set) var insertedChars: Int = 0
    private(set) var lastApplied: CaptureDraft?

    init(proxy: any TextProxy) {
        self.proxy = proxy
    }

#if canImport(UIKit)
    convenience init(proxy: any UITextDocumentProxy) {
        self.init(proxy: UITextDocumentProxyBox(proxy))
    }
#endif

    func apply(_ draft: CaptureDraft) {
        guard draft.isNewer(than: lastApplied) else { return }

        // New epoch: leftover insertion from the previous session is not this draft.
        let alreadyStable: Int
        if lastApplied.map({ $0.sessionEpoch != draft.sessionEpoch }) == true {
            alreadyStable = 0
        } else {
            alreadyStable = lastApplied.map { min($0.stablePrefix, insertedChars) } ?? 0
        }

        let toDelete = insertedChars - alreadyStable
        for _ in 0..<toDelete { proxy.deleteBackward() }

        let newText = String(draft.text.dropFirst(alreadyStable))
        proxy.insertText(newText)

        insertedChars = draft.text.count
        lastApplied = draft
    }

    func commit(_ result: CaptureResult) {
        for _ in 0..<insertedChars { proxy.deleteBackward() }
        proxy.insertText(result.shipped)
        insertedChars = 0
        lastApplied = nil
    }

    func reset() {
        insertedChars = 0
        lastApplied = nil
    }
}
