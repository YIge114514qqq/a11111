import XCTest

final class CoursewareSelectionUITests: XCTestCase {
    @MainActor
    func testCanEnterExitAndUseSelectionMode() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let courses = app.tabBars.buttons["课程"]
        XCTAssertTrue(courses.waitForExistence(timeout: 10))
        courses.tap()

        // CI installs exactly one sample lesson in the simulator.
        let lesson = app.cells.firstMatch
        XCTAssertTrue(lesson.waitForExistence(timeout: 10))
        lesson.tap()

        let detailBar = app.navigationBars["圈选回归课程"]
        XCTAssertTrue(detailBar.waitForExistence(timeout: 10))
        // The menu's system image label varies by iOS version.
        let menu = try XCTUnwrap(detailBar.buttons.allElementsBoundByIndex.filter(\.isHittable)
            .max { $0.frame.midX < $1.frame.midX })
        menu.tap()
        let openCourseware = app.buttons["打开课件"]
        XCTAssertTrue(openCourseware.waitForExistence(timeout: 10))
        openCourseware.tap()

        let select = app.buttons["圈选提问"]
        let pencil = app.buttons["铅笔"]
        let hint = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH %@", "单指从题目一角拖到对角")
        ).firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 10))
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
