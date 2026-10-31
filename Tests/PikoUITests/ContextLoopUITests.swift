import XCTest

@MainActor
final class ContextLoopUITests: XCTestCase {
    private func send(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["home.request"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(text)
        let send = app.buttons["home.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()
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

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let knowledge = app.buttons["What Piko knows"]
        XCTAssertTrue(knowledge.waitForExistence(timeout: 20))
        knowledge.tap()
        let count = app.staticTexts["suggestions-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 20))
        XCTAssertEqual(count.label, "Suggestions: 2")
        let usual = app.staticTexts["person/riya/usual"]
        XCTAssertTrue(usual.waitForExistence(timeout: 20))
        let row = app.otherElements["settings.fact.person/riya/usual"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let edit = app.buttons["settings.edit.person/riya/usual"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20))
        app.swipeUp() // Move the row above the tab bar before tapping.
        edit.tap()
        let value = app.textFields["settings.editValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 20))
        value.tap()
        value.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) { selectAll.tap() }
        else { value.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.value.map { String(describing: $0).count } ?? 20)) }
        value.typeText("oat latte")
        let saveChange = app.buttons["settings.editSave"]
        XCTAssertTrue(saveChange.waitForExistence(timeout: 10))
        saveChange.tap()
        XCTAssertTrue(app.staticTexts["oat latte"].waitForExistence(timeout: 20))
        let home = app.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 20))
        home.tap()
        send("what does Riya drink?", in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "oat latte")).firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Update usual to oat latte")).firstMatch.waitForExistence(timeout: 20))

        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        // Tab selection preserves the Settings navigation stack on return.
        if knowledge.waitForExistence(timeout: 3) { knowledge.tap() }
        XCTAssertTrue(app.staticTexts["person/riya/usual"].waitForExistence(timeout: 20))
        let forget = app.buttons["settings.forget.person/riya/usual"]
        XCTAssertTrue(forget.waitForExistence(timeout: 20))
        if !forget.isHittable { app.swipeUp() }
        forget.tap()
        let confirmForget = app.alerts.buttons["Forget saved fact"]
        XCTAssertTrue(confirmForget.waitForExistence(timeout: 10))
        confirmForget.tap()
        let dropped = NSPredicate(format: "label == %@", "Suggestions: 1")
        expectation(for: dropped, evaluatedWith: app.staticTexts["suggestions-count"])
        waitForExpectations(timeout: 20)
        XCTAssertTrue(home.waitForExistence(timeout: 20))
        home.tap()
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
