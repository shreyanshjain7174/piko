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
    private var beat = 0
    /// Steps Piko through blinks and glances while the session runs. The armed audio session keeps
    /// the app alive in the background, so these local updates keep coming with the app closed.
    private var heartbeat: Task<Void, Never>?

    public init() {}

    /// Adopts an already-running Activity (process relaunched mid-session) instead of
    /// requesting a duplicate — 07-RESEARCH.md Pattern 2.
    public func start(skin: Skin) async {
        defer {
            currentPhase = .armed
            currentWords = 0
        }

        if activity != nil { return }
        if let existing = Activity<PikoAttributes>.activities.first {
            activity = existing
            startHeartbeat()
            return
        }

        let attributes = PikoAttributes(skin: skin)
        let initialState = PikoAttributes.ContentState(
            phase: .armed,
            words: 0,
            levels: LiveActivityContent.placeholderLevels()
        )
        let content = ActivityContent(state: initialState, staleDate: Date().addingTimeInterval(10 * 60))

        // A failed request must not throw out of start(skin:) — arming the mic must succeed
        // regardless of whether the supplementary Live Activity could be created.
        do {
            activity = try Activity<PikoAttributes>.request(attributes: attributes, content: content, pushType: nil)
            startHeartbeat()
        } catch {
            print("LiveActivityController: Live Activity unavailable (\(type(of: error)))")
        }
    }

    /// Every `session.phase` emission reaches here; `.idle` ends the Activity instead of updating it.
    public func update(phase: SessionPhase) async {
        if phase != currentPhase { beat = 0 }   // each phase opens on its resting face
        currentPhase = phase
        if LiveActivityContent.shouldEndActivity(for: phase) {
            isTidyingOverride = false
            await end()
            return
        }
        await refreshContent()
    }

    /// Wired to `CaptureCoordinator.onTidyingChange`. No-ops once the Activity has already
    /// ended so a late-arriving call can never resurrect it.
    public func setTidying(_ tidying: Bool) async {
        if tidying != isTidyingOverride { beat = 0 }
        isTidyingOverride = tidying
        guard currentPhase != .idle else { return }
        await refreshContent()
    }

    /// Wired to draft arrival; recomputes the live word count.
    public func updateWords(from text: String) async {
        let words = LiveActivityContent.wordCount(in: text)
        guard words != currentWords else { return }
        currentWords = words
        await refreshContent()
    }

    public func end() async {
        heartbeat?.cancel()
        heartbeat = nil
        // Also end activities adopted from an earlier launch, so nothing is left behind.
        for running in Activity<PikoAttributes>.activities {
            // Immediate: a finished request should leave nothing behind on the Lock Screen.
            await running.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                let phase = self.map {
                    LiveActivityContent.effectivePhase(sessionPhase: $0.currentPhase, isTidying: $0.isTidyingOverride)
                } ?? .idle
                // An idle phase still waits a moment: start() sets .armed only as it returns.
                try? await Task.sleep(for: LiveActivityContent.beatInterval(for: phase) ?? .seconds(1))
                guard let self, !Task.isCancelled, self.activity != nil else { return }
                guard LiveActivityContent.beatInterval(for: phase) != nil else { continue }
                self.beat &+= 1
                await self.refreshContent()
            }
        }
    }

    private func refreshContent() async {
        let state = PikoAttributes.ContentState(
            phase: LiveActivityContent.effectivePhase(sessionPhase: currentPhase, isTidying: isTidyingOverride),
            words: currentWords,
            levels: LiveActivityContent.placeholderLevels(),
            beat: beat
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(10 * 60))
        if let activity {
            await activity.update(content)
        }
    }
}
#endif
