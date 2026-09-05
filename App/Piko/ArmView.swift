import AVFAudio
import Combine
import SwiftUI
import UIKit
import PikoKit
import PikoUI

/// App-only presentation state. All capture and persistence still use the existing coordinators.
@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var isBusy = false
    @Published var text = ""
    @Published var error: String?
    @Published private(set) var needsMicrophoneSettings = false
    @Published private(set) var skin: Skin = .cute
    @Published private(set) var microphonePermission = "Not requested"
    let activity = VoiceActivityModel()
    private var lastResultID: UUID?

    init() {
        lastResultID = AppComposition.shared.channel.readResult()?.id
        refresh()
    }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canEdit: Bool { !isBusy && phase != .capturing && phase != .tidying }
    var sessionActive: Bool { phase != .idle }

    func refresh() {
        let app = AppComposition.shared
        let nextPhase = app.captureCoordinator.isTidying ? SessionPhase.tidying : app.session.currentPhase
        if phase != nextPhase { phase = nextPhase }
        let nextSkin = app.channel.readState()?.skin ?? .cute
        if skin != nextSkin { skin = nextSkin }
        activity.setActive(phase == .capturing)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphonePermission = "Allowed"
        case .denied: microphonePermission = "Off"
        default: microphonePermission = "Not requested"
        }
    }

    func observe() async {
        refresh()
        let channel = AppComposition.shared.channel
        for await signal in channel.signals {
            guard !Task.isCancelled else { return }
            if signal == .audioLevelUpdated {
                if let sample = (channel as? any AudioLevelChannel)?.readAudioLevel() {
                    activity.receive(sample)
                }
                continue
            }
            refresh()
            if signal == .draftUpdated, phase == .capturing, let draft = channel.readDraft() {
                text = draft.text
            }
            if signal == .resultReady, let result = channel.readResult(), result.id != lastResultID {
                lastResultID = result.id
                text = result.shipped
            }
        }
    }

    func toggleCapture() async {
        guard !isBusy, !AppComposition.shared.captureCoordinator.isTidying else { return }
        isBusy = true
        error = nil
        defer { isBusy = false; refresh() }
        let app = AppComposition.shared
        if app.session.currentPhase == .capturing {
            await app.captureCoordinator.stopCapture()
            return
        }
        do {
            try await prepareSession()
            text = ""
            try await app.captureCoordinator.startCapture()
        } catch {
            present(error)
        }
    }

    func startSession() async {
        guard !isBusy, !sessionActive else { return }
        isBusy = true
        error = nil
        defer { isBusy = false; refresh() }
        do { try await prepareSession() } catch { present(error) }
    }

    func endSession() async {
        guard !isBusy, !AppComposition.shared.captureCoordinator.isTidying else { return }
        isBusy = true
        defer { isBusy = false; refresh() }
        let app = AppComposition.shared
        if app.session.currentPhase == .capturing { await app.captureCoordinator.stopCapture() }
        await app.session.disarm()
        await app.liveActivityController.end()
    }

    func selectSkin(_ skin: Skin) {
        SkinSelection.apply(skin, via: AppComposition.shared.channel)
        self.skin = skin
    }

    private func prepareSession() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw PikoError.microphoneDenied }
        if AppComposition.shared.session.currentPhase == .idle {
            try await AppComposition.shared.armSession()
        }
    }

    private func present(_ failure: any Error) {
        needsMicrophoneSettings = (failure as? PikoError).map {
            if case .microphoneDenied = $0 { return true }
            return false
        } ?? false
        error = PikoError.userMessage(for: failure)
    }
}

struct ArmView: View {
    @ObservedObject var model: HomeViewModel
    @State private var showSetup = false
    @State private var copiedText: String?
    @FocusState private var isEditing: Bool

