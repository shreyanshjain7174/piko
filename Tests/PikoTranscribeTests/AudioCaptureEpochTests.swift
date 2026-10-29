#if os(iOS)
import AVFAudio
import Foundation
import PikoKit
import Testing
@testable import PikoTranscribe

@Suite struct AudioCaptureEpochTests {
    @Test func staleConfigurationAndCancellationCannotAffectANewerCapture() async {
        let engines: [any AudioTranscriber] = [
            SpeechTranscriberEngine(),
            WhisperTranscriberEngine(modelFolder: FileManager.default.temporaryDirectory),
        ]
        for engine in engines {
            let buffers = AsyncStream<AVAudioPCMBuffer> { $0.finish() }
            await engine.configure(buffers: buffers, sessionEpoch: 2)
            await engine.configure(buffers: buffers, sessionEpoch: 1)
            await engine.cancel(sessionEpoch: 1)
            let staleFailure = await engine.recognitionFailure()
            #expect(staleFailure?.userMessage == nil)
            await engine.cancel(sessionEpoch: 2)
            let matchingFailure = await engine.recognitionFailure()
            #expect(matchingFailure?.userMessage == PikoError.sessionInterrupted.userMessage)
            await engine.configure(buffers: buffers, sessionEpoch: 3)
            let newFailure = await engine.recognitionFailure()
            #expect(newFailure?.userMessage == nil)
        }
    }
}
#endif
