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
    private(set) var lastCommitted: CaptureResult?
    private(set) var committedChars: Int = 0

    var canRevertToRaw: Bool {
        guard let lastCommitted else { return false }
        return lastCommitted.raw != lastCommitted.shipped
    }

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
        lastCommitted = nil
        committedChars = 0

        // Incoming draft.stablePrefix is the transcriber's current freeze point.
        // Using lastApplied.stablePrefix would full-replace whenever the previous
        // draft had not yet frozen any prefix (research Pattern 1 bug).
        // New epoch: leftover insertion from the previous session is not this draft.
        let alreadyStable: Int
        if lastApplied.map({ $0.sessionEpoch != draft.sessionEpoch }) == true {
            alreadyStable = 0
        } else {
            alreadyStable = min(draft.stablePrefix, insertedChars)
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
        committedChars = result.shipped.count
        lastCommitted = result
    }

    @discardableResult
    func revertToRaw() -> Bool {
        guard let result = lastCommitted, result.raw != result.shipped else { return false }
        for _ in 0..<committedChars { proxy.deleteBackward() }
        proxy.insertText(result.raw)
        committedChars = result.raw.count
        lastCommitted = nil
        return true
    }

    func reset() {
        insertedChars = 0
        lastApplied = nil
        lastCommitted = nil
        committedChars = 0
    }
}