    private let ink = Color(red: 0.08, green: 0.12, blue: 0.22)
    private let accent = Color(red: 0.24, green: 0.33, blue: 0.92)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heading
                    recordingCard
                    if let error = model.error { errorCard(error) }
                    if model.hasText || model.phase == .capturing || model.phase == .tidying {
                        transcriptCard
                    }
                    keyboardCard
                    Label("On-device transcription. Your words stay yours.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("piko")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSetup = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Keyboard setup")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditing = false }
                }
            }
            .sheet(isPresented: $showSetup) { OnboardingView(isPresented: $showSetup) }
            .onChange(of: model.text) { _, _ in copiedText = nil }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A little less typing.")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .tracking(-1)
                .fixedSize(horizontal: false, vertical: true)
            Text("Say it naturally. Make it yours.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(recordingStatus, systemImage: model.phase == .capturing ? "record.circle" : "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("VOICE TO TEXT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(model.phase == .capturing ? "Go ahead.\nWe’re listening." : "Let your thoughts\nflow into words.")
                    .font(.system(size: 28, weight: .medium))
                    .tracking(-0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)

                if model.phase == .capturing {
                    VoiceWave(activity: model.activity, tint: .cyan)
                        .frame(height: 48)
                } else {
                    Text(model.phase == .tidying ? "Putting the finishing touches on your text." : "A note, a reply, or the start of something.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 8)
                }
            }
            .frame(minHeight: 110, alignment: .topLeading)

            Button {
                isEditing = false
                Task { await model.toggleCapture() }
            } label: {
                HStack(spacing: 10) {
                    if model.isBusy || model.phase == .tidying {
                        ProgressView().tint(ink)
                    } else {
                        Image(systemName: model.phase == .capturing ? "stop.fill" : "mic.fill")
                    }
                    Text(model.phase == .capturing ? "Finish dictation" : model.phase == .tidying ? "Finishing…" : "Start dictating")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.subheadline.weight(.medium))
                }
                .foregroundStyle(ink)
                .padding(.horizontal, 18)
                .frame(minHeight: 54)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.phase == .tidying)
            .accessibilityIdentifier("home.dictate")
        }
        .padding(24)
        .background(
            LinearGradient(colors: [ink, Color(red: 0.15, green: 0.2, blue: 0.4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28))
    }

    private var recordingStatus: String {
        switch model.phase {
        case .capturing: "Listening"
        case .tidying: "Tidying"
        case .armed, .idle: "Ready when you are"
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.canEdit ? "Your words" : "Live transcript")
                    .font(.headline)
                Spacer()
                if model.canEdit {
                    Button {
                        model.text = ""
                        isEditing = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("Clear text from Home")
                }
            }

            TextEditor(text: $model.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110, maxHeight: 180)
                .focused($isEditing)
                .disabled(!model.canEdit)
                .accessibilityLabel("Dictation text")
                .accessibilityIdentifier("home.transcript")

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = model.text
                    copiedText = model.text
                } label: {
                    Label(copiedText == model.text ? "Copied" : "Copy text",
                          systemImage: copiedText == model.text ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                ShareLink(item: model.text) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 44, height: 44)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Share text")
            }
            .disabled(!model.canEdit || !model.hasText)
            .buttonStyle(.plain)
            .foregroundStyle(accent)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private var keyboardCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.title3)
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your voice, in any conversation").font(.subheadline.weight(.semibold))
                    Text("Piko keyboard").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(model.sessionActive
                 ? "Your session is active. End it here when you’re done."
                 : "Start a session, then switch to Piko using the globe key in a text field.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    Task {
                        if model.sessionActive { await model.endSession() }
                        else { await model.startSession() }
                    }
                } label: {
                    Label(model.sessionActive ? "End session" : "Start session",
                          systemImage: model.sessionActive ? "power" : "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .disabled(model.isBusy || model.phase == .tidying)
                .accessibilityIdentifier("home.session")
                Spacer()
                Button("Set up keyboard") { showSetup = true }
                    .font(.caption.weight(.medium))
                    .frame(minHeight: 44)
            }
            .foregroundStyle(accent)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.subheadline)
            if model.needsMicrophoneSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.subheadline.weight(.semibold))
            }
            Button("Dismiss") { model.error = nil }.font(.caption)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
