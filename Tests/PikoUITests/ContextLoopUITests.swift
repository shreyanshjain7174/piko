import XCTest

@MainActor
final class ContextLoopUITests: XCTestCase {
    private func send(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["home.request"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(text)
        app.buttons["home.send"].tap()
    }

    func testContextLoopAndSettingsEdit() {
        let app = XCUIApplication()
        app.launchArguments = ["-PikoUITestStub"]
        app.launch()
        defer { app.terminate() }

        send("Riya’s usual is a flat white, and we meet on Fridays", in: app)
        let save = app.buttons["Save all"]
        XCTAssertTrue(save.waitForExistence(timeout: 30))
        save.tap()
        send("what does Riya drink?", in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "a flat white")).firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "You said on")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Riya’s usual is a flat white")).firstMatch.exists)

        app.buttons["Settings"].tap()
        let knowledge = app.buttons["What Piko knows"]
        XCTAssertTrue(knowledge.waitForExistence(timeout: 20))
        knowledge.tap()
        let count = app.staticTexts["suggestions-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 20))
        XCTAssertEqual(count.label, "Suggestions: 2")
        let usual = app.staticTexts["person/riya/usual"]
        XCTAssertTrue(usual.waitForExistence(timeout: 20))
        let row = app.otherElements["settings.fact.person/riya/usual"]
        app.swipeUp() // Bring the action above the bottom tab bar.
        let edit = row.buttons["Edit saved fact"]
        XCTAssertTrue(edit.exists)
        edit.tap()
        let value = app.descendants(matching: .any)["settings.editValue"]
        if !value.waitForExistence(timeout: 10) { print(app.debugDescription) }
        XCTAssertTrue(value.exists)
        value.tap()
        value.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) { selectAll.tap() }
        else { value.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.value.map { String(describing: $0).count } ?? 20)) }
        value.typeText("oat latte")
        app.buttons["Save change"].tap()
        XCTAssertTrue(app.staticTexts["oat latte"].waitForExistence(timeout: 20))
        app.buttons["Home"].tap()
        send("what does Riya drink?", in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Update usual to oat latte")).firstMatch.waitForExistence(timeout: 30))

        app.buttons["Settings"].tap()
        app.buttons["What Piko knows"].tap()
        XCTAssertTrue(app.staticTexts["person/riya/usual"].waitForExistence(timeout: 20))
        app.swipeUp()
        app.otherElements["settings.fact.person/riya/usual"].buttons["Forget saved fact"].tap()
        app.alerts.buttons["Forget saved fact"].tap()
        let dropped = NSPredicate(format: "label == %@", "Suggestions: 1")
        expectation(for: dropped, evaluatedWith: app.staticTexts["suggestions-count"])
        waitForExpectations(timeout: 20)
        app.buttons["Home"].tap()
        send("what does Riya drink?", in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "know that yet")).firstMatch.waitForExistence(timeout: 20))
    }

    func testHostFieldKeyboardInsertWhenEnabled() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PikoUITestStub"]
        app.launch()
        defer { app.terminate() }
        throw XCTSkip("user-assisted: Piko keyboard with Full Access must already be enabled")
    }
}
