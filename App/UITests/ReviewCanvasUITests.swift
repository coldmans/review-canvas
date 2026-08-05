import XCTest

@MainActor
final class ReviewCanvasUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReviewToolbarExposesThreeExplicitIntents() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.buttons["review-type-explain"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["review-type-change"].exists)
        XCTAssertTrue(app.buttons["review-type-verify"].exists)
    }

    func testSampleDiagramCanReceiveAndResolveAReviewMark() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        let explainButton = app.buttons["review-type-explain"]
        XCTAssertTrue(explainButton.waitForExistence(timeout: 5))
        explainButton.tap()

        let canvas = app.buttons["diagram-review-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 2), app.debugDescription)
        canvas.tap()

        let firstMark = app.buttons.matching(identifier: "review-mark").firstMatch
        XCTAssertTrue(firstMark.waitForExistence(timeout: 2))
        firstMark.tap()

        let resolveButton = app.buttons["resolve-review-mark"]
        XCTAssertTrue(resolveButton.waitForExistence(timeout: 2))
        resolveButton.tap()

        XCTAssertTrue(app.staticTexts["해결됨"].waitForExistence(timeout: 2))
    }
}
