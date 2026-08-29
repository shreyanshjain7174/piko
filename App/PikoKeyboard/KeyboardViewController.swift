import SwiftUI
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
    private var insertionController: TextInsertionController?
    private var hostingController: UIHostingController<KeyboardView>?
    private var sessionState: SessionState?

    @Published private var sessionPhase: SessionPhase? = nil
    @Published private var showArmPrompt: Bool = true

    override func viewDidLoad() {
        super.viewDidLoad()
        channel = DarwinChannel()
        insertionController = TextInsertionController(proxy: textDocumentProxy)
        apply(channel?.readState())

        if !UIInputViewController.self.responds(to: #selector(getter: hasFullAccess)) || !hasFullAccess {
            showArmPrompt = true
        }

        let hosting = UIHostingController(rootView: makeKeyboardView())
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        let canvas: UIView = inputView ?? view
        canvas.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: canvas.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: canvas.bottomAnchor)
        ])
        hostingController = hosting

        Task { await observe() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        insertionController = TextInsertionController(proxy: textDocumentProxy)
    }

    private func makeKeyboardView() -> KeyboardView {
        KeyboardView(
            onMicTap: { [weak self] in self?.micButtonTapped() },
            onGlobeTap: { [weak self] in self?.advanceToNextInputMode() },
            sessionPhase: Binding(
                get: { [weak self] in self?.sessionPhase },
                set: { [weak self] in self?.sessionPhase = $0 }),
            showArmPrompt: Binding(
                get: { [weak self] in self?.showArmPrompt ?? true },
                set: { [weak self] in self?.showArmPrompt = $0 })
        )
    }

    private func apply(_ state: SessionState?) {
        sessionState = state
        sessionPhase = state?.phase
        showArmPrompt = !(state?.isLive() ?? false)
        hostingController?.rootView = makeKeyboardView()
    }

    private func observe() async {
        guard let channel else { return }
        for await signal in channel.signals {
            switch signal {
            case .stateChanged:
                if let state = channel.readState() {
                    await MainActor.run {
                        apply(state)
                        if state.phase == .idle {
                            insertionController?.reset()
                        }
                    }
                }
            case .draftUpdated:
                await MainActor.run { applyDraft() }
            case .resultReady:
                await MainActor.run { applyResult() }
            default:
                break
            }
        }
    }

    func micButtonTapped() {
        guard let state = channel?.readState(), state.isLive() else {
            showArmPrompt = true
            hostingController?.rootView = makeKeyboardView()
            return
        }
        showArmPrompt = false
        sessionPhase = state.phase
        sessionState = state
        hostingController?.rootView = makeKeyboardView()
        switch state.phase {
        case .armed: channel?.post(.captureStart)
        case .capturing: channel?.post(.captureStop)
        default: break
        }
    }

    /// Insert only what is new. Ignore anything older than what we already typed, or the field
    /// thrashes — that is the failure mode spike 3 exists to prevent.
    private func applyDraft() {
        guard let draft = channel?.readDraft() else { return }
        insertionController?.apply(draft)
    }

    private func applyResult() {
        guard let result = channel?.readResult() else { return }
        insertionController?.commit(result)
    }
}
