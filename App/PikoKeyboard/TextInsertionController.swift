import Foundation
import PikoKit
#if DEBUG
import OSLog
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Host-field mutation surface. Production wraps `UITextDocumentProxy`; tests use `MockTextDocumentProxy`.
/// Isolated to the main actor because `UITextDocumentProxy` is UIKit and not Sendable.
@MainActor
protocol TextProxy: AnyObject {
    var documentContextBeforeInput: String? { get }
    var documentIdentifier: UUID? { get }
    func insertText(_ text: String)
    func deleteBackward()
}

#if canImport(UIKit)
/// Fetches the current host interface; the provider holds its controller weakly.
@MainActor
final class UITextDocumentProxyBox: TextProxy {
    private let provider: @MainActor () -> (any UITextDocumentProxy)?
    private var proxy: (any UITextDocumentProxy)? { provider() }

    init(provider: @escaping @MainActor () -> (any UITextDocumentProxy)?) {
        self.provider = provider
    }

    var documentContextBeforeInput: String? { proxy?.documentContextBeforeInput }
    var documentIdentifier: UUID? {
        guard let proxy else { return nil }
        return Self.documentIdentifier(of: proxy)
    }

    static func documentIdentifier(of object: any NSObjectProtocol) -> UUID? {
        let getter = #selector(getter: UITextDocumentProxy.documentIdentifier)
        // UIKit can return nil before host attachment despite the nonnull SDK declaration.
        guard object.responds(to: getter),
              let value = object.perform(getter)?.takeUnretainedValue() as? NSUUID else { return nil }
        return value as UUID
    }

    func insertText(_ text: String) { proxy?.insertText(text) }
    func deleteBackward() { proxy?.deleteBackward() }
}
#endif

/// Streaming insertion. Only characters that changed since the last draft are rewritten.
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
    private var captureDocumentIdentifier: UUID?
    private var observedContext: String?
    /// What this capture actually typed for `lastApplied`, including `separator`.
    private var lastAppliedText: String?
    /// A space when the capture starts right after a word, so consecutive captures don't fuse.
    private var separator = ""

    var canRevertToRaw: Bool {
        guard let lastCommitted else { return false }
        return lastCommitted.raw != lastCommitted.shipped
    }

    init(proxy: any TextProxy) {
        self.proxy = proxy
        captureDocumentIdentifier = proxy.documentIdentifier
    }

#if canImport(UIKit)
    convenience init(proxy: any UITextDocumentProxy) {
        self.init(proxy: UITextDocumentProxyBox(provider: { [weak proxy] in proxy }))
    }

    convenience init(proxyProvider: @escaping @MainActor () -> (any UITextDocumentProxy)?) {
        self.init(proxy: UITextDocumentProxyBox(provider: proxyProvider))
    }
