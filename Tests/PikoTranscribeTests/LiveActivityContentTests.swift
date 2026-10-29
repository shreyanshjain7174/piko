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

    @Test func heartbeatRunsOnlyWhileTheSessionIsLive() {
        #expect(LiveActivityContent.beatInterval(for: .idle) == nil)
        #expect(LiveActivityContent.beatInterval(for: .armed) == .seconds(3))
        #expect(LiveActivityContent.beatInterval(for: .capturing)! < LiveActivityContent.beatInterval(for: .armed)!)
        #expect(LiveActivityContent.beatInterval(for: .tidying)! < LiveActivityContent.beatInterval(for: .armed)!)
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
