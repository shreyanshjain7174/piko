import Foundation
import PikoKit
#if canImport(UIKit)
import UIKit
#endif

/// Host-field mutation surface. Production wraps `UITextDocumentProxy`; tests use `MockTextDocumentProxy`.
/// Isolated to the main actor because `UITextDocumentProxy` is UIKit and not Sendable.
@MainActor
protocol TextProxy: AnyObject {
    var documentContextBeforeInput: String? { get }
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

    var documentContextBeforeInput: String? { proxy?.documentContextBeforeInput }

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
    private var isInvalidated = false
    private var acceptsResults = true
    private var lastHandledResultID: UUID?
    private var terminalSessionEpoch: Int?

    var canRevertToRaw: Bool {
        guard let lastCommitted else { return false }
        return lastCommitted.raw != lastCommitted.shipped
    }

    /// True when the trailing text in the field still matches what we last inserted —
    /// i.e. the most recent change came from our own `apply(_:)` / `commit(_:)`, not
    /// a user keystroke. Used by the auto-capture textDidChange guard to avoid
    /// killing capture on our own streaming inserts.
    var currentContextIsOurs: Bool {
        if insertedChars > 0, let last = lastApplied?.text {
            return proxy.documentContextBeforeInput?.hasSuffix(last) ?? false
        }
        if committedChars > 0, let last = lastCommitted?.shipped {
            return proxy.documentContextBeforeInput?.hasSuffix(last) ?? false
        }
        // Nothing outstanding to protect: any change is by definition not ours.
        return false
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
        if isInvalidated {
            guard let terminalSessionEpoch, draft.sessionEpoch > terminalSessionEpoch else { return }
            isInvalidated = false
        }
        guard terminalSessionEpoch.map({ draft.sessionEpoch > $0 }) ?? true else { return }
        guard draft.isNewer(than: lastApplied) else { return }

        guard canReplace(lastApplied?.text) else {
            invalidateCapture()
            return
        }

        lastCommitted = nil
        committedChars = 0
        acceptsResults = true
        lastHandledResultID = nil

        // Incoming draft.stablePrefix is the transcriber's current freeze point.
        // Using lastApplied.stablePrefix would full-replace whenever the previous
        // draft had not yet frozen any prefix (research Pattern 1 bug).
        // New epoch: leftover insertion from the previous session is not this draft.
        let alreadyStable: Int
        if let previous = lastApplied, previous.sessionEpoch == draft.sessionEpoch {
            let commonPrefix = Self.commonPrefixLength(previous.text, draft.text)
            alreadyStable = min(draft.stablePrefix, insertedChars, commonPrefix)
        } else {
            alreadyStable = 0
        }

        let toDelete = insertedChars - alreadyStable
        for _ in 0..<toDelete { proxy.deleteBackward() }

        let newText = String(draft.text.dropFirst(alreadyStable))
        proxy.insertText(newText)

        insertedChars = draft.text.count
        lastApplied = draft
    }

    func commit(_ result: CaptureResult) {
        guard acceptsResults, !isInvalidated, result.id != lastHandledResultID else { return }
        lastHandledResultID = result.id
        guard canReplace(lastApplied?.text) else {
            invalidateCapture()
            return
        }
        terminalSessionEpoch = lastApplied?.sessionEpoch
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
        guard canReplace(result.shipped) else {
            invalidateCapture()
            return false
        }
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
        isInvalidated = false
        acceptsResults = false
    }

    private func invalidateCapture() {
        isInvalidated = true
        acceptsResults = false
        if let activeEpoch = lastApplied?.sessionEpoch {
            terminalSessionEpoch = activeEpoch
        }
        insertedChars = 0
        lastApplied = nil
        lastCommitted = nil
        committedChars = 0
    }

    private func canReplace(_ expectedText: String?) -> Bool {
        guard let expectedText else { return insertedChars == 0 }
        guard let context = proxy.documentContextBeforeInput else { return false }
        return context.hasSuffix(expectedText)
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix { pair in pair.0 == pair.1 }.count
    }
}
