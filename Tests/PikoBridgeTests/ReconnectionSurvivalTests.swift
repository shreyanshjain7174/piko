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
    let app = try #require(
        DarwinChannel(),
        "DarwinChannel() returned nil — the App Group container is unavailable to this test process. This is an environment limitation (likely missing com.apple.security.application-groups entitlement in this unsigned SPM test binary), not necessarily a defect in the fix under test."
    )

    let written = SessionState(phase: .armed, heartbeat: .now, skin: .hero, profile: .code)
    app.writeState(written)

    // Self-check before looping: on macOS, `containerURL(forSecurityApplicationGroupIdentifier:)`
    // resolves to a path even without the App Group entitlement, but the OS only creates that
    // directory for an entitled, provisioned process. In an unsigned SPM test binary the path
    // resolves (DarwinChannel() does not return nil) yet the underlying atomic write silently
    // no-ops (DarwinChannel.write swallows the error via `try?`), so readState() comes back nil.
    // Confirm the same-instance round trip actually works before asserting anything about cold
    // reconstruction — if it doesn't, that is the environment limitation this plan's escape valve
    // exists for, surfaced honestly instead of producing 20 confusing downstream failures.
    try #require(
        app.readState() == written,
        "Wrote SessionState but could not read it back on the same DarwinChannel instance. The App Group container directory does not exist and could not be created in this unsigned SPM test environment (containerURL resolved to a path, but the atomic write failed silently) — this is an environment limitation, not a defect in the deinit/observer-removal fix under test."
    )

    for _ in 0..<20 {
        let keyboard = try #require(
            DarwinChannel(),
            "DarwinChannel() returned nil on a cold reconstruction — same environment limitation as above; App Group container unavailable to this test process."
        )
        #expect(keyboard.readState() == written)
        // `keyboard` falls out of scope here, deallocating it and exercising this plan's deinit
        // fix — without it, this loop would leak (or dangle) an observer on every iteration.
    }
}
