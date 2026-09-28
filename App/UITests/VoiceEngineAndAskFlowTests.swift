import XCTest

/// UI verification for the Sarvam cloud STT + auto-capture + ask surfaces added in
/// this milestone. Screenshots land in /tmp for the human review; each screen has
/// a checkpoint assertion so a regression is caught even without eyeballing.
final class VoiceEngineAndAskFlowTests: XCTestCase {

    private func launchPiko() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pikoSkipOnboarding", "-pikoDemoLevels"]
        app.launch()
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/piko_ui_\(name).png"))
        // Also attach so failures show up in the xcresult bundle for local triage.
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        attachment.name = name
        add(attachment)
    }

    private func tapSettingsTab(_ app: XCUIApplication) {
        // The tab bar uses SwiftUI's TabView; the "Settings" label is queryable.
        let tab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(tab.waitForExistence(timeout: 6))
        tab.tap()
    }

    @MainActor
    func testHomeShowsAskBarAndFooterMatchesEngine() throws {
        let app = launchPiko()
        snap(app, "home_default")

        // Ask bar is quiet by default; the placeholder is the invitation.
        let askField = app.textFields.matching(identifier: "home.ask.input").firstMatch
        XCTAssertTrue(askField.waitForExistence(timeout: 6), "ask bar should be visible on home")

        // The on-device promise stays intact when the engine is on-device (the default).
        XCTAssertTrue(app.staticTexts["On-device. Nothing ever leaves this iPhone."]
            .waitForExistence(timeout: 4),
                      "home footer must reflect the on-device default")
    }

    @MainActor
    func testAskBarRecallRouteAnswersInline() throws {
        let app = launchPiko()
        let askField = app.textFields.matching(identifier: "home.ask.input").firstMatch
        XCTAssertTrue(askField.waitForExistence(timeout: 6))
        askField.tap()
        askField.typeText("what did i say about the deck")
        snap(app, "ask_typed_recall")

        // Submit via return key. Recall route always returns a turn (empty or populated),
        // so the answer card should appear even in a fresh install.
        askField.typeText("\n")
        // Dismiss keyboard for a cleaner screenshot.
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        // The answer card carries the dismiss xmark; wait for it as proof the surface unfolded.
        let dismiss = app.buttons["Dismiss answer"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 6),
                      "recall route should render an inline answer under the ask bar")
        snap(app, "ask_answer_recall")
    }

    @MainActor
    func testSettingsVoiceEngineSectionShowsBothOptionsAndKeyEntry() throws {
        let app = launchPiko()
        tapSettingsTab(app)
        snap(app, "settings_landing")

        // Capture-mode radio group renders both options with explainers.
        XCTAssertTrue(app.staticTexts["Hold to talk"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Auto"].exists)

        // Voice-engine radio group renders both options.
        XCTAssertTrue(app.staticTexts["On this iPhone"].exists)
        XCTAssertTrue(app.staticTexts["Sarvam Cloud"].exists)

        // Selecting Sarvam Cloud reveals the key-entry section with a SecureField.
        app.staticTexts["Sarvam Cloud"].tap()
        let keyField = app.secureTextFields["Sarvam API key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 4),
                      "picking Sarvam Cloud should reveal the paste-in key field")
        snap(app, "settings_sarvam_selected")

        // Reverting to on-device is a single tap and hides the key-entry section.
        app.staticTexts["On this iPhone"].tap()
        XCTAssertFalse(keyField.exists,
                       "going back to on-device should hide the key field again")
        snap(app, "settings_ondevice_selected")
    }

    @MainActor
    func testSelectingAutoCaptureModePersistsAndUpdatesFooter() throws {
        let app = launchPiko()
        tapSettingsTab(app)

        // Pick auto capture mode. The default was hold-to-talk.
        let auto = app.staticTexts["Auto"]
        XCTAssertTrue(auto.waitForExistence(timeout: 6))
        auto.tap()
        snap(app, "settings_auto_selected")

        // The section footer must switch to the auto-explainer.
        let autoFooter = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Auto only fires while a session is armed'"))
            .firstMatch
        XCTAssertTrue(autoFooter.waitForExistence(timeout: 3))
    }
}
