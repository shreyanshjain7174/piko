#if os(iOS)
import Foundation
import Testing
import PikoKit
@testable import PikoTranscribe

@Suite struct WhisperReadinessTests {
    @Test func appleOnDeviceReadinessRejectsUnsupportedLanguageWithoutLegacyPermission() async {
        let model = SpeechTranscriberEngine()
        do {
            try await model.prepare(locale: Locale(identifier: "hi-IN"), allowDownload: false)
            Issue.record("The English beta must not silently change the requested language")
        } catch PikoError.speechUnavailable {
        } catch {
            Issue.record("Unexpected readiness error: \(error)")
        }
    }

    @Test func missingAssetsFailBeforeAnyDownload() async {
        let model = WhisperTranscriberEngine(
            modelFolder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        do {
            try await model.prepare(locale: Locale(identifier: "en-IN"), allowDownload: false)
            Issue.record("Missing local assets must not be accepted")
        } catch PikoError.speechAssetsMissing {
        } catch {
            Issue.record("Unexpected readiness error: \(error)")
        }
    }

    @Test func unsupportedLanguageIsNotSilentlyChanged() async {
        let model = WhisperTranscriberEngine(modelFolder: FileManager.default.temporaryDirectory)
        do {
            try await model.prepare(locale: Locale(identifier: "hi-IN"), allowDownload: false)
            Issue.record("Unsupported language must not silently become English")
        } catch PikoError.speechUnavailable {
        } catch {
            Issue.record("Unexpected locale error: \(error)")
        }
    }
}
#endif
