import XCTest

/// Drives the Piko experience end to end on Simulator: the hold-to-talk gesture on the home
/// orb, and the Dynamic Island presence (compact + expanded) while a session is live with
/// demo speech energy. Screenshots land in /tmp for visual review.
final class ExperienceFlowTests: XCTestCase {

    private func launchPiko() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pikoDemoLevels"]
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: "/tmp/piko_ui_\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }

    @MainActor
    func testHoldToTalkStreamsTranscriptAndLandsResult() throws {
        let app = launchPiko()
        let orb = app.buttons["home.dictate"]
        XCTAssertTrue(orb.waitForExistence(timeout: 8), "home orb should exist")

        orb.press(forDuration: 3.0)
        snap("hold_released")

        let transcript = app.textViews["home.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "transcript card should appear after dictation")
        snap("hold_result")
    }

    @MainActor
    func testLiveIslandCompactAndExpanded() throws {
        let app = launchPiko()
        XCTAssertTrue(app.buttons["home.dictate"].waitForExistence(timeout: 8))

        // Arm + start capture through the debug route so the hold gesture is not required.
        XCUIDevice.shared.system.open(URL(string: "piko://start")!)
        sleep(3)

        // Leave the app; the Island floats above the home screen.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        sleep(2)
        snap("island_compact")

        // Long-press the Island to expand it.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025))
            .press(forDuration: 1.2)
        sleep(1)
        snap("island_expanded")

        let stop = springboard.buttons["Stop the Piko session"]
        if stop.waitForExistence(timeout: 4) {
            stop.tap()
            snap("island_stopped")
        } else {
            XCTFail("expanded Island should expose the Stop control")
        }

        // Clean up: end the session so later runs start fresh.
        app.activate()
        XCUIDevice.shared.system.open(URL(string: "piko://disarm")!)
    }
}
