import ActivityKit
import WidgetKit
import SwiftUI
import PikoKit

/// The Dynamic Island presence.
///
/// Started in the foreground at arm time (CONSTRAINTS C5) and updated from the background for
/// the rest of the session. Lifetime is 8 h active + 4 h stale (C6) — long enough to arm once
/// in the morning.
///
/// Do not design for 60 fps. These are WidgetKit views rendered by another process; expect
/// roughly 1–2 visible updates per second. Eight to twelve discrete bars, not 512 samples.
struct PikoAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: SessionPhase
        var words: Int
        var levels: [Int]   // 8 buckets, 0...10
    }
    var skin: Skin
}

// TODO(spike 4): the widget itself, plus a stop AppIntent for the button.
