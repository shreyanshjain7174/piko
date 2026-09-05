import Foundation
import Testing
import PikoKit

@Test func audioLevelContractRoundTripAndBounds() throws {
    let sample = AudioLevel(level: 0.65)
    #expect(try JSONDecoder().decode(AudioLevel.self, from: JSONEncoder().encode(sample)) == sample)
    #expect(AudioLevel(level: .nan).level == 0)
    #expect(AudioLevel(level: -1).level == 0)
    #expect(AudioLevel(level: 2).level == 1)
    #expect(!sample.isFresh(at: sample.capturedAt.addingTimeInterval(1)))
    #expect(!sample.isFresh(at: sample.capturedAt.addingTimeInterval(-1)))
}