#endif

    func apply(_ draft: CaptureDraft) {
        if isInvalidated {
            guard let terminalSessionEpoch, draft.sessionEpoch > terminalSessionEpoch else { return }
            isInvalidated = false
        }
        guard terminalSessionEpoch.map({ draft.sessionEpoch > $0 }) ?? true else { return }
        guard draft.isNewer(than: lastApplied) else { return }

        guard canReplace(lastAppliedText) else {
            invalidateCapture()
            return
        }

        lastCommitted = nil
        committedChars = 0
        acceptsResults = true
        lastHandledResultID = nil

        // New epoch: leftover insertion from the previous session is not this draft.
        let text = separated(draft.text)
        let alreadyStable: Int
        if let previous = lastApplied, let previousText = lastAppliedText,
           previous.sessionEpoch == draft.sessionEpoch {
            // Only rewrite characters that actually changed. Hosts can drop rapid deleteBackward
            // bursts, so retyping an unchanged volatile tail duplicated text in the field.
            alreadyStable = min(insertedChars, Self.commonPrefixLength(previousText, text))
        } else {
            alreadyStable = 0
        }

        let toDelete = insertedChars - alreadyStable
        for _ in 0..<toDelete { proxy.deleteBackward() }

        let newText = String(text.dropFirst(alreadyStable))
        proxy.insertText(newText)

        insertedChars = text.count
        lastApplied = draft
        lastAppliedText = text
        observedContext = proxy.documentContextBeforeInput
    }

    func commit(_ result: CaptureResult) {
        guard acceptsResults, !isInvalidated, result.id != lastHandledResultID else {
            #if DEBUG
            Logger(subsystem: "dev.shreyansh.Piko.benchmark", category: "insertion")
                .notice("PIKO_COMMIT_REJECTED accepts=\(self.acceptsResults, privacy: .public) invalidated=\(self.isInvalidated, privacy: .public)")
            #endif
            return
        }
        lastHandledResultID = result.id
        guard canReplace(lastAppliedText) else {
            #if DEBUG
            Logger(subsystem: "dev.shreyansh.Piko.benchmark", category: "insertion")
                .notice("PIKO_COMMIT_BLOCKED inserted=\(self.insertedChars, privacy: .public) context_nil=\(self.proxy.documentContextBeforeInput == nil, privacy: .public)")
            #endif
            invalidateCapture()
            return
        }
        terminalSessionEpoch = lastApplied?.sessionEpoch
        for _ in 0..<insertedChars { proxy.deleteBackward() }
        let shipped = separated(result.shipped)
        proxy.insertText(shipped)
        insertedChars = 0
        lastApplied = nil
        lastAppliedText = nil
        committedChars = shipped.count
        lastCommitted = result
        observedContext = proxy.documentContextBeforeInput
    }

    @discardableResult
    func revertToRaw() -> Bool {
        guard let result = lastCommitted, result.raw != result.shipped else { return false }
        guard canReplace(separated(result.shipped)) else {
            invalidateCapture()
            return false
        }
        for _ in 0..<committedChars { proxy.deleteBackward() }
        let raw = separated(result.raw)
        proxy.insertText(raw)
        committedChars = raw.count
        lastCommitted = nil
        observedContext = proxy.documentContextBeforeInput
        return true
    }

    func reset() {
        insertedChars = 0
        lastApplied = nil
        lastAppliedText = nil
        separator = ""
        lastCommitted = nil
        committedChars = 0
        isInvalidated = false
        acceptsResults = false
        observedContext = nil
    }

    func beginCapture() {
        reset()
        observedContext = proxy.documentContextBeforeInput
        captureDocumentIdentifier = proxy.documentIdentifier
        if let last = observedContext?.last, !last.isWhitespace { separator = " " }
        acceptsResults = true
    }

    var hostIsReady: Bool {
        _ = proxy.documentContextBeforeInput
        return proxy.documentIdentifier != nil
    }

    private func invalidateCapture() {
        isInvalidated = true
        acceptsResults = false
        observedContext = nil
        if let activeEpoch = lastApplied?.sessionEpoch {
            terminalSessionEpoch = activeEpoch
        }
        insertedChars = 0
        lastApplied = nil
        lastAppliedText = nil
        lastCommitted = nil
        committedChars = 0
    }

    private func separated(_ text: String) -> String {
        text.isEmpty ? text : separator + text
    }

    private func canReplace(_ expectedText: String?) -> Bool {
        let document = proxy.documentIdentifier
        guard captureDocumentIdentifier == document else {
            #if DEBUG
            Logger(subsystem: "dev.shreyansh.Piko.benchmark", category: "insertion")
                .notice("PIKO_INSERTION_BLOCKED document_changed anchor_nil=\(self.captureDocumentIdentifier == nil, privacy: .public) current_nil=\(document == nil, privacy: .public)")
            #endif
            return false
        }
        let context = proxy.documentContextBeforeInput
        if let observedContext, context != observedContext {
            #if DEBUG
            Logger(subsystem: "dev.shreyansh.Piko.benchmark", category: "insertion")
                .notice("PIKO_INSERTION_BLOCKED context_changed previous_count=\(observedContext.count, privacy: .public) current_count=\(context?.count ?? -1, privacy: .public)")
            #endif
            return false
        }
        guard let expectedText else { return insertedChars == 0 }
        guard let context else { return false }
        return context.hasSuffix(expectedText)
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix { pair in pair.0 == pair.1 }.count
    }
}
