import Foundation

#if os(iOS)
@preconcurrency import ActivityKit
import PikoKit

/// The only ActivityKit importer in the codebase. Owns the `Activity<PikoAttributes>` lifecycle;
/// every displayed phase is routed through `LiveActivityContent.effectivePhase(...)` so `.tidying`
/// (which `SessionPhase` itself never emits) can actually reach the Lock Screen.
@MainActor
public final class LiveActivityController {
    private var activity: Activity<PikoAttributes>?
    private var currentWords: Int = 0
    private var currentPhase: SessionPhase = .idle
    private var isTidyingOverride: Bool = false
    private var levels: [Int] = LiveActivityContent.placeholderLevels()
    private var lastLevelPush: Date?

    /// WidgetKit renders Live Activities at roughly 1–2 updates per second — pushing every
    /// 20 Hz sample would burn the update budget for no visible difference. One bar update
    /// per interval keeps the notch visibly breathing.
    private static let levelPushInterval: TimeInterval = 0.8

    public init() {}

    /// Adopts an already-running Activity (process relaunched mid-session) instead of
    /// requesting a duplicate — 07-RESEARCH.md Pattern 2.
    public func start(skin: Skin) async {
        defer {
            currentPhase = .armed
            currentWords = 0
        }

        if let existing = Activity<PikoAttributes>.activities.first {
            activity = existing
            return
        }

        let attributes = PikoAttributes(skin: skin)
        let initialState = PikoAttributes.ContentState(
            phase: .armed,
            words: 0,
            levels: LiveActivityContent.placeholderLevels()
        )
        let content = ActivityContent(state: initialState, staleDate: Date().addingTimeInterval(8 * 3600))

        // A failed request must not throw out of start(skin:) — arming the mic must succeed
        // regardless of whether the supplementary Live Activity could be created.
        activity = try? Activity<PikoAttributes>.request(attributes: attributes, content: content, pushType: nil)
    }

    /// Every `session.phase` emission reaches here; `.idle` ends the Activity instead of updating it.
    public func update(phase: SessionPhase) async {
        currentPhase = phase
        if LiveActivityContent.shouldEndActivity(for: phase) {
            isTidyingOverride = false
            await end()
            return
        }
        if phase == .capturing {
            levels = LiveActivityContent.placeholderLevels()
            lastLevelPush = nil
        }
        await refreshContent()
    }

    /// Fed by `.audioLevelUpdated`. Rolls the newest bucket into the bar history and refreshes
    /// the Activity no more than once per `levelPushInterval`.
    public func updateLevels(_ sample: AudioLevel) async {
        guard currentPhase == .capturing, sample.isFresh() else { return }
        let now = Date()
        if let last = lastLevelPush, now.timeIntervalSince(last) < Self.levelPushInterval { return }
        lastLevelPush = now
        levels = LiveActivityContent.rolled(levels, with: LiveActivityContent.bucket(of: sample.level))
        await refreshContent()
    }

    /// Wired to `CaptureCoordinator.onTidyingChange`. No-ops once the Activity has already
    /// ended so a late-arriving call can never resurrect it.
    public func setTidying(_ tidying: Bool) async {
        isTidyingOverride = tidying
        guard currentPhase != .idle else { return }
        await refreshContent()
    }

    /// Wired to draft arrival; recomputes the live word count.
    public func updateWords(from text: String) async {
        currentWords = LiveActivityContent.wordCount(in: text)
        await refreshContent()
    }

    public func end() async {
        if let activity {
            await activity.end(nil, dismissalPolicy: .default)
        }
        self.activity = nil
    }

    private func refreshContent() async {
        let state = PikoAttributes.ContentState(
            phase: LiveActivityContent.effectivePhase(sessionPhase: currentPhase, isTidying: isTidyingOverride),
            words: currentWords,
            levels: levels
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(8 * 3600))
        if let activity {
            await activity.update(content)
        }
    }
}
#endif
