import SwiftUI
import UIKit
import PikoKit
import PikoBridge
import PikoUI

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
    private var heightConstraint: NSLayoutConstraint?
    private let voiceActivity = VoiceActivityModel()
    private var observationTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?
    private var isKeyboardVisible = false

    @Published private var sessionPhase: SessionPhase? = nil
    @Published private var setupPrompt: KeyboardSetupPrompt? = .armSession
    @Published private var selectedProfile: Profile = .message
    @Published private var skin: Skin = .cute
    @Published private var canRevert: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()
        channel = DarwinChannel()
        insertionController = TextInsertionController(proxy: textDocumentProxy)
        apply(channel?.readState())

        let hosting = UIHostingController(rootView: makeKeyboardView())
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
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

        let height = view.heightAnchor.constraint(equalToConstant: 240)
        height.priority = .required - 1
        height.isActive = true
        heightConstraint = height
        // Keep text delivery alive through keyboard transitions, as before.
        if let signals = channel?.signals {
            observationTask = Task { [weak self] in
                for await signal in signals {
                    guard !Task.isCancelled, let self else { return }
                    self.handle(signal)
                }
            }
        }
    }

    deinit {
        observationTask?.cancel()
        freshnessTask?.cancel()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updatePreferredHeight()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isKeyboardVisible = true
        apply(channel?.readState())
        freshnessTask?.cancel()
        freshnessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                let state = self.channel?.readState()
                let prompt = KeyboardSetupPrompt.resolve(
                    hasFullAccess: self.hasFullAccess, isLive: state?.isLive() ?? false)
                if state != self.sessionState || prompt != self.setupPrompt {
                    self.apply(state)
                }
                // Recover from coalesced/missed Darwin notifications while visible.
                self.refreshAudioLevel()
            }
        }
        insertionController = TextInsertionController(proxy: textDocumentProxy)
        refreshRevertAvailability()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isKeyboardVisible = false
        freshnessTask?.cancel()
        freshnessTask = nil
        voiceActivity.setActive(false)
    }

    private func updatePreferredHeight() {
        guard let hosting = hostingController, let heightConstraint else { return }
        let width = view.bounds.width
        guard width > 0 else { return }

        let fitted = hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let isLandscape = traitCollection.verticalSizeClass == .compact
        let bounds: ClosedRange<CGFloat> = isLandscape ? 140...190 : 180...260
        let clamped = min(max(fitted, bounds.lowerBound), bounds.upperBound)

        if abs(heightConstraint.constant - clamped) > 0.5 {
            heightConstraint.constant = clamped
        }
    }

    private func makeKeyboardView() -> KeyboardView {
        KeyboardView(
            onMicTap: { [weak self] in self?.micButtonTapped() },
            onGlobeTap: { [weak self] in self?.advanceToNextInputMode() },
            onRevertTap: { [weak self] in self?.revertTapped() },
            sessionPhase: Binding(
                get: { [weak self] in self?.sessionPhase },
                set: { [weak self] in self?.sessionPhase = $0 }),
            setupPrompt: setupPrompt,
            selectedProfile: Binding(
                get: { [weak self] in self?.selectedProfile ?? .message },
                set: { [weak self] in self?.selectProfile($0) }),
            skin: Binding(
                get: { [weak self] in self?.skin ?? .cute },
                set: { [weak self] in self?.skin = $0 }),
            canRevert: Binding(
                get: { [weak self] in self?.canRevert ?? false },
                set: { [weak self] in self?.canRevert = $0 }),
            voiceActivity: voiceActivity
        )
    }

    private func selectProfile(_ profile: Profile) {
        selectedProfile = profile
        if let channel {
            ProfileSelectionController(channel: channel).select(profile)
        }
        haptic(.selection)
        refreshRootView()
    }

    private func apply(_ state: SessionState?) {
        sessionState = state
        sessionPhase = state?.phase
        if let profile = state?.profile {
            selectedProfile = profile
        }
        if let stateSkin = state?.skin {
            skin = stateSkin
        }
        setupPrompt = KeyboardSetupPrompt.resolve(hasFullAccess: hasFullAccess, isLive: state?.isLive() ?? false)
        if setupPrompt != nil { sessionPhase = .idle }
        voiceActivity.setActive(isKeyboardVisible && setupPrompt == nil && state?.phase == .capturing)
        refreshAudioLevel()
        refreshRootView()
    }

    private func refreshRootView() {
        hostingController?.rootView = makeKeyboardView()
        updatePreferredHeight()
    }

    private func refreshRevertAvailability() {
        let available = insertionController?.canRevertToRaw ?? false
        guard available != canRevert else { return }
        canRevert = available
        refreshRootView()
    }

    private func refreshAudioLevel() {
        guard voiceActivity.isActive, let sample = channel?.readAudioLevel() else { return }
        voiceActivity.receive(sample)
    }

    private func handle(_ signal: Signal) {
        guard let channel else { return }
        switch signal {
        case .audioLevelUpdated:
            refreshAudioLevel()
        case .stateChanged:
            if let state = channel.readState() {
                apply(state)
                if state.phase == .idle {
                    insertionController?.reset()
                    refreshRevertAvailability()
                }
            }
        case .draftUpdated:
            applyDraft()
        case .resultReady:
            applyResult()
        default:
            break
        }
    }

    func micButtonTapped() {
        guard hasFullAccess, let state = channel?.readState(), state.isLive() else {
            apply(channel?.readState())
            haptic(.warning)
            return
        }
        setupPrompt = nil
        sessionPhase = state.phase
        sessionState = state
        switch state.phase {
        case .armed:
            channel?.post(.captureStart)
            haptic(.start)
        case .capturing:
            channel?.post(.captureStop)
            haptic(.stop)
        default:
            break
        }
        refreshRootView()
    }

    private func revertTapped() {
        guard insertionController?.revertToRaw() == true else { return }
        haptic(.selection)
        refreshRevertAvailability()
    }

    /// Insert only what is new. Ignore anything older than what we already typed, or the field
    /// thrashes — that is the failure mode spike 3 exists to prevent.
    private func applyDraft() {
        guard let draft = channel?.readDraft() else { return }
        insertionController?.apply(draft)
        refreshRevertAvailability()
    }

    private func applyResult() {
        guard let result = channel?.readResult() else { return }
        insertionController?.commit(result)
        haptic(.landed)
        refreshRevertAvailability()
    }
}

private extension KeyboardViewController {
    enum Cue { case start, stop, landed, selection, warning }

    func haptic(_ cue: Cue) {
        guard hasFullAccess else { return }
        switch cue {
        case .start:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .stop:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .landed:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
