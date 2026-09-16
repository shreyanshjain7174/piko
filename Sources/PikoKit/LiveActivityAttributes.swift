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
        public var mood: PikoMood  // drives the notch pet's looping animation
        public var animated: Bool  // false = Low Power Mode / low battery: the pet rests

        public init(phase: SessionPhase, words: Int, levels: [Int],
                    mood: PikoMood = .calm, animated: Bool = true) {
            self.phase = phase
            self.words = words
            self.levels = levels
            self.mood = mood
            self.animated = animated
        }

        /// Decode-tolerant: activities created before `mood`/`animated` existed still decode.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            phase = try container.decode(SessionPhase.self, forKey: .phase)
            words = try container.decode(Int.self, forKey: .words)
            levels = try container.decode([Int].self, forKey: .levels)
            mood = try container.decodeIfPresent(PikoMood.self, forKey: .mood) ?? .calm
            animated = try container.decodeIfPresent(Bool.self, forKey: .animated) ?? true
        }

        private enum CodingKeys: String, CodingKey {
            case phase, words, levels, mood, animated
        }
    }

    public var skin: Skin

    public init(skin: Skin) {
        self.skin = skin
    }
}
#endif
