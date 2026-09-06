import Testing
import Foundation
@testable import PikoBridge
@testable import PikoKit

/// BRDG-03 reframed per 02-RESEARCH.md: the property that actually matters is that App Group
/// file state survives the keyboard extension process being torn down and recreated — which is
/// what an app switch does to the extension in practice, not whatever else happens on Springboard.
/// Constructing/discarding 20 short-lived channels also exercises this plan's deinit fix 20 times
/// over (02-RESEARCH.md Pitfall 2: this is exactly the test shape that surfaces a missing/wrong
/// observer-removal fix immediately).

@Test("state written by one channel survives 20 cold reconstructions of a second instance")
func reconnectionSurvivesTwentyColdReconstructions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = DarwinChannel(container: directory)

    let written = SessionState(phase: .armed, heartbeat: .now, skin: .hero, profile: .code)
    app.writeState(written)

    try #require(app.readState() == written)

    for _ in 0..<20 {
        let keyboard = DarwinChannel(container: directory)
        #expect(keyboard.readState() == written)
        // `keyboard` falls out of scope here, deallocating it and exercising this plan's deinit
        // fix — without it, this loop would leak (or dangle) an observer on every iteration.
    }
}
