import SwiftUI
import UIKit
import PikoKit
import PikoBridge
import PikoUI
#if DEBUG
import OSLog
#endif

/// A remote control and a text sink. Nothing else lives here.
///
/// Hard rules (CONSTRAINTS C1, C4):
/// - No microphone. The runtime refuses; do not try.
/// - No model, no database, no audio buffers. ~60 MB and jetsam does not warn you.
/// - `RequestsOpenAccess` must be true in Info.plist for the App Group to be writable.
final class KeyboardViewController: UIInputViewController {

    private var channel: DarwinChannel?
    private var insertionController: TextInsertionController? { KeyboardProcessState.insertion }
    private var hostingController: UIHostingController<KeyboardView>?
    private var sessionState: SessionState?
    private var heightConstraint: NSLayoutConstraint?
    private let voiceActivity = VoiceActivityModel()
    private lazy var suggestionStore = SuggestionSnapshotStore()
    private lazy var suggestionFileURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: AppGroup.identifier
    )?.appendingPathComponent(AppGroup.suggestionsFile)
    private var suggestionFileSignature: SuggestionFileSignature?
    private var cachedSuggestions: SuggestionSnapshot = .empty
    private var suggestionToken: SuggestionConfirmToken?
    private lazy var suggestionController = SuggestionController(
        proxy: KeyboardSuggestionProxy(provider: { [weak self] in self?.textDocumentProxy }),
        snapshotReader: { [weak self] in self?.cachedSuggestions ?? .empty },
        freshSnapshotReader: { [weak self] in self?.suggestionStore?.read() ?? .empty },
        suggestionsEnabled: { [weak self] in
            KeyboardPreferences.suggestionsEnabled(in: self?.keyboardDefaults)
        })
    private var keyboardDefaults: UserDefaults? { UserDefaults(suiteName: AppGroup.identifier) }

    private var observationTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?
    private var captureStartTask: Task<Void, Never>?
    private var delivery: KeyboardCaptureDelivery {
        get { KeyboardProcessState.delivery }
        set { KeyboardProcessState.delivery = newValue }
    }
    private var isCurrentHost: Bool { KeyboardProcessState.host === self }
    #if DEBUG
    private var lastLoggedInsertionEpoch: Int?
    private let insertionLogger = Logger(subsystem: "dev.shreyansh.Piko.benchmark", category: "insertion")
    #endif

    @Published private var sessionPhase: SessionPhase? = nil
    @Published private var setupPrompt: KeyboardSetupPrompt? = .armSession
    @Published private var selectedProfile: Profile = .message
    @Published private var skin: Skin = .cute
    @Published private var canRevert: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()
        channel = DarwinChannel()
        KeyboardProcessState.host = self
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
        captureStartTask?.cancel()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updatePreferredHeight()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        KeyboardProcessState.host = self
        delivery.isVisible = true
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
                self.refreshSuggestions()
                if self.delivery.isActive {
                    self.applyDraft()
                    self.applyResult()
                }
            }
        }
        refreshRevertAvailability()
        refreshSuggestions()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Like system dictation: an armed Piko starts listening when its keyboard appears.
        guard hasFullAccess else { return }
        let autoListen = KeyboardPreferences.autoListen(in: UserDefaults(suiteName: AppGroup.identifier))
        guard autoListen || delivery.isActive else { return }
        startCaptureWhenHostReady(warnIfHostMissing: false, landPendingResult: true, start: autoListen)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Text typed during the hide transition can be dropped by the host, which would leave
        // insertion bookkeeping out of sync. Stop delivering and listening as soon as hiding starts.
        guard isCurrentHost else { return }
        if delivery.isActive, channel?.readState()?.phase == .capturing {
            channel?.post(.captureStop)
        }
        delivery.isVisible = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isCurrentHost { delivery.isVisible = false }
        captureStartTask?.cancel()
        captureStartTask = nil
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
            onSuggestionTap: { [weak self] in self?.suggestionTapped() },
            onSuggestionConfirm: { [weak self] in self?.confirmSuggestion() },
            onSuggestionDismiss: { [weak self] in self?.dismissSuggestion() },
            onToggleSuggestions: { [weak self] in self?.toggleSuggestions() },
            suggestionEntry: suggestionController.confirmingEntry ?? suggestionController.offeredEntry,
            isConfirmingSuggestion: suggestionController.confirmingEntry != nil,
            suggestionsEnabled: KeyboardPreferences.suggestionsEnabled(in: keyboardDefaults),
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

    /// Metadata-only polling; the bounded JSON read occurs only on file change or confirm.
    private func refreshSuggestions() {
        let before = suggestionController.state
        if hasFullAccess, suggestionStore != nil, let url = suggestionFileURL {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let signature = SuggestionFileSignature(modified: values?.contentModificationDate,
                                                     size: values?.fileSize)
            if signature != suggestionFileSignature {
                suggestionFileSignature = signature
                cachedSuggestions = suggestionStore?.read() ?? .empty
            }
        } else {
            cachedSuggestions = .empty
            suggestionFileSignature = nil
        }
        suggestionController.offer(hasFullAccess: hasFullAccess)
        if suggestionController.state != before { refreshRootView() }
    }

    private func suggestionTapped() {
        suggestionToken = suggestionController.beginConfirmation(hasFullAccess: hasFullAccess)
        refreshRootView()
    }

    private func confirmSuggestion() {
        guard let token = suggestionToken else { return }
        suggestionToken = nil
        if !suggestionController.confirm(token, hasFullAccess: hasFullAccess) { haptic(.warning) }
        refreshRootView()
    }

    private func dismissSuggestion() {
        suggestionToken = nil
        suggestionController.dismiss()
        refreshRootView()
    }

    private func toggleSuggestions() {
        guard let defaults = keyboardDefaults else { return }
        defaults.set(!KeyboardPreferences.suggestionsEnabled(in: defaults),
                     forKey: KeyboardPreferences.suggestionsEnabledKey)
        refreshSuggestions()
        refreshRootView()
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
        voiceActivity.setActive(delivery.isVisible && setupPrompt == nil && state?.phase == .capturing)
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
                    applyResult()
                    if !delivery.isActive, insertionController?.lastCommitted == nil {
                        insertionController?.reset()
                    }
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
            startCaptureWhenHostReady(warnIfHostMissing: true)
        case .capturing:
            channel?.post(.captureStop)
            haptic(.stop)
        default:
            break
        }
        refreshRootView()
    }

    private func startCaptureWhenHostReady(
        warnIfHostMissing: Bool, landPendingResult: Bool = false, start: Bool = true
    ) {
        guard captureStartTask == nil else { return }
        captureStartTask = Task { [weak self] in
            guard let self else { return }
            defer { self.captureStartTask = nil }
            // The host proxy is attached asynchronously, including after viewWillAppear.
            for _ in 0..<15 {
                guard !Task.isCancelled, self.delivery.isVisible else { return }
                if self.insertionController?.hostIsReady == true {
                    // Land a result that finished while hidden before a new capture resets insertion.
                    if landPendingResult, self.delivery.isActive { self.applyResult() }
                    guard start, let state = self.channel?.readState(), state.isLive(), state.phase == .armed else {
                        return
                    }
                    self.apply(state)
                    self.insertionController?.beginCapture()
                    self.delivery.begin(after: self.channel?.readDraft(), result: self.channel?.readResult())
                    self.channel?.post(.captureStart)
                    self.haptic(.start)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { return }
            }
            if warnIfHostMissing { self.haptic(.warning) }
            #if DEBUG
            self.insertionLogger.error("PIKO_INSERTION_BLOCKED host_not_attached")
            #endif
        }
    }

    private func revertTapped() {
        guard insertionController?.revertToRaw() == true else { return }
        haptic(.selection)
        refreshRevertAvailability()
    }

    /// Insert only what is new. Ignore anything older than what we already typed, or the field
    /// thrashes — that is the failure mode spike 3 exists to prevent.
    private func applyDraft() {
        // Before the host proxy attaches, field checks fail and would abandon the capture; retry later.
        guard isCurrentHost, insertionController?.hostIsReady == true,
              let draft = channel?.readDraft(), delivery.accepts(draft) else { return }
        insertionController?.apply(draft)
        #if DEBUG
        if insertionController?.lastApplied?.sequence == draft.sequence,
           insertionController?.lastApplied?.sessionEpoch == draft.sessionEpoch,
           !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           lastLoggedInsertionEpoch != draft.sessionEpoch {
            lastLoggedInsertionEpoch = draft.sessionEpoch
            insertionLogger.notice("PIKO_DEBUG_INSERTION epoch=\(draft.sessionEpoch, privacy: .public) uptime=\(ProcessInfo.processInfo.systemUptime, privacy: .public)")
        }
        #endif
        refreshRevertAvailability()
    }

    private func applyResult() {
        guard isCurrentHost, insertionController?.hostIsReady == true,
              let result = channel?.readResult(), delivery.accepts(result) else { return }
        delivery.finish()
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

/// iOS can replace the keyboard's view controller when the user switches keyboards and back.
/// Capture ownership and insertion bookkeeping live per keyboard process, routed to whichever
/// controller is on screen, so a capture that ended while hidden still lands its final text.
@MainActor
private enum KeyboardProcessState {
    static weak var host: KeyboardViewController?
    static var delivery = KeyboardCaptureDelivery()
    static let insertion = TextInsertionController(proxyProvider: { host?.textDocumentProxy })
}

private struct SuggestionFileSignature: Equatable {
    let modified: Date?
    let size: Int?
}

/// The UIKit-only bridge keeps the state machine host-testable on macOS.
@MainActor
private final class KeyboardSuggestionProxy: SuggestionProxy {
    private let provider: @MainActor () -> (any UITextDocumentProxy)?
    private var proxy: (any UITextDocumentProxy)? { provider() }

    init(provider: @escaping @MainActor () -> (any UITextDocumentProxy)?) {
        self.provider = provider
    }

    var documentIdentifier: UUID? {
        guard let proxy else { return nil }
        return UITextDocumentProxyBox.documentIdentifier(of: proxy)
    }
    var isSecureTextEntry: Bool { proxy?.isSecureTextEntry ?? true }
    var fieldKind: SuggestionFieldKind {
        switch proxy?.textContentType {
        case .password: .password
        case .newPassword: .newPassword
        case .oneTimeCode: .oneTimeCode
        case .creditCardNumber: .creditCardNumber
        default: .other
        }
    }
    func insertText(_ text: String) { proxy?.insertText(text) }
}
