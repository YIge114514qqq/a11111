import XCTest

final class CoursewareSelectionUITests: XCTestCase {
    @MainActor
    func testCanEnterExitAndUseSelectionMode() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-courseware"]
        app.launch()

        let select = app.buttons["圈选提问"]
        let pencil = app.buttons["铅笔"]
        let hint = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH %@", "单指从题目一角拖到对角")
        ).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"),
                                               object: select)
        wait(for: [ready], timeout: 10)
        select.tap()
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        pencil.tap()
        XCTAssertFalse(hint.exists, "The toolbar should respond after entering selection mode.")
        select.tap()
        XCTAssertTrue(hint.waitForExistence(timeout: 5))

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.36))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.51))
        start.press(forDuration: 0.08, thenDragTo: end)
        // The preview is presented immediately, before OCR or any model response.
        XCTAssertTrue(app.staticTexts["本次圈选"].waitForExistence(timeout: 10))
    }
}
