import Testing
import Foundation
@testable import PikoKit

/// Proves `CaptureDraft.isNewer(than:)`'s (sessionEpoch, sequence) ordering rule, including the
/// literal session-restart regression 02-RESEARCH.md documents. No `PikoBridge` import needed —
/// this is pure `PikoKit` type logic, not a channel test.

@Test("a first-ever draft is always newer than no previous draft")
func firstDraftIsAlwaysNewer() {
    let draft = CaptureDraft(sessionEpoch: 0, sequence: 0, text: "hi", stablePrefix: 0)
    #expect(draft.isNewer(than: nil))
}

@Test("within the same epoch, a strictly higher sequence is newer")
func sameEpochHigherSequenceIsNewer() {
    let previous = CaptureDraft(sessionEpoch: 2, sequence: 5, text: "a", stablePrefix: 0)
    let higher = CaptureDraft(sessionEpoch: 2, sequence: 6, text: "b", stablePrefix: 0)
    let equal = CaptureDraft(sessionEpoch: 2, sequence: 5, text: "c", stablePrefix: 0)
    let lower = CaptureDraft(sessionEpoch: 2, sequence: 4, text: "d", stablePrefix: 0)

    #expect(higher.isNewer(than: previous))
    #expect(!equal.isNewer(than: previous))
    #expect(!lower.isNewer(than: previous))
}

@Test("a new session epoch always wins over a leftover high-water sequence mark")
func newEpochBeatsStaleSequence() {
    // The literal regression from 02-RESEARCH.md: previous session left off at sequence 47,
    // the new session restarts its own counter at 0. Under the old bare `0 > 47` comparison
    // this was false, silently dropping every draft of the new session forever.
    let previous = CaptureDraft(sessionEpoch: 0, sequence: 47, text: "old session", stablePrefix: 0)
    let newSession = CaptureDraft(sessionEpoch: 1, sequence: 0, text: "new session", stablePrefix: 0)
    #expect(newSession.isNewer(than: previous))
}

@Test("a strictly lower epoch is never newer, even with a numerically larger sequence")
func lowerEpochNeverWinsRegardlessOfSequence() {
    let previous = CaptureDraft(sessionEpoch: 3, sequence: 2, text: "current session", stablePrefix: 0)
    let stragglerFromOldEpoch = CaptureDraft(sessionEpoch: 2, sequence: 999, text: "late arrival", stablePrefix: 0)
    #expect(!stragglerFromOldEpoch.isNewer(than: previous))
}
