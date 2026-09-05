import Foundation
import Testing
import PikoKit
@testable import PikoBridge

@Test func audioLevelChannelRoundTripDoesNotOverwriteSessionOrDraft() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = DarwinChannel(container: directory)
    let reader = DarwinChannel(container: directory)
    let state = SessionState(phase: .capturing, skin: .hero, profile: .code)
    let draft = CaptureDraft(sequence: 3, text: "keep this", stablePrefix: 4)
    writer.writeState(state)
    writer.writeDraft(draft)
    #expect(reader.readAudioLevel() == nil)
    for index in 0..<20 {
        let sample = AudioLevel(level: Double(index) / 20)
        writer.writeAudioLevel(sample)
        #expect(reader.readAudioLevel() == sample)
    }
    #expect(reader.readState() == state)
    #expect(reader.readDraft() == draft)
    writer.writeAudioLevel(AudioLevel())
    #expect(reader.readAudioLevel()?.level == 0)
}
