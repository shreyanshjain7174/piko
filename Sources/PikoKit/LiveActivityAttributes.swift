#if os(iOS)
import ActivityKit

/// The Dynamic Island presence.
///
/// Started in the foreground at arm time (CONSTRAINTS C5) and updated from the background for
/// the rest of the session. Lifetime is 8 h active + 4 h stale (C6) — long enough to arm once
/// in the morning.
///
/// Do not design for 60 fps. These are WidgetKit views rendered by another process; expect
/// roughly 1–2 visible updates per second. Eight to twelve discrete bars, not 512 samples.
public struct PikoAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: SessionPhase
        public var words: Int
        public var levels: [Int]   // 8 buckets, 0...10

        public init(phase: SessionPhase, words: Int, levels: [Int]) {
            self.phase = phase
            self.words = words
            self.levels = levels
        }
    }

    public var skin: Skin

    public init(skin: Skin) {
        self.skin = skin
    }
}
#endif
