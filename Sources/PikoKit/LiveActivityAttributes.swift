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
        /// Which frame of Piko's idle life to show: a blink, a glance, a smile. The app steps it
        /// while the session runs, because a Live Activity ignores SwiftUI animation modifiers and
        /// only animates the change between two updates.
        public var beat: Int

        public init(phase: SessionPhase, words: Int, levels: [Int], beat: Int = 0) {
            self.phase = phase
            self.words = words
            self.levels = levels
            self.beat = beat
        }

        private enum CodingKeys: String, CodingKey { case phase, words, levels, beat }

        /// An activity adopted after an update to the app carries no `beat` yet.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            phase = try container.decode(SessionPhase.self, forKey: .phase)
            words = try container.decode(Int.self, forKey: .words)
            levels = try container.decode([Int].self, forKey: .levels)
            beat = try container.decodeIfPresent(Int.self, forKey: .beat) ?? 0
        }
    }

    public var skin: Skin

    public init(skin: Skin) {
        self.skin = skin
    }
}
#endif
