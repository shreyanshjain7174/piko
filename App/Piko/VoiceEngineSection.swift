import SwiftUI
import PikoKit
import PikoTranscribe

/// Settings surface for the two opt-in behaviour toggles introduced with the
/// harness: which transcriber to use (on-device vs Sarvam cloud) and how
/// capture starts (hold-to-talk vs auto on field focus).
///
/// Copy follows piko-ui-craft: second person, one line per idea, no cloud
/// glyphs, and the privacy trade-off is stated in words rather than iconography.
@MainActor
struct VoiceEngineSection: View {
    @ObservedObject var model: VoiceEngineSettingsModel

    var body: some View {
        Group {
            captureModeSection
            voiceEngineSection
            if model.backend == .sarvamCloud {
                sarvamKeySection
            }
        }
    }

    // MARK: - Capture mode

    private var captureModeSection: some View {
        Section {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    model.selectCaptureMode(mode)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: mode == model.captureMode ? "largecircle.fill.circle" : "circle")
                            .font(.title3)
                            .foregroundStyle(mode == model.captureMode ? .white : .white.opacity(0.4))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(mode.explainer)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == model.captureMode ? .isSelected : [])
            }
        } header: {
            Text("How capture starts")
                .foregroundStyle(.white.opacity(0.5))
        } footer: {
            Text(model.captureMode == .auto
                 ? "Auto only fires while a session is armed. Typing in the field stops capture."
                 : "The default. Piko never opens the microphone on its own.")
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Voice engine

    private var voiceEngineSection: some View {
        Section {
            ForEach(TranscriberBackend.allCases, id: \.self) { backend in
                Button {
                    model.selectBackend(backend)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: backend == model.backend ? "largecircle.fill.circle" : "circle")
                            .font(.title3)
                            .foregroundStyle(backend == model.backend ? .white : .white.opacity(0.4))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(backend.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(backend.explainer)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(backend == model.backend ? .isSelected : [])
            }
        } header: {
            Text("Voice engine")
                .foregroundStyle(.white.opacity(0.5))
        } footer: {
            Text(model.backend.leavesDevice
                 ? "Audio leaves your iPhone only while Sarvam Cloud is selected."
                 : "The default. Nothing leaves this iPhone.")
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Sarvam key entry

    private var sarvamKeySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if model.hasStoredKey && !model.isEditingKey {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.white.opacity(0.7))
                            .accessibilityHidden(true)
                        Text(model.maskedKey ?? "Key saved")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                        Button("Replace") { model.beginEditingKey() }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                } else {
                    SecureField("Paste your Sarvam API key", text: $model.draftKey)
                        .textFieldStyle(.plain)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.white)
                        .tint(.cyan)
                        .padding(12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityLabel("Sarvam API key")
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.saveDraftKey() }
                        } label: {
                            Label("Save", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .frame(minHeight: 38)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(model.canSaveDraft ? .cyan.opacity(0.7) : .white.opacity(0.1),
                                    in: Capsule())
                        .disabled(!model.canSaveDraft || model.isTesting)

                        if model.hasStoredKey {
                            Button("Cancel") { model.cancelEditingKey() }
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await model.testConnection() }
                    } label: {
                        Label(model.isTesting ? "Testing…" : "Test connection",
                              systemImage: "wave.3.right")
                            .font(.caption.weight(.semibold))
                    }
                    .disabled(!model.hasStoredKey || model.isTesting)
                    .foregroundStyle(model.hasStoredKey ? .cyan : .white.opacity(0.35))

                    Spacer(minLength: 0)

                    if model.hasStoredKey {
                        Button(role: .destructive) {
                            model.clearStoredKey()
                        } label: {
                            Text("Clear key")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }

                if let status = model.statusLine {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(model.statusIsError ? .pink : .white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.voiceEngine.status")
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Sarvam key")
                .foregroundStyle(.white.opacity(0.5))
        } footer: {
            Text("Stored in your iPhone’s Keychain. Piko never sends the key anywhere except Sarvam’s speech-to-text endpoint.")
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// State for the voice-engine settings surface. Owns the read-modify-write cycle
/// against `CaptureModeStore` and `SarvamKeyStore` so the view stays declarative.
@MainActor
final class VoiceEngineSettingsModel: ObservableObject {
    @Published private(set) var captureMode: CaptureMode
    @Published private(set) var backend: TranscriberBackend
    @Published var draftKey: String = ""
    @Published private(set) var hasStoredKey: Bool
    @Published private(set) var maskedKey: String?
    @Published private(set) var isEditingKey: Bool = false
    @Published private(set) var isTesting: Bool = false
    @Published private(set) var statusLine: String?
    @Published private(set) var statusIsError: Bool = false

    init() {
        self.captureMode = CaptureModeStore.read()
        self.backend = CaptureModeStore.readBackend()
        let stored = SarvamKeyStore.read()
        self.hasStoredKey = stored != nil
        self.maskedKey = stored.map(Self.mask(_:))
        self.isEditingKey = stored == nil && CaptureModeStore.readBackend() == .sarvamCloud
    }

    var canSaveDraft: Bool {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
    }

    func selectCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode else { return }
        captureMode = mode
        CaptureModeStore.write(mode)
    }

    func selectBackend(_ backend: TranscriberBackend) {
        guard backend != self.backend else { return }
        self.backend = backend
        CaptureModeStore.writeBackend(backend)
        statusLine = nil
        statusIsError = false
        if backend == .sarvamCloud, !hasStoredKey {
            isEditingKey = true
        }
    }

    func beginEditingKey() {
        draftKey = ""
        isEditingKey = true
        statusLine = nil
        statusIsError = false
    }

    func cancelEditingKey() {
        draftKey = ""
        isEditingKey = false
    }

    func saveDraftKey() async {
        let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let outcome = SarvamKeyStore.write(trimmed)
        switch outcome {
        case .stored:
            hasStoredKey = true
            maskedKey = Self.mask(trimmed)
            draftKey = ""
            isEditingKey = false
            statusLine = "Key saved to Keychain."
            statusIsError = false
        case .cleared:
            hasStoredKey = false
            maskedKey = nil
            statusLine = "Key cleared."
            statusIsError = false
        case .failed(let error):
            statusLine = "Couldn’t save the key. (\(String(describing: error)))"
            statusIsError = true
        }
    }

    func clearStoredKey() {
        _ = SarvamKeyStore.write("")
        hasStoredKey = false
        maskedKey = nil
        isEditingKey = true
        draftKey = ""
        statusLine = "Key cleared."
        statusIsError = false
    }

    func testConnection() async {
        guard let key = SarvamKeyStore.read() else {
            statusLine = "Add a key first."
            statusIsError = true
            return
        }
        isTesting = true
        statusLine = "Reaching Sarvam…"
        statusIsError = false
        let client = SarvamAPIClient(apiKey: key)
        let result = await client.healthCheck()
        isTesting = false
        switch result {
        case .ok:
            statusLine = "Sarvam is reachable. Cloud transcription is ready."
            statusIsError = false
        case .unauthorized:
            statusLine = "Sarvam rejected the key. Check it and try again."
            statusIsError = true
        case .failed(let message):
            statusLine = "Couldn’t reach Sarvam. (\(message))"
            statusIsError = true
        }
    }

    private static func mask(_ key: String) -> String {
        let visible = 4
        guard key.count > visible * 2 else {
            return String(repeating: "•", count: max(key.count, 6))
        }
        let prefix = key.prefix(visible)
        let suffix = key.suffix(visible)
        return "\(prefix)••••••\(suffix)"
    }
}
