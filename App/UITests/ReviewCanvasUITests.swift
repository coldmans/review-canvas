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

        let intents = [
            (identifier: "review-type-explain", label: "설명"),
            (identifier: "review-type-change", label: "수정"),
            (identifier: "review-type-verify", label: "검토"),
        ]

        for intent in intents {
            let button = app.buttons[intent.identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertEqual(button.label, intent.label)
        }
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
