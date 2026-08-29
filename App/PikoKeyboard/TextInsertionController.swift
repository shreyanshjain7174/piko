import PikoKit
#if canImport(UIKit)
import UIKit
#endif

/// Host-field mutation surface. Production wraps `UITextDocumentProxy`; tests use `MockTextDocumentProxy`.
protocol TextProxy: AnyObject {
    func insertText(_ text: String)
    func deleteBackward()
}

#if canImport(UIKit)
extension UITextDocumentProxy {
    // UITextDocumentProxy already declares insertText/deleteBackward (UIKeyInput).
}

/// Class box so the controller can hold a weak reference. `UITextDocumentProxy` is a protocol.
final class UITextDocumentProxyBox: TextProxy {
    private let proxy: any UITextDocumentProxy

    init(_ proxy: any UITextDocumentProxy) {
        self.proxy = proxy
    }

    func insertText(_ text: String) { proxy.insertText(text) }
    func deleteBackward() { proxy.deleteBackward() }
}
#endif

/// StablePrefix-aware streaming insertion. Only the unstable tail is rewritten.
final class TextInsertionController {
    private weak var proxy: (any TextProxy)?
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
        // Stub: TDD RED. Real diffing lands in the GREEN commit.
        _ = draft
    }

    func commit(_ result: CaptureResult) {
        _ = result
    }

    func reset() {}
}
