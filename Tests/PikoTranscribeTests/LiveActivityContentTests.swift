import Foundation
import Testing
import PikoKit
@testable import PikoCaptureCore

@Suite("Live Activity content — pure functions")
struct LiveActivityContentTests {
    @Test func wordCountBasic() {
        #expect(LiveActivityContent.wordCount(in: "hello world") == 2)
    }

    @Test func wordCountEmptyAndWhitespaceOnly() {
        #expect(LiveActivityContent.wordCount(in: "") == 0)
        #expect(LiveActivityContent.wordCount(in: "   ") == 0)
    }

    @Test func wordCountIrregularWhitespace() {
        #expect(LiveActivityContent.wordCount(in: "hello   world\tfoo\nbar") == 4)
    }

    @Test func placeholderLevelsHasEightEntries() {
        #expect(LiveActivityContent.placeholderLevels().count == 8)
    }

    @Test func bucketCoversTheNormalizedRange() {
        #expect(LiveActivityContent.bucket(of: 0.0) == 0)
        #expect(LiveActivityContent.bucket(of: 0.44) == 4)
        #expect(LiveActivityContent.bucket(of: 0.46) == 5)
        #expect(LiveActivityContent.bucket(of: 1.0) == 10)
    }

    @Test func bucketClampsAndRejectsNonfinite() {
        #expect(LiveActivityContent.bucket(of: -0.5) == 0)
        #expect(LiveActivityContent.bucket(of: 1.7) == 10)
        #expect(LiveActivityContent.bucket(of: .nan) == 0)
    }

    @Test func rolledScrollsOldestOffTheLeft() {
        let resting = LiveActivityContent.placeholderLevels()
        var levels = resting
        for bucket in [1, 2, 3, 4, 5, 6, 7, 8] {
            levels = LiveActivityContent.rolled(levels, with: bucket)
        }
        #expect(levels == [1, 2, 3, 4, 5, 6, 7, 8])
        levels = LiveActivityContent.rolled(levels, with: 9)
        #expect(levels == [2, 3, 4, 5, 6, 7, 8, 9])
    }

    @Test func rolledClampsItsInput() {
        let levels = LiveActivityContent.rolled([0, 0, 0, 0, 0, 0, 0, 0], with: 42)
        #expect(levels.last == 10)
    }

    @Test func shouldEndActivityOnlyForIdle() {
        #expect(LiveActivityContent.shouldEndActivity(for: .idle) == true)
    }

    @Test func shouldNotEndActivityForNonIdlePhases() {
        for phase: SessionPhase in [.armed, .capturing, .tidying] {
            #expect(LiveActivityContent.shouldEndActivity(for: phase) == false)
        }
    }

    @Test func effectivePhaseTidyingOverrideWinsOverNonIdle() {
        for phase: SessionPhase in [.armed, .capturing, .tidying] {
            #expect(LiveActivityContent.effectivePhase(sessionPhase: phase, isTidying: true) == .tidying)
        }
    }

    @Test func effectivePhaseRealIdleWinsOverStaleTidyingOverride() {
        #expect(LiveActivityContent.effectivePhase(sessionPhase: .idle, isTidying: true) == .idle)
    }
}
