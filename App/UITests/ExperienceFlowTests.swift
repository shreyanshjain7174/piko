import XCTest

/// Drives the Piko experience end to end on Simulator: the hold-to-talk gesture on the home
/// orb, and the Dynamic Island presence (compact + expanded) while a session is live with
/// demo speech energy. Screenshots land in /tmp for visual review.
final class ExperienceFlowTests: XCTestCase {

    private func launchPiko() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pikoDemoLevels", "-pikoSkipOnboarding"]
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

        // The result must land, not just the tidying phase: the card becomes editable
        // ("Your words") once the brain has finished rewriting.
        let yourWords = app.staticTexts["Your words"]
        XCTAssertTrue(yourWords.waitForExistence(timeout: 25), "tidying should complete into a result")
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
            // The stop must actually reach the app: the capturing state (and its bars)
            // must end promptly, not linger as a stale notch.
            let recording = springboard.staticTexts["Recording…"]
            XCTAssertTrue(recording.waitForNonExistence(timeout: 10),
                          "Stop from the Island should end the capturing state promptly")
            snap("island_stopped")
        } else {
            XCTFail("expanded Island should expose the Stop control")
        }

        // Clean up: end the session so later runs start fresh.
        app.activate()
        XCUIDevice.shared.system.open(URL(string: "piko://disarm")!)
    }

    /// Walks every remaining surface so the verifier has fresh captures of each: History,
    /// Settings, the visual skin picker, and the onboarding sheet.
    @MainActor
    func testAllScreensRender() throws {
        let app = launchPiko()
        XCTAssertTrue(app.buttons["home.dictate"].waitForExistence(timeout: 8))

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        sleep(1)
        snap("screen_history")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        sleep(1)
        snap("screen_settings")

        app.tabBars.buttons["Home"].tap()
        sleep(1) // let the tab transition settle before reaching for the toolbar
        let setup = app.buttons["home.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        setup.tap()
        let onboardingOpened = app.navigationBars["Get Piko working"].waitForExistence(timeout: 8)
        if !onboardingOpened { snap("debug_setup_tap") }
        XCTAssertTrue(onboardingOpened, "onboarding sheet should open from Home's setup button")
        sleep(1)
        snap("screen_onboarding")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["home.dictate"].waitForExistence(timeout: 5))
    }

    /// A brand-new user is met by the setup walkthrough, and dismissing it lands them on
    /// a usable Home — the U1 first-minute contract.
    @MainActor
    func testFirstRunPresentsOnboarding() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-pikoDemoLevels", "-pikoForceOnboarding"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Get Piko working"].waitForExistence(timeout: 8),
                      "first run should present the setup walkthrough")
        snap("screen_first_run")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["home.dictate"].waitForExistence(timeout: 5),
                      "dismissing onboarding should land on a usable Home")
    }

    /// The real-speech smoke test. Real transcription cannot run on Simulator — neither
    /// SpeechTranscriber (no dictation assets) nor SFSpeechRecognizer on-device
    /// (kLSRErrorDomain 300: the sim's local recognizer asset fails to initialize), and a
    /// server recognizer would break the nothing-leaves-the-machine rule. What the
    /// Simulator CAN prove is that the real-mic capture path arms, starts, and streams
    /// audio levels; transcription correctness is a physical-iPhone check.
    @MainActor
    func testRealMicCaptureStarts() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-pikoRealSpeech", "-pikoAutoStart"]
        app.launch()

        // First real-speech run shows the system speech-recognition prompt; answer it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) {
            allow.tap()
        }

        XCTAssertTrue(app.buttons["home.dictate"].waitForExistence(timeout: 8))
        let transcript = app.textViews["home.transcript"]
        // The speech prompt can surface late (previous session state, engine timing);
        // keep answering it while waiting for capture to begin.
        var started = false
        for _ in 0..<3 {
            let allow = springboard.buttons["Allow"]
            if allow.exists { allow.tap() }
            started = transcript.waitForExistence(timeout: 8)
            if started { break }
        }
        if !started { snap("debug_realmic_fail") }
        XCTAssertTrue(started,
                      "capture should start from the real engine path via -pikoAutoStart")
        snap("realmic_capture_started")

        XCUIDevice.shared.system.open(URL(string: "piko://disarm")!)
    }
}
